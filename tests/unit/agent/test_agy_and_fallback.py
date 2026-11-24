import asyncio
import json

import pytest

from src.core.llm.base import LLMRequest
from src.core.llm.exceptions import ContextOverflowError, ProviderError
from src.core.llm.providers.agy import MAX_PROMPT_BYTES, AgyProvider
from src.core.llm.providers.fallback import FallbackProvider, reset_breakers


def parse(**envelope):
    return AgyProvider("gemini-3.8-flash-high")._parse(json.dumps(envelope), "", 0)


def test_success_reads_response_and_usage():
    response = parse(status="SUCCESS", response="Halo", usage={"input_tokens": 9, "output_tokens": 2})
    assert response.content == "Halo" and (response.prompt_tokens, response.completion_tokens) == (9, 2)


def test_log_lines_before_the_json_are_ignored():
    text = "[agy] working\n" + json.dumps({"status": "SUCCESS", "response": "ok"})
    assert AgyProvider("m")._parse(text, "", 0).content == "ok"


@pytest.mark.parametrize("message,check", [
    ("invalid model selection", lambda e: e.retryable is False),
    ("You are not logged in", lambda e: e.retryable is False and e.status_code == 401),
    ("quota exhausted", lambda e: e.rate_limited),
    ("input is too long", lambda e: e.context_overflow),
    ("print timeout after 1s", lambda e: e.retryable is True),
])
def test_errors_are_classified(message, check):
    with pytest.raises(ProviderError) as info:
        parse(status="ERROR", response="", error=message)
    assert check(info.value)


def test_command_puts_the_system_prompt_first_and_passes_prompt_as_argument():
    provider = AgyProvider("m", effort="low")
    request = LLMRequest(prompt="USER", system_prompt="SYSTEM", model="gemini-3.8-flash-low",
                         api_key=None, timeout=1)
    cmd = provider._command(request, "agy", provider._full_prompt(request))
    assert cmd[-1] == "-p=SYSTEM\n\nUSER"
    assert cmd[cmd.index("--model") + 1] == "gemini-3.8-flash-low"
    assert cmd[cmd.index("--effort") + 1] == "low"


def test_oversized_prompt_is_refused_as_context_overflow(monkeypatch):
    monkeypatch.setenv("AGY_PATH", __file__)  # any existing file: the size check comes first
    request = LLMRequest(prompt="x" * (MAX_PROMPT_BYTES + 1), system_prompt=None, model="m",
                         api_key=None, timeout=1)
    with pytest.raises(ProviderError) as info:
        asyncio.run(AgyProvider("m")._send(request))
    assert info.value.context_overflow


class Stub:
    display_name = "Stub"

    def __init__(self, model, error=None):
        self.model, self.error, self.seen = model, error, []
        self.provider_name = "stub-" + model      # one breaker per engine, as in real life

    async def _send(self, request):
        self.seen.append(request.model)
        if self.error:
            raise self.error
        from src.core.llm.base import LLMResponse
        return LLMResponse(content=f"from {request.model}")


@pytest.fixture(autouse=True)
def _fresh_breakers():
    reset_breakers()


def fallback(primary, backup, **kwargs):
    return FallbackProvider(primary, backup, "backup-model", **kwargs)


def send(provider):
    request = LLMRequest(prompt="p", system_prompt=None, model="primary-model", api_key=None, timeout=1)
    return asyncio.run(provider._send(request))


def test_primary_answers_when_healthy():
    primary, backup = Stub("primary-model"), Stub("backup-model")
    assert send(fallback(primary, backup)).content == "from primary-model" and not backup.seen


def test_backup_answers_with_its_own_model_when_primary_fails():
    primary = Stub("primary-model", ProviderError("boom", retryable=True))
    backup = Stub("backup-model")
    assert send(fallback(primary, backup)).content == "from backup-model"


def test_context_overflow_is_not_rerouted():
    primary = Stub("p", ProviderError("too long", context_overflow=True))
    backup = Stub("b")
    with pytest.raises(ProviderError):
        send(fallback(primary, backup))
    assert not backup.seen


def test_breaker_skips_a_persistently_failing_primary():
    primary = Stub("p", ProviderError("signed out", retryable=False))
    backup = Stub("b")
    provider = fallback(primary, backup)
    for _ in range(4):
        send(provider)
    assert len(primary.seen) == 1 and len(backup.seen) == 4


def test_breaker_opens_after_repeated_transient_failures():
    primary = Stub("p", ProviderError("flaky", retryable=True))
    provider = fallback(primary, Stub("b"), failure_limit=2)
    for _ in range(5):
        send(provider)
    assert len(primary.seen) == 2


def test_context_overflow_error_type_is_unused_here():
    assert issubclass(ContextOverflowError, Exception)
