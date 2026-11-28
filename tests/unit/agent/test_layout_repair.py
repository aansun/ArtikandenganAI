"""Paragraphs cut inside a sentence, English contents entries and poor source files."""
import json
import zipfile

import translate_book
from src.core.agent import layout_repair
from src.core.epub.token_alignment_fallback import TokenAlignmentFallback, split_blocks
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_intake_qa import _page
from tests.unit.agent.test_pipeline_e2e import book_dir, env, upload  # noqa: F401 - env is a fixture

#: As a lost layout marker leaves them: each break is inside a sentence, the real one inside.
BROKEN = ('<p class="c"><span>Catatan itu selesai.\n\n"Hanya satu hal yang ingin saya ketahui lebih</span></p>\n'
          '<p class="c"><span> jauh," kata <i id="h">Holmes</i> akhirnya.\n\n"Rahasiaku</span></p>\n'
          '<p class="c"><span> sendiri boleh kuceritakan."\n\n"Nah,</span></p>\n'
          '<p class="c"><span> Tuan-tuan, mari.</span></p>')
SOURCE = "<p>One.</p><p>Two.</p><p>Three.</p><p>Four.</p>"


def with_page(tmp_path, name, body):
    base = build_omnibus(tmp_path / f"{name}-base.epub", volumes=1, chapters=1)
    made = tmp_path / f"{name}.epub"
    with zipfile.ZipFile(base) as a, zipfile.ZipFile(made, "w") as b:
        for info in a.infolist():
            data = a.read(info.filename)
            b.writestr(info, _page(body) if info.filename.endswith("v1c1.xhtml") else data)
    return made


def paragraphs(epub):
    with zipfile.ZipFile(epub) as z:
        root = layout_repair._parse(z.read("OEBPS/v1c1.xhtml"))
    return [" ".join("".join(p.itertext()).split()) for p in root.iter("{*}p")], root


def test_paragraphs_cut_inside_a_sentence_are_cut_again_at_the_real_breaks(tmp_path):
    source, output = with_page(tmp_path, "s", SOURCE), with_page(tmp_path, "o", BROKEN)
    assert layout_repair.split_paragraphs(source, output) == ["v1c1.xhtml: 3"]
    assert layout_repair.repair_paragraphs(output) == 3
    texts, root = paragraphs(output)
    assert texts == ["Catatan itu selesai.",
                     '"Hanya satu hal yang ingin saya ketahui lebih jauh," kata Holmes akhirnya.',
                     '"Rahasiaku sendiri boleh kuceritakan."', '"Nah, Tuan-tuan, mari.']
    assert [i.text for i in root.iter("{*}i")] == ["Holmes"]            # inline markup moves along
    assert [i.get("id") for i in root.iter("{*}i")] == ["h"]
    assert all(p.get("class") == "c" for p in root.iter("{*}p"))
    assert layout_repair.split_paragraphs(source, output) == []
    assert layout_repair.repair_paragraphs(output) == 0


def test_breaks_the_author_made_are_left_alone(tmp_path):
    verse = "<p>Who denies and resists change as he fears</p><p>it will lead to something worse, or</p>"
    source, output = with_page(tmp_path, "s", verse), with_page(tmp_path, "o", verse)
    before = output.read_bytes()
    assert layout_repair.split_paragraphs(source, output) == []
    assert layout_repair.repair_paragraphs(output) == 0 and output.read_bytes() == before
    # a blank line that does not add up to the same number of paragraphs: not this defect
    odd = with_page(tmp_path, "odd", "<p>Satu\n\ndua\n\ntiga</p><p>empat.</p>")
    assert layout_repair.repair_paragraphs(odd) == 0


def test_front_matter_entries_of_the_contents_are_worded_in_indonesian(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", volumes=1, chapters=1)
    assert layout_repair.untranslated_contents(book, "Indonesian") == ["Cover"]
    assert layout_repair.untranslated_contents(book, "Spanish") == []
    assert layout_repair.translate_contents(book, "Indonesian") == ["Cover"]
    with zipfile.ZipFile(book) as z:
        assert z.testzip() is None
        ncx, nav = z.read("OEBPS/toc.ncx").decode(), z.read("OEBPS/nav.xhtml").decode()
    assert "<text>Sampul</text>" in ncx and ">Sampul</a>" in nav and "Chapter 1" in nav
    assert layout_repair.untranslated_contents(book, "Indonesian") == []


def test_a_poor_source_file_is_recognised(tmp_path):
    good = build_omnibus(tmp_path / "good.epub", volumes=1, chapters=1)
    assert layout_repair.source_warnings(good) == []
    bad = with_page(tmp_path, "bad", "<p>���</p>" + "<p>a sentence cut</p><p>in the middle</p>" * 30)
    assert layout_repair.source_warnings(bad) == ["garbled", "broken_paragraphs"]
    assert layout_repair.source_warnings(tmp_path / "missing.epub") == []


def test_lost_markers_return_to_the_paragraph_breaks():
    tags = {"[id0]": "<p>", "[id1]": "</p>\n<p>", "[id2]": "<i>", "[id3]": "</i>", "[id4]": "</p>\n<p>", "[id5]": "</p>"}
    chunk = "[id0]The pencil stopped.[id1]There is [id2]one[id3] point, he said at last.[id4]Not a doubt.[id5]"
    segments, markers = split_blocks(chunk, tags)
    assert markers == ["[id1]", "[id4]", "[id5]"] and len(segments) == 4
    translated = "Pensil itu berhenti.\n\nAda satu hal yang ingin saya ketahui lebih jauh, katanya akhirnya.\n\nTentu."
    aligned = TokenAlignmentFallback().align_blocks(segments, markers, translated, list(tags))
    assert aligned.startswith("[id0]Pensil itu berhenti.[id1]")
    assert "akhirnya.[id4]Tentu.[id5]" in aligned
    assert all(aligned.count(ph) == 1 for ph in tags)
    assert TokenAlignmentFallback().align_blocks(segments, markers, "Satu paragraf saja.", list(tags)) is None


def test_a_translated_book_is_mended_and_an_old_one_can_be_repaired(env, capsys):
    upload(env, volumes=1, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    assert "translated contents entries: Cover" in capsys.readouterr().out
    work = book_dir(env)
    checks = {c["id"]: c["level"] for c in json.loads((work / "check.json").read_text())["volumes"][0]["checks"]}
    assert checks["toc"] == "ok" and checks["splits"] == "ok"

    output = next((work / "translation").glob("*.epub"))
    with zipfile.ZipFile(output) as z:
        entries = {n: z.read(n) for n in z.namelist()}
    entries["OEBPS/v1c1.xhtml"] = _page(BROKEN)                 # as an older version left it
    with zipfile.ZipFile(output, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)
    assert translate_book.main(["--repair", str(work)]) == 0
    assert "mended 3 paragraph break(s)" in capsys.readouterr().out
    assert len(list((work / "previous").glob("*before-repair*"))) == 1
    assert len(paragraphs(output)[0]) == 4
