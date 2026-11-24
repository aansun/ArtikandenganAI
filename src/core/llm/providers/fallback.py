"""
Primary-with-backup provider.

Sends each attempt to the primary provider and, when that fails, to the backup
(with the backup's own model). Used as ``agy`` first, ``claude`` second: the
book keeps translating when the primary hits a quota, is signed out, or breaks.

A failure the backup cannot fix is not rerouted: a context overflow is the
prompt's fault and goes straight back to the chunker.

Circuit breaker: when the primary keeps failing, it is skipped for a cooldown
instead of being tried (and timed out) on every chunk. A persistent failure
(signed out, unknown model, quota used up) opens it at once. The breaker is
shared by every instance with the same primary, because each volume builds its
own provider and a quota does not reset between volumes.
"""

import dataclasses
import logging
import time
from dataclasses import dataclass
from typing import Callable, Dict, Optional

from ..base import LLMProvider, LLMRequest, LLMResponse
from ..exceptions import ProviderError
from ..policy import RetryPolicy

logger = logging.getLogger("llm.fallback")

#: Consecutive transient failures that open the breaker.
FAILURE_LIMIT = 3
#: Seconds the primary is skipped once the breaker is open.
COOLDOWN_SECONDS = 600


@dataclass
class _Breaker:
    failures: int = 0
    skip_until: float = 0.0


_BREAKERS: Dict[str, _Breaker] = {}


def reset_breakers() -> None:
    """Forget every breaker (tests, or after the user fixed the primary)."""
    _BREAKERS.clear()


class FallbackProvider(LLMProvider):
    """Try ``primary``; on failure answer from ``backup`` using ``backup_model``."""

    def __init__(
        self,
        primary: LLMProvider,
        backup: LLMProvider,
        backup_model: str,
        *,
        failure_limit: int = FAILURE_LIMIT,
        cooldown: float = COOLDOWN_SECONDS,
        retry_policy: Optional[RetryPolicy] = None,
        temperature: Optional[float] = None,
        log_callback: Optional[Callable] = None,
    ):
        super().__init__(
            primary.model, api_keys=None,
            provider_name=f"{primary.provider_name}+{backup.provider_name}",
            retry_policy=retry_policy, temperature=temperature, log_callback=log_callback)
        self.primary = primary
        self.backup = backup
        self.backup_model = backup_model
        self.failure_limit = failure_limit
        self.cooldown = cooldown
        self._breaker = _BREAKERS.setdefault(self.primary.provider_name, _Breaker())

    # ---------------------------------------------------------------- breaker
    def _primary_available(self) -> bool:
        return time.monotonic() >= self._breaker.skip_until

    def _record_failure(self, error: ProviderError) -> None:
        self._breaker.failures += 1
        persistent = error.retryable is False or error.rate_limited
        if persistent or self._breaker.failures >= self.failure_limit:
            self._breaker.skip_until = time.monotonic() + self.cooldown
            self._breaker.failures = 0
            self._log(
                "llm_fallback_open",
                f"⚠️ [{self.primary.display_name}] failing ({error.message[:160]}); using "
                f"{self.backup.display_name} ({self.backup_model}) for the next "
                f"{self.cooldown / 60:.0f} min")
        else:
            self._log(
                "llm_fallback",
                f"⚠️ [{self.primary.display_name}] failed ({error.message[:160]}); answering this "
                f"request with {self.backup.display_name} ({self.backup_model})",
                level=logging.INFO)

    # ------------------------------------------------------------------- send
    async def _send(self, request: LLMRequest) -> LLMResponse:
        if self._primary_available():
            try:
                response = await self.primary._send(request)
            except ProviderError as error:
                if error.context_overflow:
                    raise
                self._record_failure(error)
            else:
                self._breaker.failures = 0
                return response
        return await self.backup._send(dataclasses.replace(request, model=self.backup_model))
