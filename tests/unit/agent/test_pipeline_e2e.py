"""Whole agent runs against fake `agy` and `claude` binaries (no network)."""
import json
import zipfile
from pathlib import Path

import pytest

import translate_book
from src.core.agent import library
from src.core.agent.epub_metadata import audit_metadata, read_metadata, strip_volume_suffix
from src.core.llm.providers.fallback import reset_breakers
from tests.unit.agent.epub_fixture import build_omnibus

HERE = Path(__file__).parent
AGY_FIRST = ["--translate-provider", "agy-claude"]


@pytest.fixture
def env(tmp_path, monkeypatch):
    reset_breakers()
    monkeypatch.chdir(tmp_path)  # checkpoint DB and uploads are cwd-relative
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(HERE / "fake_claude.py"))
    monkeypatch.setenv("AGY_PATH", str(HERE / "fake_agy.py"))
    monkeypatch.setenv("CODEX_PATH", str(HERE / "fake_codex.py"))
    monkeypatch.setenv("AGENT_ENGINES", "claude")      # tests of the other engines say so themselves
    monkeypatch.setenv("FAKE_LLM_LOG", str(tmp_path / "calls.jsonl"))
    monkeypatch.setenv("BOOKS_DIR", str(tmp_path / "books"))
    return tmp_path


def calls(tmp_path):
    return [json.loads(line) for line in (tmp_path / "calls.jsonl").read_text().splitlines()]


def is_translation(call) -> bool:
    return "</TRANSLATION>" in call["system"] + call["prompt"] and "<NER_JSON>" not in (
        call["system"] + call["prompt"])


def upload(env, volumes=3, chapters=2, name="saga.epub"):
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    return build_omnibus(inbox / name, volumes=volumes, chapters=chapters)


def book_dir(env):
    return env / "books" / "saga"


def test_inbox_book_is_filed_split_glossed_translated_and_indexed(env):
    book = upload(env)
    assert translate_book.main(AGY_FIRST) == 0

    work = book_dir(env)
    assert not book.exists() and (work / "source" / "saga.epub").exists()  # moved out of the inbox
    outputs = sorted((work / "translation").glob("*.epub"))
    assert len(outputs) == 3 and all("(Indonesian)" in o.name for o in outputs)

    glossary = json.loads((work / "glossary.json").read_text())
    by_source = {t["source"]: t for t in glossary["terms"]}
    # names are preserved: the model proposed "Aldrik" and "Jalan Baker", the glossary keeps the original
    assert by_source["Aldric"]["target"] == "Aldric" and by_source["Aldric"]["decision"] == "keep"
    assert by_source["Baker Street"]["target"] == "Baker Street"
    assert by_source["Lyra Thorne"]["gender"] == "female" and "Kaldmoor" in by_source
    assert "Doctor" not in by_source                                         # cleanup dropped it
    style = (work / "style.md").read_text()
    assert "## Baseline" in style and "## Register and address" in style
    calibration = (work / "calibration.md").read_text()
    assert "**Source**" in calibration and "**Translation**" in calibration

    info = json.loads((work / "book.json").read_text())
    assert info["glossary_terms"] == 5 and info["polish_pass"] is True
    assert info["style_guide"].endswith("style.md") and info["calibration"].endswith("calibration.md")
    assert info["translate_provider"] == "agy-claude" and info["backup_model"] == "sonnet"
    assert [v["status"] for v in info["volumes"]] == ["completed"] * 3
    assert all(v["metadata_missing"] == [] for v in info["volumes"])

    series = info["title_translated"]
    assert series and series == strip_volume_suffix(read_metadata(outputs[0])["title"])
    index = (env / "books" / "INDEX.md").read_text()
    assert series in index and "saga/translation/" in index

    # metadata of a translated volume is complete
    meta = read_metadata(outputs[1])
    assert meta["language"] == "id" and meta["creators"] == ["Jane Author"]
    assert meta["title"] == "Fake Saga - Volume 2"         # the original title is kept
    assert series == "Fake Saga" and meta["series"] == series and meta["series_index"] == "2"
    assert read_metadata(outputs[0])["series"] == series          # one series across volumes
    assert meta["subjects"] == ["Novel ringan" if info["genre"] == "light_novel" else "Fiksi"]
    assert meta["date"]
    assert meta["source"].startswith("Fake Saga") and meta["cover"]
    assert audit_metadata(outputs[1], expect_series=True) == []
    with zipfile.ZipFile(outputs[1]) as z:
        assert z.testzip() is None
        opf = z.read("OEBPS/content.opf").decode()
    assert "belongs-to-collection" in opf and "dcterms:modified" in opf


def test_agy_translates_claude_does_glossary_and_no_opus(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(AGY_FIRST) == 0
    made = calls(env)
    ner = [c for c in made if "<NER_JSON>" in c["system"] + c["prompt"]]
    assert ner and {(c["provider"], c["model"]) for c in ner} == {("claude", "sonnet")}
    translation = [c for c in made if is_translation(c)]
    assert translation and {(c["provider"], c["model"]) for c in translation} == {
        ("agy", "gemini-3.8-flash-high")}
    classify = [c for c in made if "Return exactly this JSON" in c["prompt"]]
    assert {(c["provider"], c["model"]) for c in classify} == {("agy", "gemini-3.8-flash-low")}
    assert not any("opus" in c["model"] for c in made)
    # agy ran in a scratch directory, not in the project or the book folder
    assert all(c["cwd"] != str(env) for c in made if c["provider"] == "agy")
    # the glossary reached the translation prompts of the passages that name Aldric
    assert any(c["glossary"] for c in translation)
    # the style guide is part of the translation instructions
    assert any("saya and Anda" in c["prompt"] for c in translation)
    # the style guide is written by claude sonnet, never agy
    style_calls = [c for c in made if "Write the style guide" in c["prompt"]]
    assert {(c["provider"], c["model"]) for c in style_calls} == {("claude", "sonnet")}
    # fiction gets the polish pass
    assert any("Polish this Indonesian translation" in c["prompt"] for c in made)


def test_claude_backs_up_agy(env, monkeypatch):
    monkeypatch.setenv("FAKE_AGY_ERROR", "quota exhausted for today")
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(AGY_FIRST) == 0
    made = calls(env)
    translation = [c for c in made if is_translation(c) and c["provider"] == "claude"]
    assert translation and {c["model"] for c in translation} == {"sonnet"}
    # the quota error opens the breaker on the first (classification) call: no more agy calls
    assert len([c for c in made if c["provider"] == "agy"]) == 1
    assert len(list((book_dir(env) / "translation").glob("*.epub"))) == 2


def test_rerun_skips_finished_volumes(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main([]) == 0
    before = len(calls(env))
    assert translate_book.main([]) == 0   # nothing in the inbox, nothing unfinished
    assert len(calls(env)) == before
    source = book_dir(env) / "source" / "saga.epub"
    assert translate_book.main(["-i", str(source)]) == 0
    assert len(calls(env)) == before      # finished volumes are not sent again


def test_nonfiction_gets_no_glossary_and_cheaper_tier(env, monkeypatch):
    # agy first here, to see the cheap tier map onto agy's low model
    monkeypatch.setenv("FAKE_GENRE", "children")
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    (inbox / "manual.txt").write_text("The pump must be inspected every month.\n" * 5)
    assert translate_book.main(AGY_FIRST) == 0
    assert not (env / "books" / "manual" / "glossary.json").exists()
    translation = [c for c in calls(env) if is_translation(c)]
    assert {c["model"] for c in translation} == {"gemini-3.8-flash-low"}
    assert (env / "books" / "manual" / "translation").glob("*.txt")


def test_glossary_only_stops_before_translating(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--glossary-only"]) == 0
    assert (book_dir(env) / "glossary.json").exists()
    assert not list((book_dir(env) / "translation").glob("*"))


def test_default_provider_is_claude_only_and_never_touches_agy(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main([]) == 0
    made = calls(env)
    assert {c["provider"] for c in made} == {"claude"}
    assert {c["model"] for c in made if is_translation(c)} == {"sonnet"}
    info = json.loads((book_dir(env) / "book.json").read_text())
    assert info["translate_provider"] == "auto" and info["backup_model"] == ""


def test_translated_title_on_request(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--translate-title"]) == 0
    outputs = sorted((book_dir(env) / "translation").glob("*.epub"))
    title = read_metadata(outputs[0])["title"]
    assert read_metadata(outputs[0])["series"] == strip_volume_suffix(title)


def test_refresh_metadata_fixes_finished_volumes_without_translating(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--translate-title"]) == 0
    before = len(calls(env))
    assert translate_book.main(["-i", str(book_dir(env) / "source" / "saga.epub"),
                                "--refresh-metadata"]) == 0
    assert len(calls(env)) == before                      # nothing re-translated
    outputs = sorted((book_dir(env) / "translation").glob("*.epub"))
    assert read_metadata(outputs[0])["title"] == "Fake Saga - Volume 1"


def test_no_refine_skips_the_polish_pass(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--no-refine"]) == 0
    assert not any("Polish this Indonesian translation" in c["prompt"] + c["system"]
                   for c in calls(env))
    assert json.loads((book_dir(env) / "book.json").read_text())["polish_pass"] is False


def test_an_edited_style_guide_and_glossary_are_used_as_is(env):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--glossary-only"]) == 0
    work = book_dir(env)
    (work / "style.md").write_text("# Style guide\n\n## Register and address\n- Always use kamu.\n")
    (work / "calibration.md").unlink()
    before = len(calls(env))
    assert translate_book.main(["-i", str(work / "source" / "saga.epub"), "--no-refine"]) == 0
    new = calls(env)[before:]
    assert not any("Write the style guide" in c["prompt"] for c in new)       # style not rewritten
    assert any("Always use kamu" in c["system"] + c["prompt"] for c in new if is_translation(c))
    assert not any("<NER_JSON>" in c["system"] + c["prompt"] for c in new)    # glossary not rebuilt


def test_opus_is_refused(env):
    with pytest.raises(SystemExit):
        translate_book.main(["-m", "claude-opus-4-6-thinking"])


def test_both_clis_failing_is_reported(env, monkeypatch):
    monkeypatch.setenv("FAKE_AGY_ERROR", "invalid model")
    monkeypatch.setenv("FAKE_CLAUDE_ERROR", "Failed to authenticate: OAuth session expired")
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    (inbox / "plain.txt").write_text("Hello there.\n")
    # no engine passes its test question, so nothing is started and the run says why
    assert translate_book.main(["--non-fiction"]) == 2
    assert not (env / "calls.jsonl").exists()
    assert translate_book.main(["--non-fiction", "--translate-provider", "claude-cli"]) == 1
    assert len(calls(env)) <= 12   # forced engine: fails fast on auth, not the full retry budget


def test_library_lists_unfinished_books(env):
    root = library.books_root()
    assert library.list_inbox(root) == []
    upload(env, volumes=2, chapters=1)
    assert [p.name for p in library.list_inbox(root)] == ["saga.epub"]
