"""
OpenCode CLI provider.

Runs each request through ``opencode run --format json`` with an agent made for this one job:
its prompt is the request's system prompt and every tool is switched off and denied, so the
model can only answer with text. The prompt goes on stdin and the answer is the ``text``
events of the JSON lines it prints.

Each call runs in an empty scratch directory with its own empty configuration folder, so the
user's rules (``AGENTS.md``, ``CLAUDE.md``), plugins and MCP servers do not reach a
translation. The sign-in stays the CLI's own (``opencode auth login``); this module never
reads or stores a credential.

``model`` is ``provider/model`` as ``opencode models`` prints it.
"""

import asyncio
import json
import logging
import os
import shutil
import tempfile
from typing import Callable, Dict, List, Optional, Set

from ..base import LLMProvider, LLMRequest, LLMResponse, is_output_limit_finish
from ..exceptions import ProviderError
from ..policy import RetryPolicy

logger = logging.getLogger("llm.opencode")

#: Environment variable that overrides the ``opencode`` executable location.
OPENCODE_PATH_ENV = "OPENCODE_CLI_PATH"

#: Name of the agent defined for each request.
AGENT = "translator"

#: The agent's prompt when a request has no system prompt: without one, OpenCode would use its
#: own coding-assistant prompt.
DEFAULT_SYSTEM = "Follow the instructions of the message and answer with text only."

LIST_TIMEOUT = 60

_AUTH_MARKERS = ("api key", "unauthorized", "401", "403", "user not found", "not logged in",
                 "auth login", "authentication")
_RATE_LIMIT_MARKERS = ("rate limit", "rate_limit", "usage limit", "quota", "too many requests",
                       "429", "overloaded", "insufficient balance", "insufficient credit",
                       "limit reached")
_OVERFLOW_MARKERS = ("context window", "context length", "context_length", "too long",
                     "maximum context")
_BAD_REQUEST_MARKERS = ("model not found", "unknown model", "does not exist", "not supported",
                        "agent not found")


def find_opencode_executable(explicit: Optional[str] = None) -> Optional[str]:
    """Resolve ``opencode``: explicit path, env override, PATH, then its installer's folder."""
    candidate = explicit or os.getenv(OPENCODE_PATH_ENV)
    if candidate:
        return candidate if os.path.isfile(candidate) else shutil.which(candidate)
    installed = os.path.expanduser("~/.opencode/bin/opencode")
    return shutil.which("opencode") or (installed if os.access(installed, os.X_OK) else None)


async def listed_models(executable: str) -> Optional[Set[str]]:
    """The ``provider/model`` ids ``opencode models`` prints, or None when it cannot say.

    A listed model is not necessarily usable (an expired key lists its models too).
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            executable, "models", stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            cwd=tempfile.gettempdir())
        try:
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=LIST_TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return None
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    lines = (line.strip() for line in stdout.decode("utf-8", "replace").splitlines())
    return {line for line in lines if "/" in line and " " not in line} or None


def agent_config(system_prompt: Optional[str]) -> str:
    """The configuration of the one-job agent: no tool, no sharing."""
    # "{" starts a substitution ("{env:...}", "{file:...}") in OpenCode's configuration;
    # written as a JSON escape, the text of a book cannot trigger one.
    prompt = json.dumps(system_prompt or DEFAULT_SYSTEM).replace("{", "\\u007b")
    config = {
        "share": "disabled",
        "agent": {AGENT: {"mode": "primary", "prompt": "__PROMPT__",
                          "tools": {"*": False}, "permission": {"*": "deny"}}},
    }
    return json.dumps(config).replace('"__PROMPT__"', prompt)


class OpenCodeProvider(LLMProvider):
    """Provider that shells out to ``opencode run`` for each request."""

    DISPLAY_NAME = "OpenCode"

    def __init__(
        self,
        model: str,
        *,
        executable: Optional[str] = None,
        retry_policy: Optional[RetryPolicy] = None,
        temperature: Optional[float] = None,
        log_callback: Optional[Callable] = None,
    ):
        super().__init__(model, api_keys=None, provider_name="opencode",
                         retry_policy=retry_policy, temperature=temperature,
                         log_callback=log_callback)
        self.executable = executable
        self._scratch: Optional[str] = None

    def _scratch_dir(self) -> str:
        if not self._scratch or not os.path.isdir(self._scratch):
            self._scratch = tempfile.mkdtemp(prefix="opencode-scratch-")
            os.makedirs(os.path.join(self._scratch, "config"), exist_ok=True)
            os.makedirs(os.path.join(self._scratch, "work"), exist_ok=True)
        return self._scratch

    def _command(self, request: LLMRequest, executable: str) -> List[str]:
        if not request.model:
            raise ProviderError("opencode needs a model (provider/model)", retryable=False)
        # a given title saves the extra request OpenCode would make to name the session
        return [executable, "run", "--pure", "--format", "json", "--agent", AGENT,
                "--title", "translation", "-m", request.model]

    def _environment(self, request: LLMRequest) -> Dict[str, str]:
        env = dict(os.environ)
        env.update({
            "OPENCODE_CONFIG_CONTENT": agent_config(request.system_prompt),
            "XDG_CONFIG_HOME": os.path.join(self._scratch_dir(), "config"),
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT": "1",
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
        })
        env.pop("OPENCODE_CONFIG", None)
        env.pop("OPENCODE_CONFIG_DIR", None)
        return env

    async def _send(self, request: LLMRequest) -> LLMResponse:
        executable = find_opencode_executable(self.executable)
        if not executable:
            raise ProviderError(
                f"the 'opencode' CLI was not found. Install it or set {OPENCODE_PATH_ENV}.",
                retryable=False)
        command = self._command(request, executable)
        work = os.path.join(self._scratch_dir(), "work")
        try:
            proc = await asyncio.create_subprocess_exec(
                *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, cwd=work, env=self._environment(request))
        except OSError as e:
            raise ProviderError(f"could not start the opencode CLI: {e}", retryable=False) from e
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(request.prompt.encode("utf-8")), timeout=request.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise ProviderError(f"opencode CLI timed out after {request.timeout:.0f}s",
                                retryable=True, transport=True)
        except asyncio.CancelledError:
            proc.kill()
            raise
        return self._parse(stdout.decode("utf-8", "replace"),
                           stderr.decode("utf-8", "replace"), proc.returncode)

    def _parse(self, stdout: str, stderr: str, returncode: Optional[int]) -> LLMResponse:
        """Turn the JSON event lines into an ``LLMResponse`` or a ``ProviderError``."""
        texts: List[str] = []
        prompt_tokens = completion_tokens = 0
        cost = 0.0
        finish: Optional[str] = None
        for line in stdout.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            kind, part = event.get("type"), event.get("part") or {}
            if kind == "error":
                raise _classify_error(_error_message(event.get("error")))
            if kind == "tool_use":
                raise ProviderError(f"opencode ran a tool ({part.get('tool')}) although none "
                                    "is allowed; the answer is discarded", retryable=False)
            if kind == "text":
                texts.append(str(part.get("text") or ""))
            elif kind == "step_finish":
                tokens = part.get("tokens") or {}
                cache = tokens.get("cache") or {}
                prompt_tokens += int((tokens.get("input") or 0) + (cache.get("read") or 0)
                                     + (cache.get("write") or 0))
                completion_tokens += int(tokens.get("output") or 0)
                cost += float(part.get("cost") or 0)
                finish = part.get("reason") or finish
        text = "".join(texts).strip()
        if returncode not in (0, None) or not text:
            detail = (stderr or "").strip()[-600:]
            raise _classify_error(detail or f"opencode CLI exit {returncode} with no answer")
        return LLMResponse(
            content=text,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            context_used=prompt_tokens + completion_tokens,
            context_limit=0,
            finish_reason=finish,
            output_truncated=is_output_limit_finish(finish),
            cost=cost or None,
        )


def _error_message(error) -> str:
    if isinstance(error, dict):
        data = error.get("data") if isinstance(error.get("data"), dict) else {}
        message = data.get("message") or error.get("message") or error.get("name") or str(error)
        status = data.get("statusCode")
        return f"{status}: {message}" if status else str(message)
    return str(error or "opencode reported an error")


def _classify_error(message: str) -> ProviderError:
    lowered = message.lower()
    if any(m in lowered for m in _OVERFLOW_MARKERS):
        return ProviderError(message, context_overflow=True)
    if any(m in lowered for m in _RATE_LIMIT_MARKERS):
        return ProviderError(message, status_code=429, rate_limited=True, retryable=True)
    if any(m in lowered for m in _BAD_REQUEST_MARKERS):
        return ProviderError(message, status_code=400, retryable=False)
    if any(m in lowered for m in _AUTH_MARKERS):
        return ProviderError(f"opencode CLI is not signed in: {message} Run 'opencode auth login'.",
                             status_code=401, retryable=False)
    return ProviderError(message, retryable=True)
