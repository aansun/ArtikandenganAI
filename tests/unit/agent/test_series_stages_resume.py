"""Continuing a stopped run, sharing a series' names, and timing the stages."""
import json
import shutil

import pytest

import translate_book
from src.core.agent import series, stages
from src.core.agent.glossary_builder import build_glossary
from src.core.llm.providers.fallback import reset_breakers
from src.core.refine import chunk_cache
from tests.unit.agent.epub_fixture import build_omnibus
from tests.unit.agent.test_pipeline_e2e import (HERE, calls, env, is_polish,  # noqa: F401
                                                upload)


@pytest.mark.parametrize("text, expected", [
    ("The Devotion of Suspect X (Detective Galileo Series — Vol. 1) (Keigo Higashino etc.) (z-library.sk)",
     ("Detective Galileo Series", "1")),
    ("Silver Saga - Volume 12", ("Silver Saga", "12")),
    ("Silver Saga, Vol. III", ("Silver Saga", "III")),
    ("A Night Out (Lanterns #2)", ("Lanterns", "2")),
    ("Hikayat Perak Jilid 3", ("Hikayat Perak", "3")),
    ("The Book Thief", None),
    ("And Then There Were None (Agatha Christie) (z-library.sk, 1lib.sk, z-lib.sk)", None),
])
def test_the_series_is_read_from_a_name(text, expected):
    assert series.from_title(text) == expected


def test_the_same_series_means_the_same_name_and_author():
    a = series.Series("Detective Galileo Series", "1", "Higashino, Keigo")
    assert a.same_as(series.Series("detective galileo", "2", "Keigo Higashino"))
    assert a.same_as(series.Series("Detective Galileo", "3", ""))
    assert not a.same_as(series.Series("Detective Galileo", "2", "Someone Else"))
    assert not a.same_as(series.Series("Detective Kaga", "2", "Keigo Higashino"))


def volume(env, number):
    inbox = env / "books" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    return build_omnibus(inbox / f"Fake Saga (Test Series - Vol. {number}).epub", volumes=1, chapters=1)


def test_a_later_added_volume_starts_from_the_names_and_style_of_the_series(env):  # noqa: F811
    first = volume(env, 3)                  # volumes come in any order
    assert translate_book.main(["-i", str(first), "--fiction", "--no-refine"]) == 0
    one = env / "books" / "Fake_Saga_Test_Series_Vol_3"
    one = one if one.exists() else next(p.parent for p in (env / "books").glob("*/book.json"))
    glossary = json.loads((one / "glossary.json").read_text())
    glossary["terms"].insert(0, {"source": "Old Mill", "target": "Kincir Tua", "decision": "translate"})
    glossary["terms"][1]["target"] = "Pilihan Seri"
    chosen_name = glossary["terms"][1]["source"]
    (one / "glossary.json").write_text(json.dumps(glossary))
    (one / "style.md").write_text("# Style guide\n\n## Register and address\n- Always use kamu.\n")

    before = len(calls(env))
    second = volume(env, 1)
    assert translate_book.main(["-i", str(second), "--fiction", "--no-refine"]) == 0
    other = next(p.parent for p in (env / "books").glob("*/book.json") if p.parent != one)
    terms = {t["source"]: t["target"] for t in json.loads((other / "glossary.json").read_text())["terms"]}
    assert terms["Old Mill"] == "Kincir Tua" and terms[chosen_name] == "Pilihan Seri"
    assert "Always use kamu" in (other / "style.md").read_text()
    assert not any("Write the style guide" in c["prompt"] for c in calls(env)[before:])
    assert json.loads((other / "book.json").read_text())["series"] == "Test Series"

    shutil.rmtree(one)                      # a deleted book gives nothing any more
    third = volume(env, 2)
    shutil.rmtree(other)
    assert translate_book.main(["-i", str(third), "--fiction", "--no-refine"]) == 0
    last = next((env / "books").glob("*/glossary.json"))
    assert "Old Mill" not in last.read_text()


def test_another_language_or_series_shares_nothing(env, tmp_path):  # noqa: F811
    book = volume(env, 1)
    assert translate_book.main(["-i", str(book), "--fiction", "--no-refine"]) == 0
    root = env / "books"
    info = series.Series("Test Series", "2", "Jane Author")
    assert len(series.related_books(root, root / "new", info, "Indonesian")) == 1
    assert series.related_books(root, root / "new", info, "Spanish") == []
    assert series.related_books(root, root / "new", series.Series("Other", "1", ""), "Indonesian") == []


def test_a_stopped_polish_pass_continues_where_it_was(env, monkeypatch):  # noqa: F811
    upload(env, volumes=1, chapters=4)
    wrapper, counter = env / "claude_limited.py", env / "polished.count"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport json, subprocess, sys, pathlib\n"
        "data = sys.stdin.read()\n"
        "if 'Polish this Indonesian translation' in data + ' '.join(sys.argv):\n"
        f"    p = pathlib.Path({str(counter)!r}); n = int(p.read_text()) if p.exists() else 0\n"
        "    p.write_text(str(n + 1))\n"
        "    if n >= 2:\n"
        "        print(json.dumps({'is_error': True, 'result': 'Usage limit reached', 'api_error_status': 429}))\n"
        "        sys.exit(1)\n"
        f"sys.exit(subprocess.run([{str(HERE / 'fake_claude.py')!r}] + sys.argv[1:], input=data, text=True).returncode)\n")
    wrapper.chmod(0o755)
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(wrapper))
    translate_book.main(["--fiction"])
    work = env / "books" / "saga"
    cache = list((work / "translation").glob("*" + chunk_cache.SUFFIX))
    assert len(cache) == 1
    first = [c["prompt"] for c in calls(env) if is_polish(c)]
    assert len(first) == 2

    reset_breakers()
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(HERE / "fake_claude.py"))
    assert translate_book.main(["-i", str(work / "source" / "saga.epub"), "--fiction"]) == 0
    all_polished = [c["prompt"] for c in calls(env) if is_polish(c)]
    assert len(all_polished) > 2 and len(set(all_polished)) == len(all_polished)   # no chunk twice
    assert not list((work / "translation").glob("*" + chunk_cache.SUFFIX))
    status = json.loads((env / "books" / "status.json").read_text())
    assert status["state"] == "idle" and set(status["times"]) == {"prepare", "translate", "refine"}
    assert set(json.loads((work / "stages.json").read_text())) == {"prepare", "volumes"}


def test_a_half_written_cache_line_is_ignored(tmp_path):
    path = tmp_path / "c.jsonl"
    chunk_cache.use(path)
    chunk_cache.put("a", "satu")
    with open(path, "a") as f:
        f.write('\n{"key": "b", "te')
    chunk_cache.use(path)
    assert chunk_cache.get("a") == "satu" and chunk_cache.get("b") is None
    chunk_cache.put("c", "tiga")
    chunk_cache.use(path)
    assert chunk_cache.get("c") == "tiga"
    chunk_cache.use(None)
    assert chunk_cache.get("a") is None


def test_a_stopped_glossary_build_does_not_ask_again(tmp_path):
    import asyncio
    from src.core.llm.base import LLMResponse

    class Model:
        def __init__(self, fail_consolidation):
            self.asked, self.fail = 0, fail_consolidation

        async def generate(self, prompt, system_prompt=None, **kw):
            if "Return the cleaned list" in prompt:
                if self.fail:
                    raise KeyboardInterrupt            # the app is closed here
                return LLMResponse(content="nothing")
            self.asked += 1
            return LLMResponse(content='<NER_JSON>[{"source": "Aldric", "target": "Aldric", "category": "character"},'
                                       '{"source": "Lyra", "target": "Lyra", "category": "character"},'
                                       '{"source": "Kaldmoor", "target": "Kaldmoor", "category": "location"}]</NER_JSON>')

    book = tmp_path / "b.txt"
    book.write_text("Aldric met Lyra in Kaldmoor. " * 400)
    out = tmp_path / "glossary.json"
    first = Model(True)
    with pytest.raises(KeyboardInterrupt):
        asyncio.run(build_glossary([book], "English", "Indonesian", first, out))
    assert first.asked >= 1 and not out.exists()
    second = Model(False)
    assert asyncio.run(build_glossary([book], "English", "Indonesian", second, out)) == 3
    assert second.asked == 0 and not (tmp_path / "glossary_parts.json").exists()


def test_stage_times_add_up_across_runs(tmp_path):
    clock_time = [100.0]
    phase = [""]
    path = tmp_path / "stages.json"
    clock = stages.StageClock(path, phase=lambda: phase[0], interval=0, now=lambda: clock_time[0])
    clock.start(stages.PREPARE)
    clock_time[0] += 30
    clock.start(stages.TRANSLATE, 1)
    clock_time[0] += 50
    clock.tick()
    phase[0] = "refine"
    clock_time[0] += 3
    clock.tick()                    # the time since the last look still belongs to the translation
    clock_time[0] += 20
    clock.stop()
    clock_time[0] += 999            # paused: not counted
    again = stages.StageClock(path, interval=0, now=lambda: clock_time[0])
    again.start(stages.REFINE, 1)
    clock_time[0] += 10
    again.stop()
    assert again.seconds(1) == {"prepare": 30, "translate": 53, "refine": 30}
    assert again.seconds(2) == {"prepare": 30, "translate": 0, "refine": 0}
    again.reset(1)
    assert again.seconds(1)["translate"] == 0
