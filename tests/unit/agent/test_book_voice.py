"""A book's main engine: waiting for it, or switching while keeping its voice (fake CLIs)."""
import json

import zipfile

import translate_book
from src.core.agent import final_check
from src.core.llm import voice
from src.core.llm.providers.fallback import reset_breakers
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_pipeline_e2e import (  # noqa: F401 - env is a fixture
    HERE, book_dir, calls, env, is_translation, upload)

RUN = ["--non-fiction", "--no-refine"]
ONE = [*RUN, "--one-engine"]


def two_engines(monkeypatch):
    monkeypatch.setenv("AGENT_ENGINES", "claude,codex")


def claude_limited(env, monkeypatch, marker="</TRANSLATION>", probe_too=False):
    """The fake claude, answering "usage limit" to every request that holds ``marker``."""
    wrapper = env / "claude_limited.py"
    condition = "True" if probe_too else f"{marker!r} in data + ' '.join(sys.argv)"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport json, subprocess, sys\n"
        "data = sys.stdin.read()\n"
        f"if {condition}:\n"
        "    print(json.dumps({'is_error': True, 'result': 'Usage limit reached', 'api_error_status': 429}))\n"
        "    sys.exit(1)\n"
        f"sys.exit(subprocess.run([{str(HERE / 'fake_claude.py')!r}] + sys.argv[1:], input=data, text=True).returncode)\n")
    wrapper.chmod(0o755)
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(wrapper))


def claude_back(monkeypatch, env):
    reset_breakers()
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(HERE / "fake_claude.py"))
    (env / "books" / ".engines.json").unlink(missing_ok=True)


def status(env):
    return json.loads((env / "books" / "status.json").read_text())


def state(env, folder="saga"):
    return json.loads((env / "books" / folder / "state.json").read_text())


def test_a_book_waits_for_its_engine_instead_of_switching(env, monkeypatch, capsys):
    two_engines(monkeypatch)
    upload(env, volumes=1, chapters=2)
    claude_limited(env, monkeypatch)
    assert translate_book.main(ONE) == 3
    assert "Waiting for Claude" in capsys.readouterr().out
    assert not any(c["provider"] == "codex" for c in calls(env))          # the backup stays out
    assert status(env)["state"] == "waiting" and status(env)["engine"] == "Claude"
    assert state(env)["lock"] == {"engine": "claude", "model": "sonnet"}

    # claude's limit still on at the next try, when even its test question is refused
    claude_limited(env, monkeypatch, probe_too=True)
    reset_breakers()
    (env / "books" / ".engines.json").unlink(missing_ok=True)
    source = str(book_dir(env) / "source" / "saga.epub")
    assert translate_book.main(["-i", source, *ONE]) == 3
    assert not any(c["provider"] == "codex" for c in calls(env))

    claude_back(monkeypatch, env)
    assert translate_book.main(["-i", source, *ONE, "--profile", "economy"]) == 0
    made = [c for c in calls(env) if is_translation(c)]
    assert {(c["provider"], c["model"]) for c in made} == {("claude", "sonnet")}    # the model stays too
    info = json.loads((book_dir(env) / "book.json").read_text())
    assert info["engine"] == "claude" and info["volumes"][0]["status"] == "completed"


def test_a_book_keeps_its_main_engine_when_the_order_changes(env, monkeypatch):
    two_engines(monkeypatch)
    upload(env, volumes=2, chapters=1)
    assert translate_book.main([*RUN, "--volumes", "1"]) == 0
    monkeypatch.setenv("AGENT_ENGINES", "codex,claude")
    before = len(calls(env))
    source = str(book_dir(env) / "source" / "saga.epub")
    assert translate_book.main(["-i", source, *RUN]) == 0
    assert {c["provider"] for c in calls(env)[before:] if is_translation(c)} == {"claude"}
    # translating it all again chooses anew
    before = len(calls(env))
    assert translate_book.main(["-i", source, *RUN, "--redo"]) == 0
    assert {c["provider"] for c in calls(env)[before:] if is_translation(c)} == {"codex"}


def test_a_limit_while_preparing_waits_and_keeps_nothing_poorer(env, monkeypatch):
    upload(env, volumes=1, chapters=1)
    claude_limited(env, monkeypatch, marker="Write the style guide")
    assert translate_book.main(["--fiction", "--prepare-only"]) == 3
    assert not (book_dir(env) / "style.md").exists()
    claude_back(monkeypatch, env)
    source = str(book_dir(env) / "source" / "saga.epub")
    assert translate_book.main(["-i", source, "--fiction", "--prepare-only"]) == 0
    assert "## Register and address" in (book_dir(env) / "style.md").read_text()


def test_a_book_whose_engine_is_gone_says_how_to_go_on(env, monkeypatch, capsys):
    two_engines(monkeypatch)
    upload(env, volumes=2, chapters=1)
    assert translate_book.main([*RUN, "--volumes", "1"]) == 0
    monkeypatch.setenv("AGENT_ENGINES", "codex")
    source = str(book_dir(env) / "source" / "saga.epub")
    capsys.readouterr()
    assert translate_book.main(["-i", source, *ONE]) == 2
    assert "--one-engine" in capsys.readouterr().out
    assert translate_book.main(["-i", source, *RUN]) == 0
    assert state(env)["lock"]["engine"] == "claude"           # still the book's own engine


def test_the_next_volume_of_a_series_is_written_by_the_same_engine(env, monkeypatch):
    two_engines(monkeypatch)
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    first = build_omnibus(inbox / "Saga Vol. 1.epub", volumes=1, chapters=1)
    assert translate_book.main(["-i", str(first), *RUN]) == 0
    monkeypatch.setenv("AGENT_ENGINES", "codex,claude")
    second = build_omnibus(inbox / "Saga Vol. 2.epub", volumes=1, chapters=1)
    before = len(calls(env))
    assert translate_book.main(["-i", str(second), *RUN]) == 0
    assert {c["provider"] for c in calls(env)[before:] if is_translation(c)} == {"claude"}


def test_a_stand_in_engine_is_shown_the_voice_of_the_main_one(env, monkeypatch):
    two_engines(monkeypatch)
    monkeypatch.setattr(voice, "MIN_CHARS", 20)
    upload(env, volumes=2, chapters=1)
    assert translate_book.main([*RUN, "--volumes", "1"]) == 0
    kept = json.loads((book_dir(env) / "voice.json").read_text())["translate"]
    assert kept["engine"] == "claude-cli" and kept["samples"] and "[id" not in kept["samples"][0]
    assert not any(c["voice"] for c in calls(env))              # the main engine is asked as before

    claude_limited(env, monkeypatch)
    reset_breakers()
    before = len(calls(env))
    source = str(book_dir(env) / "source" / "saga.epub")
    assert translate_book.main(["-i", source, *RUN]) == 0
    stood_in = [c for c in calls(env)[before:] if c["provider"] == "codex" and is_translation(c)]
    assert stood_in and all(c["voice"] for c in stood_in)
    assert json.loads((book_dir(env) / "voice.json").read_text())["translate"] == kept


def test_a_sample_is_cut_clean_and_belongs_to_the_main_engine(tmp_path):
    long = "<TRANSLATION>" + "Kalimat pembuka yang biasa saja. " * 8 + '"Kau datang," katanya. ' \
        + "[id0]Dia menunggu di dekat jendela.[id1] " * 20 + "</TRANSLATION>"
    sample = voice.passage(long)
    assert sample.startswith('"Kau datang,"') and len(sample) <= voice.SAMPLE_CHARS and "[id" not in sample
    assert voice.passage("<TRANSLATION>Pendek.</TRANSLATION>") == ""

    book = voice.Voice(tmp_path / "voice.json", main="claude-cli")
    book.note("classify", "claude-cli", long)
    assert book.reference("classify", "codex") == ""
    book.note("refine", "codex", long.replace("Kau", "Kamu"))      # the main engine is away
    assert book.reference("refine", "codex") == "" and "Kamu datang" in book.reference("refine", "agy")
    book.note("refine", "claude-cli", long)                          # its voice takes over
    again = voice.Voice(tmp_path / "voice.json", main="claude-cli")
    assert "Kau datang" in again.reference("refine", "codex") and again.reference("refine", "claude-cli") == ""
    assert again.copied("refine", "Isi lain. " + sample[:90], asked="Terjemahkan ini.")
    assert not again.copied("refine", sample[:90], asked=sample)
    assert not again.copied("refine", "Jawaban yang sama sekali lain.", asked="")


def test_a_polish_keeps_the_pronouns_of_the_text(env):
    source = build_omnibus(env / "saga.epub", volumes=1, chapters=1)
    assert translate_book.main(["-i", str(source), "--polish-only", "--fiction"]) == 0
    style = (env / "books" / "saga_polish" / "style.md").read_text()
    assert style.count("## Pronouns already in the text") == 1
    assert "## Register and address" not in style and "## Narration" in style     # no rule against it
    assert any("Keep every pronoun" in c["system"] + c["prompt"] for c in calls(env))


def test_pages_written_unlike_the_rest_are_listed(tmp_path):
    def book(name, odd):
        path = tmp_path / name
        build_omnibus(path, volumes=2, chapters=0)
        with zipfile.ZipFile(path) as z:
            entries = {n: z.read(n) for n in z.namelist()}
        usual = "<p>" + "Kau tahu itu. " * 30 + "</p>"
        for page, text in (("OEBPS/v1.xhtml", usual), ("OEBPS/v2.xhtml", odd or usual)):
            entries[page] = entries[page].replace(b"</body>", text.encode() + b"</body>")
        with zipfile.ZipFile(path, "w") as z:
            for n, data in entries.items():
                z.writestr(n, data)
        return path

    same = final_check.check_volume(book("a.epub", ""), book("b.epub", ""), polished=True)
    assert next(c for c in same if c["id"] == "voice")["level"] == "ok"
    changed = final_check.check_volume(book("a.epub", ""),
                                       book("c.epub", "<p>" + "Kamu tahu itu. " * 10 + "</p>"), polished=True)
    found = next(c for c in changed if c["id"] == "voice")
    assert found["level"] == "info" and found["items"] == ["v2.xhtml: kamu, the book mostly kau"]
