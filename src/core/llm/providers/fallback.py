"""
Primary-with-backup provider: a two-engine ``ChainProvider``.

Kept for the ``agy-claude`` provider and its callers; the general N-engine chain, the circuit
breaker and the rules about what is and is not rerouted live in ``chain.py``.
"""

from typing import Callable, Optional

from ..base import LLMProvider
from ..policy import RetryPolicy
from .chain import (  # noqa: F401  (re-exported)
    COOLDOWN_SECONDS, FAILURE_LIMIT, ChainProvider, last_engine, reset_breakers)


class FallbackProvider(ChainProvider):
    """Try ``primary`` with the request's model; on failure answer from ``backup``."""

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
        super().__init__([(primary, None), (backup, backup_model)], failure_limit=failure_limit,
                         cooldown=cooldown, retry_policy=retry_policy, temperature=temperature,
                         log_callback=log_callback)
        self.primary, self.backup, self.backup_model = primary, backup, backup_model
