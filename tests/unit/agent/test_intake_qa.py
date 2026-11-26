import json
import zipfile


import pytest
from lxml import etree

import translate_book
from src.core.agent import qa
from src.core.agent.intake import (CUT_REASON, boilerplate_reason, clean_text, clean_volume,
                                   judge_page)
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_pipeline_e2e import book_dir, calls, env, is_translation, upload  # noqa: F401


def test_boilerplate_is_recognised_and_story_is_not():
    assert boilerplate_reason("The Project Gutenberg EBook of X *** START OF THIS PROJECT GUTENBERG EBOOK X ***")
    assert boilerplate_reason("Project Gutenberg-tm a. Project Gutenberg-tm b. Project Gutenberg-tm c.")
    assert boilerplate_reason("A Study in Scarlet By A. Conan Doyle 1 Original Transcriber's Note: This etext")
    assert boilerplate_reason("Downloaded from z-library. Thank you.")
    assert not boilerplate_reason("CHAPTER I. Mr. Sherlock Holmes. In the year 1878 I took my degree.")
    assert not boilerplate_reason("He read the project gutenberg of his own youth, wistfully. " * 80)


def test_epub_boilerplate_documents_are_removed_and_the_original_is_untouched(tmp_path):
    book = build_omnibus(tmp_path / "saga.epub", 2, 1, boilerplate=True)
    before = book.read_bytes()
    path, removed = clean_volume(book, tmp_path / "volumes")
    assert {name.rsplit("/", 1)[-1] for name, _ in removed} == {"gbhead.xhtml", "gblicense.xhtml"}
    assert path.parent == tmp_path / "volumes" and book.read_bytes() == before
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        assert z.testzip() is None
        assert not [n for n in names if "gbhead" in n or "gblicense" in n]
        assert "gbhead" not in z.read("OEBPS/content.opf").decode()
        assert "Fake Saga" in z.read("OEBPS/content.opf").decode()      # title unchanged


def test_clean_book_is_left_alone(tmp_path):
    book = build_omnibus(tmp_path / "saga.epub", 2, 1)
    assert clean_volume(book, tmp_path / "volumes") == (book, [])


def test_text_is_cut_between_the_gutenberg_markers(tmp_path):
    source = tmp_path / "b.txt"
    source.write_text("Header\n*** START OF THIS PROJECT GUTENBERG EBOOK B ***\nThe story.\n"
                      "*** END OF THIS PROJECT GUTENBERG EBOOK B ***\nLicence text\n")
    target = tmp_path / "c.txt"
    assert clean_text(source, target)
    assert target.read_text().strip() == "The story."


def test_pipeline_never_sends_boilerplate_to_the_model(env):  # noqa: F811
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    build_omnibus(inbox / "saga.epub", 2, 1, boilerplate=True)
    assert translate_book.main(["--non-fiction"]) == 0
    assert not any("PROJECT GUTENBERG" in c["prompt"].upper() for c in calls(env))
    outputs = list((book_dir(env) / "translation").glob("*.epub"))
    assert outputs
    with zipfile.ZipFile(outputs[0]) as z:
        assert not [n for n in z.namelist() if "gblicense" in n or "gbhead" in n]


def test_a_drifted_name_is_repaired_and_reported(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv("FAKE_NAME_DRIFT", "1")
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--no-refine"]) == 0
    info = json.loads((book_dir(env) / "book.json").read_text())
    assert all(v["fixed_variants"] == {"Aldrik": "Aldric"} for v in info["volumes"])
    for output in (book_dir(env) / "translation").glob("*.epub"):
        with zipfile.ZipFile(output) as z:
            body = " ".join(z.read(n).decode("utf-8", "ignore")
                            for n in z.namelist() if n.endswith(".xhtml"))
        assert "Aldrik" not in body and "Aldric" in body
    report = (book_dir(env) / "qa_report.md").read_text()
    assert "Name variants repaired: Aldrik -> Aldric" in report
    assert not list((book_dir(env) / "translation").glob("*.md"))        # no stray engine reports
    assert sorted(p.name for p in (book_dir(env) / "translation").iterdir()
                  if p.suffix != ".epub") == []


def test_a_truncated_translation_is_flagged(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv("FAKE_SHORT", "1")
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    (inbox / "story.txt").write_text(("The captain walked along the old stone pier at dawn. " * 40
                                      + "\n\n") * 3)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    info = json.loads((env / "books" / "story" / "book.json").read_text())
    assert info["volumes"][0]["qa_flags"] == 1
    assert "possible omission" in (env / "books" / "story" / "qa_report.md").read_text()


def test_redo_translates_again_and_keeps_the_old_file(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--no-refine"]) == 0
    before = len(calls(env))
    source = book_dir(env) / "source" / "saga.epub"
    assert translate_book.main(["-i", str(source), "--no-refine", "--redo", "--volumes", "1"]) == 0
    assert len(calls(env)) > before                                   # volume 1 was sent again
    assert len(list((book_dir(env) / "previous").glob("*.epub"))) == 1
    info = json.loads((book_dir(env) / "book.json").read_text())
    assert [v["status"] for v in info["volumes"]] == ["completed", "completed"]
    assert len(list((book_dir(env) / "translation").glob("*.epub"))) == 2


def test_audit_flags_numbers_dialogue_and_locked_terms():
    source = ('"No," he said. "Yes," she said. "Why?" "How?" "When?" "Where?" ' * 8
              + "On 1887 and 1914 Aldric walked. Aldric ran. Aldric hid. ") * 2
    output = "Dia berjalan tanpa tanda kutip dan tanpa angka. " * 40
    result = qa.audit_pair("a.xhtml", source, output, 3, 5,
                           [{"source": "Aldric", "target": "Aldric", "decision": "keep"}])
    text = " ".join(result.flags)
    assert "dialogue marks differ" in text and "numbers missing" in text
    assert "paragraphs: 3 in the source, 5" in text and "locked term never rendered" in text


def test_a_plural_s_is_not_a_missing_name():
    source = "The Mormons came. The Mormons stayed. The Mormons left. " * 10
    output = "Kaum Mormon datang. Kaum Mormon tinggal. Kaum Mormon pergi. " * 10
    result = qa.audit_pair("a", source, output, 0, 0,
                           [{"source": "Mormons", "target": "Mormons", "decision": "keep"}])
    assert not [f for f in result.flags if "locked term" in f]


def test_variant_finder_ignores_real_names_and_sentence_starts():
    entries = [{"source": "Lestrade", "target": "Lestrade", "decision": "keep"}]
    source = "Lestrade met Lestrand, a clerk."
    output = "Kemudian Lestrade bertemu Lestrand, seorang juru tulis. Lestrada pergi. Lestrada! kata Lestrada."
    variants = qa.find_name_variants(source, output, entries)
    assert "Lestrand" not in variants            # a real word of the source
    assert variants == {"Lestrada": ("Lestrade", 1)}   # only the mid-sentence use counts


def test_a_locked_name_that_is_also_a_common_word_is_not_hunted():
    entries = [{"source": "Standard", "target": "Standard", "decision": "keep"}]
    source = "The Daily Standard reported it. We follow present standards."
    output = "The Daily Standard memberitakannya. Kami mengikuti Standar terkini, kata Standar itu."
    assert qa.find_name_variants(source, output, entries) == {}


def test_boilerplate_pages_are_deleted_from_a_finished_translation(tmp_path):
    from src.core.agent.epub_metadata import audit_metadata
    from src.core.agent.intake import boilerplate_documents, remove_documents
    book = build_omnibus(tmp_path / "saga.epub", 2, 1, boilerplate=True)
    names = {n for n, _ in boilerplate_documents(book)}
    assert {n.rsplit("/", 1)[-1] for n in names} == {"gbhead.xhtml", "gblicense.xhtml"}
    translated = tmp_path / "translated.epub"
    translated.write_bytes(book.read_bytes())          # stands in for a translation with those pages
    assert len(remove_documents(translated, names)) == 2
    with zipfile.ZipFile(translated) as z:
        assert z.testzip() is None
        assert not [n for n in z.namelist() if "gbhead" in n or "gblicense" in n]
        assert "gbhead" not in z.read("OEBPS/nav.xhtml").decode()     # gone from the TOC too
    assert audit_metadata(translated, target_language="English") == []
    assert remove_documents(translated, names) == []                  # idempotent


def test_the_pipeline_deletes_them_and_does_not_flag_their_absence(env, tmp_path):  # noqa: F811
    from src.core.agent import AgentOptions, BookAgent
    from src.core.agent.pipeline import VolumeState
    source = build_omnibus(tmp_path / "saga.epub", 2, 1, boilerplate=True)
    output = tmp_path / "out.epub"
    output.write_bytes(source.read_bytes())
    agent = BookAgent(AgentOptions(input_path=source, books_dir=tmp_path / "books"))
    vol = VolumeState(index=1, label="saga", source=str(source), output=str(output))
    agent._drop_boilerplate(vol)
    agent._audit(vol, [])
    assert vol.qa_flags == 0
    assert not [r for r in agent._qa_results[1] if "missing from the translation" in " ".join(r.flags)]
    with zipfile.ZipFile(output) as z:
        assert not [n for n in z.namelist() if "gblicense" in n]


def _page(body: str) -> bytes:
    return ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
            f"<head><title>t</title></head><body>{body}</body></html>").encode()


STORY = "<h3>CHAPTER I</h3>" + "<p>Mr. Jasper walked to the cathedral in the evening light.</p>" * 40
START = "<p>*** START OF THE PROJECT GUTENBERG EBOOK, THE BOOK ***</p>"
LICENCE = "<p>Project Gutenberg-tm works. Project Gutenberg-tm terms. Project Gutenberg-tm gifts.</p>"


def test_chapters_sharing_a_page_with_the_start_line_are_kept():
    """A real book lost 16 of 23 chapters: its big pages also held the licence lines."""
    reason, page = judge_page(_page("<p>The Project Gutenberg EBook of the book</p>" + START + STORY))
    assert reason == CUT_REASON
    text = page.decode()
    assert text.count("Mr. Jasper walked") == 40 and "CHAPTER I" in text
    assert "GUTENBERG" not in text.upper()


@pytest.mark.parametrize("footer", [
    "<p>*** END OF THE PROJECT GUTENBERG EBOOK, THE BOOK ***</p>" + LICENCE,
    "<hr/>*** END OF THE PROJECT GUTENBERG EBOOK, THE BOOK ***<p>This file should be named x.txt</p>",
    "<div>End of Project Gutenberg's The Book, by A Writer*** END OF THIS PROJECT GUTENBERG EBOOK "
    "THE BOOK ***<div><p>licence</p></div></div>",
])
def test_chapters_sharing_a_page_with_the_end_line_are_kept(footer):
    reason, page = judge_page(_page(f"<div>{STORY}</div>{footer}"))
    assert reason == CUT_REASON
    text = page.decode()
    assert text.count("Mr. Jasper walked") == 40
    assert "GUTENBERG" not in text.upper() and "licence" not in text and "should be named" not in text
    etree.fromstring(page)                                  # still well formed


def test_a_page_with_both_lines_keeps_only_what_is_between():
    page = judge_page(_page(f"<p>header</p>{START}{STORY}<p>*** END OF THIS PROJECT GUTENBERG "
                            "EBOOK X ***</p><p>footer</p>"))[1].decode()
    assert page.count("Mr. Jasper walked") == 40 and "header" not in page and "footer" not in page


def test_a_page_with_nothing_but_the_header_is_left_out():
    reason, page = judge_page(_page("<p>The Project Gutenberg EBook of X</p>" + START + "<p>Produced by Y</p>"))
    assert reason and page is None


def test_a_page_whose_line_cannot_be_located_is_kept_whole():
    split = "<p><b>***</b> START OF THE PROJECT GUTENBERG EBOOK X ***</p>"
    assert judge_page(_page(split + STORY * 3)) == ("", None)


def test_a_long_story_page_is_not_dropped_for_naming_the_licence():
    assert judge_page(_page(STORY * 20 + LICENCE)) == ("", None)


def test_a_book_in_big_pages_keeps_every_chapter(tmp_path):
    book = build_omnibus(tmp_path / "saga.epub", 1, 2)
    big = tmp_path / "big.epub"
    with zipfile.ZipFile(book) as a, zipfile.ZipFile(big, "w") as b:
        for info in a.infolist():
            data = a.read(info.filename)
            if info.filename.endswith("v1c1.xhtml"):
                data = _page(START + STORY)
            if info.filename.endswith("v1c2.xhtml"):
                data = _page(STORY + "<p>*** END OF THE PROJECT GUTENBERG EBOOK X ***</p>" + LICENCE)
            b.writestr(info, data)
    path, removed = clean_volume(big, tmp_path / "volumes")
    assert [why for _, why in removed] == [CUT_REASON, CUT_REASON]
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None and z.namelist()[0] == "mimetype"
        for chapter in ("v1c1.xhtml", "v1c2.xhtml"):
            text = z.read(f"OEBPS/{chapter}").decode()
            assert text.count("Mr. Jasper walked") == 40 and "GUTENBERG" not in text.upper()
