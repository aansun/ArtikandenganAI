import json
from pathlib import Path

import pytest

import translate_book
from src.core.agent import engines
from src.core.llm.providers.chain import ChainProvider, reset_breakers
from tests.unit.agent.test_pipeline_e2e import book_dir, calls, env, is_translation, upload  # noqa: F401

FAKES = Path(__file__).parent


def detect(**kw):
    return {e.name: e for e in engines.detect_engines(**kw)}


def test_active_means_installed_and_answering(env, monkeypatch):  # noqa: F811
    found = detect(order=["claude", "codex", "agy"], refresh=True)
    assert all(e.active for e in found.values())
    assert [e.role for e in found.values()] == ["main", "backup", "backup"]

    monkeypatch.setenv("CLAUDE_CLI_PATH", "/nonexistent/claude")
    monkeypatch.setenv("FAKE_CODEX_ERROR", "Not logged in. Run codex login.")
    found = detect(order=["claude", "codex", "agy"], refresh=True)
    assert found["claude"].reason == "not installed" and not found["claude"].active
    assert not found["codex"].active and "login" in found["codex"].reason.lower()
    assert found["agy"].active and found["agy"].role == "main"      # the first active one leads


def test_the_result_is_cached_and_refresh_probes_again(env, tmp_path, monkeypatch):  # noqa: F811
    cache = tmp_path / "engines.json"
    assert detect(order=["claude"], cache_path=cache)["claude"].active
    monkeypatch.setenv("CLAUDE_CLI_PATH", "/nonexistent/claude")
    assert detect(order=["claude"], cache_path=cache)["claude"].active          # from the cache
    assert not detect(order=["claude"], cache_path=cache, refresh=True)["claude"].active


def test_chain_models_follow_the_engines_and_never_use_opus(env):  # noqa: F811
    found = engines.detect_engines(["claude", "codex", "agy"], refresh=True)
    chain = engines.chain_for(found, "sonnet")
    assert chain == [{"provider": "claude-cli", "model": "sonnet"}, {"provider": "codex", "model": ""},
                     {"provider": "agy", "model": "gemini-3.8-flash-high"}]
    assert engines.chain_for(found, "haiku")[2]["model"] == "gemini-3.8-flash-low"
    with pytest.raises(ValueError):
        engines.chain_for(found, "sonnet", override="opus")


def test_detect_command_prints_json(env, capsys):  # noqa: F811
    assert translate_book.main(["--detect", "--refresh-engines"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert [e["name"] for e in data] == ["claude"] and data[0]["active"] and data[0]["role"] == "main"


def test_inspect_command_describes_a_book(env, capsys, monkeypatch):  # noqa: F811
    from tests.unit.agent.epub_fixture import build_omnibus
    book = build_omnibus(env / "saga.epub", volumes=3, chapters=1)
    assert translate_book.main(["--inspect", str(book)]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["volumes"] == 3 and info["author"] == "Jane Author" and info["title"] == "Fake Saga"
    assert info["kind"] == "fiksi" and info["classified_by"] == "llm" and info["estimated_minutes"] >= 0


def test_codex_is_the_main_engine_when_listed_first(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv("AGENT_ENGINES", "codex,claude")
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    made = calls(env)
    assert {c["provider"] for c in made} == {"codex"}
    assert {c["model"] for c in made if is_translation(c)} == {""}       # the CLI's own model


def test_a_backup_engine_takes_over_when_the_main_one_fails(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv("AGENT_ENGINES", "claude,codex")
    upload(env, volumes=2, chapters=1)
    # claude passes its test question, then every real request fails on quota
    claude = FAKES / "fake_claude.py"
    wrapper = env / "claude_quota.py"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport os, subprocess, sys\n"
        f"data = sys.stdin.read()\nif data.startswith('Reply with the single word OK.'):\n"
        f"    r = subprocess.run([{str(claude)!r}] + sys.argv[1:], input=data, text=True)\n"
        "    sys.exit(r.returncode)\n"
        "import json\nprint(json.dumps({'is_error': True, 'result': 'Usage limit reached', "
        "'api_error_status': 429}))\nsys.exit(1)\n")
    wrapper.chmod(0o755)
    monkeypatch.setenv("CLAUDE_CLI_PATH", str(wrapper))
    assert translate_book.main(["--non-fiction", "--no-refine", "--profile", "economy"]) == 0
    made = calls(env)
    assert any(c["provider"] == "codex" and is_translation(c) for c in made)
    assert len(list((book_dir(env) / "translation").glob("*.epub"))) == 2


def test_status_json_tells_the_app_what_is_running(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    status = json.loads((env / "books" / "status.json").read_text())
    assert status["state"] == "idle" and status["book"] == "saga"
    assert status["phase"] == "translate"     # the app tells the translation pass from the polish pass by this


def test_no_active_engine_is_reported_with_the_reason(env, monkeypatch, capsys):  # noqa: F811
    monkeypatch.setenv("CLAUDE_CLI_PATH", "/nonexistent/claude")
    upload(env)
    assert translate_book.main(["--non-fiction"]) == 2
    assert "No translation engine is active" in capsys.readouterr().out


def test_chain_provider_reports_the_engine_that_answered():
    from src.core.llm.providers.chain import last_engine
    reset_breakers()
    assert last_engine() == "" and ChainProvider


def test_style_is_recommended_from_the_book_and_written_for_the_app(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--prepare-only"]) == 0
    work = book_dir(env)
    choice = json.loads((work / "style.json").read_text())
    assert choice["recommended"] == "sastra" and choice["chosen"] == "sastra"
    assert "diksi kaya" in choice["why"] and [o["id"] for o in choice["options"]] == ["formal", "santai", "sastra"]
    direction = [c for c in calls(env) if "Write the style guide" in c["prompt"]]
    assert direction and "Literary and poetic" in direction[0]["prompt"]


def test_another_style_rewrites_the_style_guide_and_the_samples(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--prepare-only"]) == 0
    work = book_dir(env)
    first = (work / "calibration.md").stat().st_mtime_ns
    source = work / "source" / "saga.epub"
    assert translate_book.main(["-i", str(source), "--prepare-only", "--style", "santai"]) == 0
    choice = json.loads((work / "style.json").read_text())
    assert choice["chosen"] == "santai" and choice["recommended"] == "sastra"
    written = [c for c in calls(env) if "Write the style guide" in c["prompt"]]
    assert len(written) == 2 and "Casual and modern" in written[1]["prompt"]
    assert (work / "calibration.md").stat().st_mtime_ns > first
    # asking for the same style again changes nothing
    before = len(calls(env))
    assert translate_book.main(["-i", str(source), "--prepare-only", "--style", "santai"]) == 0
    assert len(calls(env)) == before


def test_style_falls_back_to_the_genre_without_an_answer():
    from types import SimpleNamespace
    from src.core.agent.style import heuristic_style
    assert heuristic_style(SimpleNamespace(genre="literary_fiction"))["id"] == "sastra"
    assert heuristic_style(SimpleNamespace(genre="light_novel"))["id"] == "santai"
    assert heuristic_style(SimpleNamespace(genre="fiction_novel"))["id"] == "formal"
