"""The user's own choice of model per engine (fake CLIs)."""
import json

import pytest

import translate_book
from src.core.agent import engines, models
from src.core.llm.providers.fallback import reset_breakers
from tests.unit.agent.test_pipeline_e2e import (  # noqa: F401 - env is a fixture
    HERE, book_dir, calls, env, is_translation, upload)

RUN = ["--non-fiction", "--no-refine"]


def test_banned_free_preview_and_orchestrator_models_are_never_offered():
    for name in ("claude-opus-5-5-high", "claude-fable-5", "opencode/beam-free", "x-preview", "gemini-pro-orchestrator"):
        assert not models.allowed_choice(name), name
    assert models.allowed_choice("gemini-3.8-flash-medium") and models.allowed_choice("gpt-6-luna@medium")
    assert not models.allowed_choice("")


def test_the_choices_of_an_engine_start_with_the_recommendation(env, monkeypatch):
    listing = env / "agy_list.py"
    listing.write_text("#!/usr/bin/env python3\nprint('Fetching available models...')\n"
                       "for m in ('gemini-3.8-flash-low', 'gemini-3.8-flash-medium', 'claude-opus-5-5-high', 'gemini-3.8-flash-high'):\n"
                       "    print(m + '\\t' + m.title())\n")
    listing.chmod(0o755)
    monkeypatch.setenv("AGY_PATH", str(listing))
    found = engines.model_choices(["agy", "claude", "opencode"])
    assert found["agy"] == {"recommended": "gemini-3.8-flash-high",
                            "choices": ["gemini-3.8-flash-high", "gemini-3.8-flash-low", "gemini-3.8-flash-medium"]}
    assert found["claude"] == {"recommended": "sonnet", "choices": ["sonnet", "haiku"]}
    assert "opencode" not in found                       # no recommended model: cannot be used


def test_a_chosen_model_translates_and_can_be_taken_back(env, capsys, monkeypatch):
    monkeypatch.setenv("AGENT_ENGINES", "agy")
    upload(env, volumes=2, chapters=1)
    choose = ["--engine-model", "agy=gemini-3.8-flash-medium"]
    assert translate_book.main([*RUN, "--volumes", "1", *choose]) == 0
    made = calls(env)
    assert {c["model"] for c in made} == {"gemini-3.8-flash-medium"}     # light work too
    state = json.loads((book_dir(env) / "state.json").read_text())
    assert state["lock"] == {"engine": "agy", "model": "gemini-3.8-flash-medium", "picked": "yes"}

    reset_breakers()
    before = len(made)
    source = str(book_dir(env) / "source" / "saga.epub")
    assert translate_book.main(["-i", source, *RUN]) == 0                # choice taken back
    translated = [c for c in calls(env)[before:] if is_translation(c)]
    assert {c["model"] for c in translated} == {"gemini-3.8-flash-high"}
    assert "picked" not in json.loads((book_dir(env) / "state.json").read_text())["lock"]

    capsys.readouterr()
    assert translate_book.main(["--detect", *choose]) == 0               # not the cached answer
    [found] = json.loads(capsys.readouterr().out)
    assert found["models"] == {"sonnet": "gemini-3.8-flash-medium", "haiku": "gemini-3.8-flash-medium"}


@pytest.mark.parametrize("choice", ["agy=claude-opus-5-5-high", "claude=claude-fable-5", "nobody=x", "agy"])
def test_a_choice_that_is_not_allowed_is_refused(env, choice):
    with pytest.raises(SystemExit):
        translate_book.main(["--detect", "--engine-model", choice])
