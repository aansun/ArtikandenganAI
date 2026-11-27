"""Polish only: a book that is already translated is polished and checked (fake `claude`)."""
import json
import zipfile

import pytest

import translate_book
from src.core.agent import final_check
from src.core.agent.epub_metadata import read_metadata
from src.core.llm.providers.fallback import reset_breakers
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_pipeline_e2e import (  # noqa: F401 - env is a fixture
    HERE, calls, env, is_polish, is_translation)

POLISH = ["--polish-only", "--fiction"]


def mine(env, **options):
    """A translated book where the user keeps it, outside the library."""
    folder = env / "my books"
    folder.mkdir(exist_ok=True)
    return build_omnibus(folder / "saga.epub", **{"volumes": 2, "chapters": 2, **options})


def work(env):
    return env / "books" / "saga_polish"


def book(env):
    return json.loads((work(env) / "book.json").read_text())


def claude_failing_for(env, monkeypatch, marker, status, message):
    """The fake claude, answering with an error to every request that holds ``marker``."""
    wrapper = env / "claude_failing.py"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport json, subprocess, sys\n"
        "data = sys.stdin.read()\n"
        f"if all(m in data + ' '.join(sys.argv) for m in {marker!r}):\n"
        f"    print(json.dumps({{'is_error': True, 'result': {message!r}, 'api_error_status': {status}}}))\n"
        "    sys.exit(1)\n"
        f"sys.exit(subprocess.run([{str(HERE / 'fake_claude.py')!r}] + sys.argv[1:], input=data, text=True).returncode)\n")
    wrapper.chmod(0o755)
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(wrapper))


def claude_healthy_again(monkeypatch):
    reset_breakers()
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(HERE / "fake_claude.py"))


def test_a_translated_book_is_polished_and_checked_not_translated(env):
    source = mine(env, boilerplate=True)
    original = source.read_bytes()
    assert translate_book.main(["-i", str(source), *POLISH]) == 0

    assert source.read_bytes() == original                       # the user's file is left as it is
    info = book(env)
    assert info["mode"] == "polish" and info["polish_pass"] is True
    assert info["source_language"] == info["target_language"] == "Indonesian"
    assert info["title"] == info["title_translated"] == "Fake Saga"
    [volume] = info["volumes"]                                    # not split, though it has two parts
    assert volume["status"] == "completed" and volume["output"].endswith("(Indonesian, polished).epub")

    made = calls(env)
    assert any(is_polish(c) for c in made)
    assert not any("<NER_JSON>" in c["system"] + c["prompt"] for c in made)      # no glossary
    assert not (work(env) / "glossary.json").exists() and not (work(env) / "calibration.md").exists()
    assert any("Past tense, plain diction" in c["system"] + c["prompt"] for c in made if is_polish(c))   # the style
    assert not any(is_translation(c) and not is_polish(c) and "Hello" in c["prompt"] for c in made)

    with zipfile.ZipFile(volume["output"]) as z:
        assert z.testzip() is None
        assert "OEBPS/gbhead.xhtml" in z.namelist()               # nothing is cut from the user's book
        assert "Selesai." in z.read("OEBPS/v1c1.xhtml").decode()
    assert read_metadata(volume["output"])["language"] == "en"   # metadata is not rewritten

    report = json.loads((work(env) / "check.json").read_text())
    found = {c["id"]: c["level"] for c in report["volumes"][0]["checks"]}
    assert found["pages"] == "ok" and found["polish"] == "ok" and found["paragraphs"] == "ok"
    assert "untranslated" not in found
    assert not list((work(env) / "translation").glob("*.jsonl"))  # the polish cache is cleared
    status = json.loads((env / "books" / "status.json").read_text())
    assert status["polish"] is True and status["state"] == "idle"

    logged = [json.loads(line) for path in (env / "books" / "_activity-log").glob("*.jsonl")
              for line in path.read_text().splitlines()]
    [done] = [r for r in logged if r["event"] == "volume"]
    assert done["mode"] == "polish" and done["chunks_total"] > 0
    assert translate_book.main(["--check", str(work(env))]) == 0
    again = json.loads((work(env) / "check.json").read_text())
    assert again["volumes"] == report["volumes"]


def test_a_translation_of_the_same_file_has_its_own_folder(env):
    source = mine(env, volumes=1)
    assert translate_book.main(["-i", str(source), *POLISH]) == 0
    assert translate_book.main(["-i", str(source), "--fiction", "--no-refine"]) == 0
    assert book(env)["mode"] == "polish"
    translated = json.loads((env / "books" / "saga" / "book.json").read_text())
    assert translated["mode"] == "translate"
    assert translate_book.main(["-i", str(source), *POLISH, "--workdir", str(env / "books" / "saga")]) == 2


def test_a_paused_polish_goes_on_where_it_stopped_without_the_flag(env, monkeypatch):
    source = mine(env, volumes=1, chapters=3)
    claude_failing_for(env, monkeypatch, ["Polish this Indonesian translation", "chapter 3"],
                       429, "Usage limit reached")
    assert translate_book.main(["-i", str(source), *POLISH, "--chunk-tokens", "40"]) == 3     # waiting
    assert book(env)["volumes"][0]["status"] == "rate_limited"
    cache = list((work(env) / "translation").glob("*.polish-cache.jsonl"))
    assert cache and cache[0].read_text().strip()
    first = [c for c in calls(env) if is_polish(c)]

    claude_healthy_again(monkeypatch)
    before = len(calls(env))
    # as the queue worker does it: the unfinished book is found in the library, no flag is given
    assert translate_book.main(["--chunk-tokens", "40"]) == 0
    second = [c for c in calls(env)[before:] if is_polish(c)]
    assert book(env)["mode"] == "polish" and book(env)["volumes"][0]["status"] == "completed"
    assert not (env / "books" / "saga").exists()
    assert second and not {c["prompt"] for c in second} & {c["prompt"] for c in first}
    assert not list((work(env) / "translation").glob("*.jsonl"))
    assert len(list((work(env) / "translation").glob("*.epub"))) == 1       # no partial file stays


def test_a_pass_that_polished_nothing_is_a_failure_and_can_be_retried(env, monkeypatch, capsys):
    source = mine(env, volumes=1)
    claude_failing_for(env, monkeypatch, ["Polish this Indonesian translation"], 400, "bad request")
    assert translate_book.main(["-i", str(source), *POLISH]) == 1
    assert "Nothing was polished" in capsys.readouterr().out
    volume = book(env)["volumes"][0]
    assert volume["status"] == "failed" and "Nothing was polished" in volume["error"]
    assert not list((work(env) / "translation").glob("*.epub"))

    claude_healthy_again(monkeypatch)
    assert translate_book.main(["-i", str(work(env) / "source" / "saga.epub"), *POLISH]) == 0
    [volume] = book(env)["volumes"]
    assert volume["status"] == "completed" and volume["output"].endswith("(Indonesian, polished).epub")


def test_polishing_again_keeps_the_earlier_result(env):
    source = mine(env, volumes=1)
    assert translate_book.main(["-i", str(source), *POLISH]) == 0
    before = len([c for c in calls(env) if is_polish(c)])
    assert translate_book.main(["-i", str(work(env) / "source" / "saga.epub"), "--redo"]) == 0
    assert len([c for c in calls(env) if is_polish(c)]) == 2 * before
    assert len(list((work(env) / "previous").glob("*.epub"))) == 1


def test_preparing_stops_after_the_style_so_it_can_be_chosen(env):
    source = mine(env, volumes=1)
    assert translate_book.main(["-i", str(source), *POLISH, "--prepare-only"]) == 0
    assert (work(env) / "style.json").exists() and (work(env) / "style.md").exists()
    assert not any(is_polish(c) for c in calls(env))


@pytest.mark.parametrize("flags", [["--polish-only"], ["--polish-only", "-i", "x.epub", "--no-refine"]])
def test_flags_that_make_no_sense_are_refused(env, flags):
    with pytest.raises(SystemExit):
        translate_book.main(flags)


def test_only_an_epub_can_be_polished_and_nothing_is_moved(env, capsys):
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True)
    plain = inbox / "plain.txt"
    plain.write_text("Halo.\n")
    assert translate_book.main(["-i", str(plain), "--polish-only"]) == 2
    assert "one EPUB file" in capsys.readouterr().out
    assert plain.exists() and not (env / "books" / "plain_polish").exists()


def test_pages_the_polish_pass_left_alone_are_listed(tmp_path):
    long_page = "<p>" + "kata " * 120 + "</p>"

    def make(name, second):
        path = tmp_path / name
        build_omnibus(path, volumes=1, chapters=0)
        with zipfile.ZipFile(path) as z:
            entries = {n: z.read(n) for n in z.namelist()}
        entries["OEBPS/v1.xhtml"] = entries["OEBPS/v1.xhtml"].replace(b"</body>", second.encode() + b"</body>")
        with zipfile.ZipFile(path, "w") as z:
            for n, data in entries.items():
                z.writestr(n, data)
        return path

    before = make("before.epub", long_page)
    untouched = final_check.check_volume(before, before, polished=True)
    polish = next(c for c in untouched if c["id"] == "polish")
    assert polish["level"] == "warn" and polish["items"] == ["v1.xhtml"]
    changed = final_check.check_volume(before, make("after.epub", long_page.replace("kata", "kalimat", 1)),
                                       polished=True)
    assert next(c for c in changed if c["id"] == "polish")["level"] == "ok"
