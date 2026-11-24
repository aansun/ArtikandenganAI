"""
Codex CLI provider.

Runs each request through ``codex exec``: the prompt (system prompt first, there is no
system-prompt flag) goes on stdin, and the model's final answer is read from the file given
to ``--output-last-message``, which holds the answer alone while stdout carries the session
log. Every call runs in an empty scratch directory with a read-only sandbox and no saved
session, so nothing of the project is in reach and nothing is kept.

``model`` may be empty: the CLI's own configured model is then used. Authentication is the
CLI's own (``codex login``); this module never sees a credential.
"""

import asyncio
import logging
import os
import shutil
import tempfile
from typing import Callable, List, Optional

from ..base import LLMProvider, LLMRequest, LLMResponse
from ..exceptions import ProviderError
from ..policy import RetryPolicy

logger = logging.getLogger("llm.codex")

#: Environment variable that overrides the ``codex`` executable location.
CODEX_PATH_ENV = "CODEX_PATH"

_AUTH_MARKERS = ("not logged in", "please log in", "codex login", "unauthorized", "401",
                 "invalid api key", "authentication")
_RATE_LIMIT_MARKERS = ("rate limit", "rate_limit", "usage limit", "quota", "too many requests",
                       "429", "overloaded", "capacity")
_OVERFLOW_MARKERS = ("context window", "context length", "too long", "maximum context")
_BAD_REQUEST_MARKERS = ("unknown model", "model not found", "does not exist", "unexpected argument",
                        "invalid value")


def find_codex_executable(explicit: Optional[str] = None) -> Optional[str]:
    """Resolve the ``codex`` executable: explicit path, env override, then PATH."""
    candidate = explicit or os.getenv(CODEX_PATH_ENV)
    if candidate:
        return candidate if os.path.isfile(candidate) else shutil.which(candidate)
    return shutil.which("codex")


class CodexProvider(LLMProvider):
    """Provider that shells out to ``codex exec`` for each request."""

    DISPLAY_NAME = "Codex"

    def __init__(
        self,
        model: str = "",
        *,
        executable: Optional[str] = None,
        retry_policy: Optional[RetryPolicy] = None,
        temperature: Optional[float] = None,
        log_callback: Optional[Callable] = None,
    ):
        super().__init__(model, api_keys=None, provider_name="codex",
                         retry_policy=retry_policy, temperature=temperature,
                         log_callback=log_callback)
        self.executable = executable
        self._scratch: Optional[str] = None

    def _scratch_dir(self) -> str:
        if not self._scratch or not os.path.isdir(self._scratch):
            self._scratch = tempfile.mkdtemp(prefix="codex-scratch-")
        return self._scratch

    def _command(self, request: LLMRequest, executable: str, out_file: str) -> List[str]:
        cmd = [executable, "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
               "--color", "never", "-C", self._scratch_dir(), "-o", out_file]
        if request.model:
            cmd += ["-m", request.model]
        return cmd + ["-"]

    async def _send(self, request: LLMRequest) -> LLMResponse:
        executable = find_codex_executable(self.executable)
        if not executable:
            raise ProviderError(f"the 'codex' CLI was not found. Install it or set {CODEX_PATH_ENV}.",
                                retryable=False)
        prompt = request.prompt if not request.system_prompt else (
            f"{request.system_prompt}\n\n{request.prompt}")
        fd, out_file = tempfile.mkstemp(prefix="codex-out-", suffix=".txt")
        os.close(fd)
        try:
            try:
                proc = await asyncio.create_subprocess_exec(
                    *self._command(request, executable, out_file),
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE, cwd=self._scratch_dir())
            except OSError as e:
                raise ProviderError(f"could not start the codex CLI: {e}", retryable=False) from e
            try:
                stdout, stderr = await asyncio.wait_for(
                    proc.communicate(prompt.encode("utf-8")), timeout=request.timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                raise ProviderError(f"codex CLI timed out after {request.timeout:.0f}s",
                                    retryable=True, transport=True)
            except asyncio.CancelledError:
                proc.kill()
                raise
            with open(out_file, encoding="utf-8", errors="replace") as f:
                answer = f.read().strip()
        finally:
            try:
                os.unlink(out_file)
            except OSError:
                pass
        return self._parse(answer, stdout.decode("utf-8", "replace"),
                           stderr.decode("utf-8", "replace"), proc.returncode)

    def _parse(self, answer: str, stdout: str, stderr: str, returncode: Optional[int]) -> LLMResponse:
        if returncode not in (0, None) or not answer:
            detail = (stderr or stdout or "").strip()
            raise _classify_error(detail[-600:] or f"codex CLI exit {returncode} with no answer")
        return LLMResponse(content=answer, context_limit=0)


def _classify_error(message: str) -> ProviderError:
    lowered = message.lower()
    if any(m in lowered for m in _BAD_REQUEST_MARKERS):
        return ProviderError(message, status_code=400, retryable=False)
    if any(m in lowered for m in _AUTH_MARKERS):
        return ProviderError(f"codex CLI is not authenticated: {message}. Run 'codex login'.",
                             status_code=401, retryable=False)
    if any(m in lowered for m in _OVERFLOW_MARKERS):
        return ProviderError(message, context_overflow=True)
    if any(m in lowered for m in _RATE_LIMIT_MARKERS):
        return ProviderError(message, status_code=429, rate_limited=True, retryable=True)
    return ProviderError(message, retryable=True)
