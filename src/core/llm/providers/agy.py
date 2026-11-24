"""
Antigravity CLI (``agy``) provider.

Runs each request through ``agy --print`` and reads the JSON envelope
(``{"status", "response", "error", "usage"}``). It reaches the models the CLI
offers (``agy models``): Gemini Flash, Claude 4.6 and GPT-OSS.

Differences from the ``claude`` CLI that this module absorbs:

* the prompt travels as a command-line argument (``-p=<prompt>``), not on stdin,
  so a prompt over the operating system's per-argument limit is refused up front;
* there is no system-prompt flag, so the system prompt is placed in front of the
  user prompt;
* ``agy`` is an agent with tools and has no switch to disable them, so every
  call runs in an empty scratch directory: nothing of the project is in reach.

Authentication is the CLI's own; this module never sees a credential.
"""

import asyncio
import json
import logging
import os
import shutil
import tempfile
from typing import Callable, List, Optional

from ..base import LLMProvider, LLMRequest, LLMResponse
from ..exceptions import ProviderError
from ..policy import RetryPolicy

logger = logging.getLogger("llm.agy")

#: Environment variable that overrides the ``agy`` executable location.
AGY_PATH_ENV = "AGY_PATH"

#: Largest prompt passed as one argument. Linux caps a single argument at
#: 128 KiB (MAX_ARG_STRLEN); stay clear of it.
MAX_PROMPT_BYTES = 120_000

_AUTH_MARKERS = ("not logged in", "unauthenticated", "sign in", "please log in", "login required",
                 "authentication")
_RATE_LIMIT_MARKERS = ("quota", "rate limit", "rate_limit", "resource_exhausted", "too many requests",
                       "429", "overloaded")
_OVERFLOW_MARKERS = ("context window", "too long", "context length", "too many tokens")
_BAD_REQUEST_MARKERS = ("invalid model", "not recognized", "unknown flag", "flag needs an argument")


def find_agy_executable(explicit: Optional[str] = None) -> Optional[str]:
    """Resolve the ``agy`` executable: explicit path, env override, then PATH."""
    candidate = explicit or os.getenv(AGY_PATH_ENV)
    if candidate:
        return candidate if os.path.isfile(candidate) else shutil.which(candidate)
    return shutil.which("agy")


class AgyProvider(LLMProvider):
    """Provider that shells out to ``agy --print`` for each request."""

    DISPLAY_NAME = "Antigravity CLI"

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
            model: ``agy --model`` id, e.g. ``gemini-3.8-flash-high`` (see ``agy models``).
            executable: Path to the ``agy`` binary; resolved lazily when None.
            effort: Optional ``--effort`` level. None keeps the CLI default.
        """
        super().__init__(model, api_keys=None, provider_name="agy",
                         retry_policy=retry_policy, temperature=temperature,
                         log_callback=log_callback)
        self.executable = executable
        self.effort = effort
        self._scratch: Optional[str] = None

    def _scratch_dir(self) -> str:
        if not self._scratch or not os.path.isdir(self._scratch):
            self._scratch = tempfile.mkdtemp(prefix="agy-scratch-")
        return self._scratch

    @staticmethod
    def _full_prompt(request: LLMRequest) -> str:
        if request.system_prompt:
            return f"{request.system_prompt}\n\n{request.prompt}"
        return request.prompt

    def _command(self, request: LLMRequest, executable: str, prompt: str) -> List[str]:
        cmd = [executable, "--model", request.model, "--output-format", "json",
               "--disable-slash-commands"]
        if self.effort:
            cmd += ["--effort", self.effort]
        cmd.append(f"-p={prompt}")
        return cmd

    async def _send(self, request: LLMRequest) -> LLMResponse:
        executable = find_agy_executable(self.executable)
        if not executable:
            raise ProviderError(
                f"the 'agy' CLI was not found. Install it or set {AGY_PATH_ENV}.", retryable=False)

        prompt = self._full_prompt(request)
        if len(prompt.encode("utf-8")) > MAX_PROMPT_BYTES:
            raise ProviderError(
                f"prompt is {len(prompt.encode('utf-8'))} bytes, over the {MAX_PROMPT_BYTES} an "
                "agy command-line argument can carry; use smaller chunks",
                context_overflow=True)

        try:
            proc = await asyncio.create_subprocess_exec(
                *self._command(request, executable, prompt),
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self._scratch_dir(),
            )
        except OSError as e:
            raise ProviderError(f"could not start the agy CLI: {e}", retryable=False) from e

        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=request.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise ProviderError(f"agy CLI timed out after {request.timeout:.0f}s",
                                retryable=True, transport=True)
        except asyncio.CancelledError:
            proc.kill()
            raise

        return self._parse(stdout.decode("utf-8", "replace"),
                           stderr.decode("utf-8", "replace"), proc.returncode)

    def _parse(self, stdout: str, stderr: str, returncode: Optional[int]) -> LLMResponse:
        """Turn agy's JSON envelope into an ``LLMResponse`` or a ``ProviderError``."""
        data = _last_json_object(stdout)
        if data is None:
            detail = (stderr or stdout or "").strip()[:500]
            raise ProviderError(f"agy CLI returned no JSON (exit {returncode}): {detail}",
                                retryable=True, transport=True, body=detail)

        text = str(data.get("response") or "")
        if str(data.get("status", "")).upper() != "SUCCESS" or not text.strip():
            raise _classify_error(str(data.get("error") or text or stderr), data)

        usage = data.get("usage") or {}
        prompt_tokens = int(usage.get("input_tokens") or 0)
        completion_tokens = int(usage.get("output_tokens") or 0)
        return LLMResponse(
            content=text,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            context_used=prompt_tokens + completion_tokens,
            context_limit=0,
            finish_reason=data.get("finished_reason"),
        )


def _last_json_object(text: str) -> Optional[dict]:
    """The last line of ``text`` that parses as a JSON object (agy may log before it)."""
    for line in reversed([ln for ln in text.splitlines() if ln.strip()]):
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            return data
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _classify_error(message: str, data: dict) -> ProviderError:
    """Map agy's error text onto the shared error taxonomy."""
    message = (message or "agy CLI reported an error").strip()
    lowered = message.lower()
    if any(m in lowered for m in _BAD_REQUEST_MARKERS):
        return ProviderError(message, status_code=400, retryable=False)
    if any(m in lowered for m in _AUTH_MARKERS):
        return ProviderError(f"agy CLI is not authenticated: {message}. Sign in with the agy CLI.",
                             status_code=401, retryable=False)
    if any(m in lowered for m in _OVERFLOW_MARKERS):
        return ProviderError(message, context_overflow=True)
    if any(m in lowered for m in _RATE_LIMIT_MARKERS):
        return ProviderError(message, status_code=429, rate_limited=True, retryable=True)
    # A print-mode timeout is the CLI's own verdict; the next attempt may pass.
    return ProviderError(message, retryable=True)
