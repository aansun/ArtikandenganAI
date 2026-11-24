"""
Claude CLI provider.

Runs every request through the ``claude`` command line tool in headless mode
(``claude -p``). The prompt is piped through stdin, the answer is read from the
``--output-format json`` envelope, and no tool is enabled: the model only
produces text, it never touches the file system.

Authentication is the CLI's own (``claude auth login`` on a workstation,
``ANTHROPIC_API_KEY`` or ``CLAUDE_CODE_OAUTH_TOKEN`` in a container), so this
module never sees or stores a credential.

Model names are whatever ``claude --model`` accepts: an alias (``haiku``,
``sonnet``, ``opus``, ``fable``) or a full model id.
"""

import asyncio
import json
import logging
import os
import shutil
from typing import Callable, List, Optional

from ..base import LLMProvider, LLMRequest, LLMResponse
from ..exceptions import ProviderError
from ..policy import RetryPolicy

logger = logging.getLogger("llm.claude-cli")

#: Environment variable that overrides the ``claude`` executable location.
CLAUDE_CLI_PATH_ENV = "CLAUDE_CLI_PATH"

# Phrases of the CLI's error text that map onto the shared error taxonomy.
_AUTH_MARKERS = (
    "failed to authenticate", "oauth session expired", "not logged in",
    "invalid api key", "authentication_error", "please run /login", "claude auth login",
)
_RATE_LIMIT_MARKERS = (
    "rate limit", "rate_limit", "usage limit", "too many requests", "overloaded",
    "limit reached", "429",
)
_OVERFLOW_MARKERS = (
    "prompt is too long", "context window", "context_length", "too many tokens",
    "exceeds the maximum",
)


def find_claude_executable(explicit: Optional[str] = None) -> Optional[str]:
    """Resolve the ``claude`` executable: explicit path, env override, then PATH."""
    candidate = explicit or os.getenv(CLAUDE_CLI_PATH_ENV)
    if candidate:
        return candidate if os.path.isfile(candidate) else shutil.which(candidate)
    return shutil.which("claude")


class ClaudeCLIProvider(LLMProvider):
    """Provider that shells out to ``claude -p`` for each request."""

    DISPLAY_NAME = "Claude CLI"

    def __init__(
        self,
        model: str,
        *,
        executable: Optional[str] = None,
        effort: Optional[str] = None,
        retry_policy: Optional[RetryPolicy] = None,
        temperature: Optional[float] = None,
        log_callback: Optional[Callable] = None,
    ):
        """
        Args:
            model: ``claude --model`` value (alias or full id).
            executable: Path to the ``claude`` binary; resolved lazily when None.
            effort: Optional ``--effort`` level (low, medium, high, xhigh, max).
                None keeps the CLI default.
        """
        super().__init__(model, api_keys=None, provider_name="claude-cli",
                         retry_policy=retry_policy, temperature=temperature,
                         log_callback=log_callback)
        self.executable = executable
        self.effort = effort

    # The CLI has no sampling-temperature switch, so ``temperature`` is accepted
    # for interface parity and ignored.

    def _command(self, request: LLMRequest, executable: str) -> List[str]:
        cmd = [
            executable, "-p",
            "--model", request.model,
            "--output-format", "json",
            "--tools", "",                   # text in, text out: no tool may run
            "--no-session-persistence",
            "--disable-slash-commands",
        ]
        if request.system_prompt:
            cmd += ["--system-prompt", request.system_prompt]
        if self.effort:
            cmd += ["--effort", self.effort]
        return cmd

    async def _send(self, request: LLMRequest) -> LLMResponse:
        executable = find_claude_executable(self.executable)
        if not executable:
            raise ProviderError(
                "the 'claude' CLI was not found. Install it (npm install -g "
                f"@anthropic-ai/claude-code) or set {CLAUDE_CLI_PATH_ENV}.",
                retryable=False,
            )

        try:
            proc = await asyncio.create_subprocess_exec(
                *self._command(request, executable),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                # A neutral working directory keeps project files (CLAUDE.md,
                # settings) out of a translation request.
                cwd=os.path.expanduser("~"),
            )
        except OSError as e:
            raise ProviderError(f"could not start the claude CLI: {e}", retryable=False) from e

        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(request.prompt.encode("utf-8")), timeout=request.timeout,
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise ProviderError(
                f"claude CLI timed out after {request.timeout:.0f}s",
                retryable=True, transport=True,
            )
        except asyncio.CancelledError:
            proc.kill()
            raise

        return self._parse(stdout.decode("utf-8", "replace"),
                           stderr.decode("utf-8", "replace"), proc.returncode)

    def _parse(self, stdout: str, stderr: str, returncode: Optional[int]) -> LLMResponse:
        """Turn the CLI's JSON envelope into an ``LLMResponse`` or a ``ProviderError``."""
        try:
            data = json.loads(stdout)
        except json.JSONDecodeError:
            data = None
        if not isinstance(data, dict):
            detail = (stderr or stdout or "").strip()[:500]
            raise ProviderError(
                f"claude CLI returned no JSON (exit {returncode}): {detail}",
                retryable=True, transport=True, body=detail,
            )

        text = str(data.get("result") or "")
        if data.get("is_error") or (returncode not in (0, None) and not text):
            raise _classify_error(text or stderr, data)

        usage = data.get("usage") or {}
        prompt_tokens = int(
            (usage.get("input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
        )
        completion_tokens = int(usage.get("output_tokens") or 0)
        stop_reason = data.get("stop_reason")
        return LLMResponse(
            content=text,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            context_used=prompt_tokens + completion_tokens,
            context_limit=0,
            finish_reason=stop_reason,
            output_truncated=str(stop_reason or "").lower() == "max_tokens",
            cost=data.get("total_cost_usd") or None,
        )


def _classify_error(message: str, data: dict) -> ProviderError:
    """Map the CLI's error text onto the shared error taxonomy."""
    message = (message or "claude CLI reported an error").strip()
    lowered = message.lower()
    status = data.get("api_error_status")
    status = status if isinstance(status, int) else None

    if any(m in lowered for m in _AUTH_MARKERS) or status in (401, 403):
        return ProviderError(
            f"claude CLI is not authenticated: {message}. Run 'claude auth login' "
            "or set ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN.",
            status_code=status or 401, retryable=False,
        )
    if any(m in lowered for m in _OVERFLOW_MARKERS):
        return ProviderError(message, status_code=status, context_overflow=True)
    if status == 429 or any(m in lowered for m in _RATE_LIMIT_MARKERS):
        return ProviderError(message, status_code=429, rate_limited=True, retryable=True)
    if status is not None and 400 <= status < 500:
        return ProviderError(message, status_code=status, retryable=False)
    return ProviderError(message, status_code=status, retryable=True)
