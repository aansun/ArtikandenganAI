"""The model list the app imposes, and the OpenCode engine (a fake binary, no network)."""
import asyncio
import json

import pytest

import translate_book
from src.core.agent import engines, models
from src.core.llm import ProviderConfig, create_llm_provider
from src.core.llm.base import LLMRequest
from src.core.llm.exceptions import ProviderError
from src.core.llm.providers.opencode_cli import DEFAULT_SYSTEM, agent_config
from tests.unit.agent.test_pipeline_e2e import book_dir, calls, env, is_translation, upload  # noqa: F401

SONNET = "opencode/claude-sonnet-5-5"


def opencode(**kw):
    return engines.detect_engines(["opencode"], refresh=True, **kw)[0]


def ask(system="Translate.", prompt="Hello", model=SONNET):
    provider = create_llm_provider(ProviderConfig(provider="opencode", model=model))
    return asyncio.run(provider._send(LLMRequest(
        prompt=prompt, system_prompt=system, model=model, api_key=None, timeout=60)))


def test_every_listed_model_is_allowed():
    for engine, tiers in models.RECOMMENDED.items():
        assert set(tiers) == {"haiku", "sonnet"}, engine
        for listed in tiers.values():
            for r in listed:
                assert not any(b in r.model for b in models.BANNED)
                assert "free" not in r.model and "preview" not in r.model


def test_an_engine_without_a_tested_model_cannot_be_used(env):  # noqa: F811
    engine = opencode()
    assert not engine.active and engine.reason.startswith("no recommended model yet")
    assert not (env / "calls.jsonl").exists()                  # nothing was sent to it


def test_a_candidate_that_answers_makes_the_engine_usable_when_asked_for(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv(models.ALLOW_UNTESTED_ENV, "1")
    engine = opencode()
    assert engine.active
    assert engine.models == {"sonnet": SONNET, "haiku": "opencode/claude-haiku-5-5"}
    assert engines.chain_for([engine], "haiku") == [
        {"provider": "opencode", "model": "opencode/claude-haiku-5-5"}]


def test_only_a_model_the_sign_in_offers_and_that_answers_is_chosen(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv(models.ALLOW_UNTESTED_ENV, "1")
    monkeypatch.setenv("FAKE_OPENCODE_MODELS", "opencode/something-else,opencode/space-free")
    engine = opencode()
    assert not engine.active and "no recommended model is available" in engine.reason

    monkeypatch.setenv("FAKE_OPENCODE_MODELS", f"{SONNET},opencode/gemini-3.8-flash")
    monkeypatch.setenv("FAKE_OPENCODE_REFUSES", SONNET)         # listed, but it does not answer
    engine = opencode()
    assert engine.active and engine.models["sonnet"] == "opencode/gemini-3.8-flash"


def test_a_listed_model_is_not_proof_of_a_working_key(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv(models.ALLOW_UNTESTED_ENV, "1")
    monkeypatch.setenv("FAKE_OPENCODE_ERROR", "This API key has expired.")
    engine = opencode()
    assert not engine.active and "expired" in engine.reason


def test_a_cached_candidate_is_dropped_once_untested_models_are_not_allowed(env, tmp_path, monkeypatch):  # noqa: F811
    cache = tmp_path / "engines.json"
    monkeypatch.setenv(models.ALLOW_UNTESTED_ENV, "1")
    assert opencode(cache_path=cache).active
    monkeypatch.delenv(models.ALLOW_UNTESTED_ENV)
    assert not engines.detect_engines(["opencode"], cache_path=cache)[0].active


def test_codex_gets_the_listed_model_and_effort(env):  # noqa: F811
    from src.core.llm.providers.codex_cli import CodexProvider
    cmd = CodexProvider()._command(LLMRequest(
        prompt="x", system_prompt=None, model="gpt-6-luna@high", api_key=None, timeout=1), "codex", "o")
    assert cmd[cmd.index("-m") + 1] == "gpt-6-luna"
    assert 'model_reasoning_effort="high"' in cmd and cmd[-1] == "-"


def test_a_request_runs_without_tools_or_the_users_rules(env):  # noqa: F811
    system = 'Keep {env:HOME} and {file:~/.ssh/id} as written. "quoted" \\{x}'
    answer = ask(system=system, prompt="Hello")
    assert answer.content and answer.prompt_tokens == 13 and answer.completion_tokens == 5
    assert answer.cost == pytest.approx(0.002) and not answer.output_truncated
    call = calls(env)[-1]
    assert call["system"] == system and call["prompt"] == "Hello"
    assert call["agent"]["tools"] == {"*": False} and call["agent"]["permission"] == {"*": "deny"}
    assert "--pure" in call["args"] and "--auto" not in call["args"]
    assert call["no_rules"] == ["1", "1"] and call["config_home"].endswith("config")
    assert call["cwd"].endswith("work")


def test_the_prompt_cannot_trigger_a_configuration_substitution():
    raw = agent_config("{env:SECRET} {file:/etc/hosts}")
    assert "{env:" not in raw and "{file:" not in raw
    assert json.loads(raw)["agent"]["translator"]["prompt"] == "{env:SECRET} {file:/etc/hosts}"
    assert json.loads(agent_config(None))["agent"]["translator"]["prompt"] == DEFAULT_SYSTEM


def test_an_answer_that_used_a_tool_is_discarded(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv("FAKE_OPENCODE_TOOL", "1")
    with pytest.raises(ProviderError) as caught:
        ask()
    assert "tool" in caught.value.message and not caught.value.retryable


@pytest.mark.parametrize("message, expect", [
    ("This API key has expired.", {"status_code": 401, "retryable": False}),
    ("Rate limit exceeded", {"rate_limited": True}),
    ("maximum context length is 8000 tokens", {"context_overflow": True}),
])
def test_errors_are_classified(env, monkeypatch, message, expect):  # noqa: F811
    monkeypatch.setenv("FAKE_OPENCODE_ERROR", message)
    with pytest.raises(ProviderError) as caught:
        ask()
    for name, value in expect.items():
        assert getattr(caught.value, name) == value


def test_a_whole_book_can_be_translated_with_opencode(env, monkeypatch):  # noqa: F811
    monkeypatch.setenv(models.ALLOW_UNTESTED_ENV, "1")
    monkeypatch.setenv("AGENT_ENGINES", "opencode")
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    made = calls(env)
    assert {c["provider"] for c in made} == {"opencode"}
    assert all("free" not in c["model"] for c in made)
    assert any(is_translation(c) for c in made)
    assert len(list((book_dir(env) / "translation").glob("*.epub"))) == 2


def test_detect_prints_the_model_of_each_engine(env, capsys):  # noqa: F811
    assert translate_book.main(["--detect", "--refresh-engines", "--engines", "claude,opencode"]) == 0
    found = {e["name"]: e for e in json.loads(capsys.readouterr().out)}
    assert found["claude"]["models"] == {"sonnet": "sonnet", "haiku": "haiku"}
    assert found["opencode"]["models"] == {} and not found["opencode"]["active"]
