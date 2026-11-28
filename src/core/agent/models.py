"""
The models each engine may translate with.

The app recommends the model, whatever the CLI's own settings say: an engine is only usable
when it has a model on this list. The user may pick another model of such an engine (see
``allowed_choice``); the recommendation stays shown beside it. ``tested`` marks a model that has translated real text
through that engine here; an untested one is a candidate and is not used until it has been
checked (set ``AGENT_ALLOW_UNTESTED_MODELS=1`` to try the candidates).

Tiers are the two quality levels the routing asks for (see ``routing.py``): ``haiku`` for
light work, ``sonnet`` for everything that must read well. Within a tier the first model
that answers is used. No free or preview model is listed: some of them train on what they
are sent, and a book's text must not feed them.

A codex model may carry its reasoning effort after an ``@``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, List, Tuple

ALLOW_UNTESTED_ENV = "AGENT_ALLOW_UNTESTED_MODELS"

#: Never used, on any engine.
BANNED = ("opus", "fable")
#: Not offered as the user's own choice either: free and preview models may train on what they
#: are sent, and an orchestrator is an agent of its own, not a translator.
NOT_OFFERED = ("free", "preview", "orchestrator")


def allowed_choice(model: str) -> bool:
    """May the user pick this model?"""
    name = (model or "").lower()
    return bool(name) and not any(word in name for word in BANNED + NOT_OFFERED)


@dataclass(frozen=True)
class Recommended:
    model: str
    tested: bool = True


def _candidate(model: str) -> Recommended:
    return Recommended(model, tested=False)


RECOMMENDED: Dict[str, Dict[str, Tuple[Recommended, ...]]] = {
    "claude": {
        "haiku": (Recommended("haiku"),),
        "sonnet": (Recommended("sonnet"),),
    },
    "codex": {
        "haiku": (Recommended("gpt-6-luna@high"),),
        "sonnet": (Recommended("gpt-6-luna@high"),),
    },
    "agy": {
        "haiku": (Recommended("gemini-3.8-flash-low"),),
        "sonnet": (Recommended("gemini-3.8-flash-high"),),
    },
    # provider/model as `opencode models` prints them.
    "opencode": {
        "haiku": (
            _candidate("opencode/claude-haiku-5-5"),
            _candidate("opencode/gemini-3.8-flash"),
        ),
        "sonnet": (
            _candidate("opencode/claude-sonnet-5-5"),
            _candidate("opencode/gemini-3.8-flash"),
        ),
    },
}


def candidates(engine: str, tier: str) -> List[str]:
    """The models of ``engine`` that may be used for ``tier``, best first."""
    allow_all = os.getenv(ALLOW_UNTESTED_ENV, "").strip() == "1"
    return [r.model for r in RECOMMENDED.get(engine, {}).get(tier, ()) if r.tested or allow_all]


def first_choice(engine: str, tier: str) -> str:
    """The preferred model of ``engine`` for ``tier`` ('' when it has none)."""
    found = candidates(engine, tier)
    return found[0] if found else ""
