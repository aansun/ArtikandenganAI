"""
Engine chain: the first working engine answers, the rest are backups.

Each attempt goes to the first engine of the chain that is not resting; when it fails, to
the next one, each with its own model. A failure the next engine cannot fix is not rerouted:
a context overflow is the prompt's fault and goes back to the chunker.

When a book's :class:`~src.core.llm.voice.Voice` is given, an engine other than the one
whose writing the book follows is shown a sample of it, so the book keeps one voice.

Circuit breaker: an engine that keeps failing is skipped for a cooldown instead of being
tried (and timed out) on every chunk. A persistent failure (signed out, unknown model, quota
used up) rests it at once. The breakers are shared by every chain with the same engine,
because each volume builds its own provider and a quota does not reset between volumes.
If every engine is resting, the chain still tries them in order rather than give up.
"""

import dataclasses
import logging
import time
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .. import activity
from ..base import LLMProvider, LLMRequest, LLMResponse
from ..exceptions import ProviderError
from ..policy import RetryPolicy
from ..voice import Voice

logger = logging.getLogger("llm.chain")

#: Consecutive transient failures that rest an engine.
FAILURE_LIMIT = 3
#: Seconds a resting engine is skipped.
COOLDOWN_SECONDS = 600


@dataclass
class _Breaker:
    failures: int = 0
    skip_until: float = 0.0


_BREAKERS: Dict[str, _Breaker] = {}
_LAST_ENGINE: Dict[str, str] = {"name": ""}


def reset_breakers() -> None:
    """Forget every breaker (tests, or after the user fixed an engine)."""
    _BREAKERS.clear()
    _LAST_ENGINE["name"] = ""


def last_engine() -> str:
    """Provider name of the engine that answered most recently ('' before any answer)."""
    return _LAST_ENGINE["name"]


def resting_until(provider_name: str) -> float:
    """Wall-clock time an engine rests until (0 when it is not resting)."""
    breaker = _BREAKERS.get(provider_name)
    remaining = (breaker.skip_until - time.monotonic()) if breaker else 0
    return time.time() + remaining if remaining > 0 else 0.0


class ChainProvider(LLMProvider):
    """Try each ``(provider, model)`` of ``links`` in order; ``model`` None keeps the request's."""

    def __init__(
        self,
        links: Sequence[Tuple[LLMProvider, Optional[str]]],
        *,
        failure_limit: int = FAILURE_LIMIT,
        cooldown: float = COOLDOWN_SECONDS,
        retry_policy: Optional[RetryPolicy] = None,
        temperature: Optional[float] = None,
        log_callback: Optional[Callable] = None,
        voice: Optional[Voice] = None,
    ):
        if not links:
            raise ValueError("a chain needs at least one engine")
        first, first_model = links[0]
        super().__init__(
            first_model or first.model, api_keys=None,
            provider_name="+".join(p.provider_name for p, _ in links),
            retry_policy=retry_policy, temperature=temperature, log_callback=log_callback)
        self.links: List[Tuple[LLMProvider, Optional[str]]] = list(links)
        self.failure_limit = failure_limit
        self.cooldown = cooldown
        self.voice = voice

    async def _ask(self, provider: LLMProvider, attempt: LLMRequest) -> LLMResponse:
        """One request to one engine, with the book's voice when the engine needs it."""
        step = activity.phase()
        reference = self.voice.reference(step, provider.provider_name) if self.voice else ""
        if not reference:
            response = await provider._send(attempt)
        else:
            system = f"{attempt.system_prompt}\n\n{reference}" if attempt.system_prompt else reference
            response = await provider._send(dataclasses.replace(attempt, system_prompt=system))
            if self.voice.copied(step, response.content, attempt.prompt):
                self._log("llm_chain_voice_copied",
                          f"⚠️ [{provider.display_name}] repeated the voice sample; asking again without it")
                response = await provider._send(attempt)
        if self.voice:
            self.voice.note(step, provider.provider_name, response.content)
        return response

    # ---------------------------------------------------------------- breaker
    @staticmethod
    def _breaker(provider: LLMProvider) -> _Breaker:
        return _BREAKERS.setdefault(provider.provider_name, _Breaker())

    def _available(self, provider: LLMProvider) -> bool:
        return time.monotonic() >= self._breaker(provider).skip_until

    def _record_failure(self, provider: LLMProvider, error: ProviderError, nxt: Optional[str]) -> None:
        breaker = self._breaker(provider)
        breaker.failures += 1
        persistent = error.retryable is False or error.rate_limited
        follow = f"; using {nxt} next" if nxt else ""
        if persistent or breaker.failures >= self.failure_limit:
            breaker.skip_until = time.monotonic() + self.cooldown
            breaker.failures = 0
            self._log("llm_chain_rest",
                      f"⚠️ [{provider.display_name}] failing ({error.message[:160]}); resting it for "
                      f"{self.cooldown / 60:.0f} min{follow}")
        else:
            self._log("llm_chain_fallback",
                      f"⚠️ [{provider.display_name}] failed ({error.message[:160]}){follow}",
                      level=logging.INFO)

    # ------------------------------------------------------------------- send
    async def _send(self, request: LLMRequest) -> LLMResponse:
        order = [link for link in self.links if self._available(link[0])] or list(self.links)
        last_error: Optional[ProviderError] = None
        for i, (provider, model) in enumerate(order):
            attempt = dataclasses.replace(request, model=model) if model is not None else request
            started = time.monotonic()
            try:
                response = await self._ask(provider, attempt)
            except ProviderError as error:
                activity.record_request(provider.provider_name, attempt.model, started, attempt,
                                        error=error)
                if error.context_overflow:
                    raise
                last_error = error
                nxt = order[i + 1][0].display_name if i + 1 < len(order) else None
                self._record_failure(provider, error, nxt)
                continue
            activity.record_request(provider.provider_name, attempt.model, started, attempt,
                                    response=response)
            self._breaker(provider).failures = 0
            _LAST_ENGINE["name"] = provider.provider_name
            return response
        raise last_error or ProviderError("no engine answered", retryable=True)
