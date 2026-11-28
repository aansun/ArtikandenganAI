"""The check made after a translation: what it passes and what it catches."""
import json
import re
import zipfile

import translate_book
from src.core.agent import final_check
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_intake_qa import STORY, _page
from tests.unit.agent.test_pipeline_e2e import book_dir, calls, env, upload  # noqa: F401

LONG = "".join(f"<p>Chapter line {i}: the captain walked slowly along the old stone pier at dawn while the gulls "
               f"circled above the quiet harbour and the fishermen mended their nets.</p>" for i in range(12))
SAME = LONG.replace("captain walked slowly", "kapten berjalan pelan").replace(
    "along the old stone pier at dawn while the gulls circled above the quiet harbour and the fishermen mended their nets",
    "menyusuri dermaga batu tua saat fajar sementara camar berputar di atas pelabuhan sunyi dan nelayan menambal jaring mereka")


def book(tmp_path, name, pages):
    """A fake saga whose chapter pages hold ``pages`` ({file: body})."""
    base = build_omnibus(tmp_path / f"{name}-base.epub", 1, 2)
    made = tmp_path / f"{name}.epub"
    with zipfile.ZipFile(base) as a, zipfile.ZipFile(made, "w") as b:
        for info in a.infolist():
            data = a.read(info.filename)
            for file, body in pages.items():
                if info.filename.endswith(file):
                    data = _page(body) if body is not None else None
            if data is not None:
                b.writestr(info, data)
    return made


def found(source, output, **kw):
    checks = final_check.check_volume(source, output, source_language="English", **kw)
    return {c["id"]: c for c in checks}


def test_a_whole_translation_passes(tmp_path):
    source = book(tmp_path, "s", {"v1c1.xhtml": LONG, "v1c2.xhtml": LONG})
    output = book(tmp_path, "o", {"v1c1.xhtml": SAME, "v1c2.xhtml": SAME})
    result = found(source, output)
    assert {c["level"] for c in result.values() if c["id"] not in ("metadata", "toc")} <= {"ok"}
    assert result["toc"]["items"] == ["Cover"]          # these pages were not through the agent
    assert set(result) == {"file", "pages", "paragraphs", "length", "untranslated", "quotes", "links",
                           "names", "surplus", "splits", "toc", "voice", "metadata"}


def test_missing_and_shortened_text_fails(tmp_path):
    source = book(tmp_path, "s", {"v1c1.xhtml": LONG, "v1c2.xhtml": LONG})
    short = re.sub(r"(Chapter line \d+:)[^<]*", r"\1 kapten.", LONG)
    output = book(tmp_path, "o", {"v1c1.xhtml": short, "v1c2.xhtml": SAME})
    result = found(source, output)
    assert result["length"]["level"] == "fail" and "v1c1" in result["length"]["items"][0]

    dropped = tmp_path / "dropped.epub"
    with zipfile.ZipFile(output) as a, zipfile.ZipFile(dropped, "w") as b:
        for info in a.infolist():
            data = a.read(info.filename)
            if info.filename.endswith(".opf"):
                data = re.sub(rb'<itemref idref="v1c2"/>', b"", data)
            if not info.filename.endswith("v1c2.xhtml"):
                b.writestr(info, data)
    assert found(source, dropped)["pages"]["level"] == "fail"


def test_the_upload_is_compared_so_cleaning_cannot_hide_a_loss(tmp_path):
    upload_ = book(tmp_path, "u", {"v1c1.xhtml": STORY * 3, "v1c2.xhtml": LONG})
    cleaned = tmp_path / "cleaned.epub"
    with zipfile.ZipFile(upload_) as a, zipfile.ZipFile(cleaned, "w") as b:
        for info in a.infolist():
            data = a.read(info.filename)
            if info.filename.endswith(".opf"):
                data = re.sub(rb'<itemref idref="v1c1"/>', b"", data)
            if not info.filename.endswith("v1c1.xhtml"):
                b.writestr(info, data)
    assert found(cleaned, cleaned)["pages"]["level"] == "ok"
    assert found(cleaned, cleaned, upload=upload_)["pages"]["level"] == "fail"


def test_copied_text_dead_links_mixed_quotes_and_runaway_names(tmp_path):
    notes = '<p><a href="v1c2.xhtml#n1">1</a></p>'
    source = book(tmp_path, "s", {"v1c1.xhtml": LONG + notes, "v1c2.xhtml": LONG + '<p id="n1">Tokyo</p>'})
    single = SAME + "<p>" + "'Ya,' katanya. " * 12 + "</p>"
    double = SAME + "<p>" + '"Ya," katanya. ' * 12 + "</p><p>" + "Tokyo kue. " * 30 + "</p>"
    output = book(tmp_path, "o", {"v1c1.xhtml": double + notes, "v1c2.xhtml": single})
    entries = [{"source": "Tokyo", "target": "Tokyo", "decision": "keep"}]
    result = found(source, output, entries=entries)
    assert result["links"]["level"] == "warn" and "n1" in result["links"]["items"][0]
    assert result["quotes"]["level"] == "warn"
    assert result["surplus"]["level"] == "warn" and "Tokyo" in result["surplus"]["items"][0]
    copied = book(tmp_path, "c", {"v1c1.xhtml": LONG, "v1c2.xhtml": SAME})
    assert found(source, copied)["untranslated"]["level"] == "warn"


def test_a_damaged_file_fails_at_once(tmp_path):
    source = book(tmp_path, "s", {})
    bad = tmp_path / "bad.epub"
    bad.write_bytes(b"not a book")
    assert final_check.check_volume(source, bad)[0]["level"] == "fail"


def test_every_translation_ends_with_the_check_and_it_can_be_repeated(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--no-refine"]) == 0
    work = book_dir(env)
    report = json.loads((work / "check.json").read_text())
    assert [v["index"] for v in report["volumes"]] == [1, 2] and report["overall"] in final_check.LEVELS
    assert "check" in json.loads((env / "books" / "status.json").read_text())["times"]

    (work / "check.json").unlink()
    before = len(calls(env))
    assert translate_book.main(["--check", str(work)]) == 0
    assert len(calls(env)) == before                        # no model was asked
    assert len(json.loads((work / "check.json").read_text())["volumes"]) == 2


def test_a_run_stopped_before_the_check_makes_it_next_time(env):  # noqa: F811
    upload(env, volumes=1, chapters=1)
    assert translate_book.main(["--no-refine"]) == 0
    work = book_dir(env)
    (work / "check.json").unlink()
    before = len(calls(env))
    assert translate_book.main(["-i", str(work / "source" / "saga.epub"), "--no-refine"]) == 0
    assert (work / "check.json").exists() and len(calls(env)) == before
