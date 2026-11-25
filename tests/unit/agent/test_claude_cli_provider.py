import json

import pytest

from src.core.llm.exceptions import ProviderError
from src.core.llm.providers.claude_cli import ClaudeCLIProvider


def parse(**envelope):
    return ClaudeCLIProvider("sonnet")._parse(json.dumps(envelope), "", 0)


def test_success_reads_text_usage_and_cost():
    response = parse(is_error=False, result="Halo", stop_reason="end_turn", total_cost_usd=0.5,
                     usage={"input_tokens": 7, "cache_read_input_tokens": 3, "output_tokens": 2})
    assert response.content == "Halo"
    assert (response.prompt_tokens, response.completion_tokens) == (10, 2)
    assert response.cost == 0.5


@pytest.mark.parametrize("message,check", [
    ("Failed to authenticate: OAuth session expired", lambda e: e.retryable is False),
    ("Claude AI usage limit reached", lambda e: e.rate_limited),
    ("Prompt is too long", lambda e: e.context_overflow),
    ("something odd", lambda e: e.retryable is True),
])
def test_errors_are_classified(message, check):
    with pytest.raises(ProviderError) as info:
        parse(is_error=True, result=message)
    assert check(info.value)


def test_non_json_output_is_a_retryable_transport_error():
    with pytest.raises(ProviderError) as info:
        ClaudeCLIProvider("sonnet")._parse("garbage", "boom", 2)
    assert info.value.retryable and info.value.transport


def test_command_disables_tools_and_passes_system_prompt():
    from src.core.llm.base import LLMRequest
    request = LLMRequest(prompt="p", system_prompt="be brief", model="opus", api_key=None, timeout=1)
    cmd = ClaudeCLIProvider("sonnet", effort="low")._command(request, "claude")
    assert cmd[cmd.index("--tools") + 1] == ""
    assert cmd[cmd.index("--model") + 1] == "opus"
    assert cmd[cmd.index("--system-prompt") + 1] == "be brief"
    assert cmd[cmd.index("--effort") + 1] == "low"
