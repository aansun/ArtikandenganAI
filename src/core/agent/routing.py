"""
Pick the models for a book from its genre.

By default (``auto``) the agent uses every translation engine that is active on the
machine (claude, codex, agy; see ``engines.py``): the first is the main one and the rest are
backups, in order. ``opus`` is not an option anywhere: Claude is capped at ``sonnet``. The
glossary, the one step where a mistake is repeated in every volume, runs at the ``sonnet``
tier on the same chain.

The genre decides a quality *tier* (``haiku`` or ``sonnet``, the claude CLI
aliases). Each provider turns the tier into its own model id. A profile moves
every class one step up or down, bounded below so quality never collapses.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

#: Cheapest to strongest tier. Values are ``claude --model`` aliases.
LADDER = ("haiku", "sonnet")

#: Model of the glossary pass (fiction only), always on the claude CLI.
GLOSSARY_MODEL = "sonnet"

#: Translation providers the agent can use.
PROVIDER_AGY_CLAUDE = "agy-claude"   # agy first, claude CLI as backup
PROVIDER_AGY = "agy"
PROVIDER_CLAUDE = "claude-cli"
PROVIDER_CODEX = "codex"
PROVIDER_AUTO = "auto"               # every active engine, first = main, rest = backups
TRANSLATE_PROVIDERS = (PROVIDER_AUTO, PROVIDER_AGY_CLAUDE, PROVIDER_AGY, PROVIDER_CLAUDE, PROVIDER_CODEX)

#: Detect the active engines and chain them (see engines.py).
DEFAULT_TRANSLATE_PROVIDER = PROVIDER_AUTO

#: Tier -> agy model id (see ``agy models``).
AGY_MODELS = {"haiku": "gemini-3.8-flash-low", "sonnet": "gemini-3.8-flash-high"}

FICTION_GENRES = frozenset({"fiction_novel", "light_novel", "literary_fiction"})
SPECIALIST_GENRES = frozenset({"technical", "academic", "legal"})
LIGHT_GENRES = frozenset({"children", "simple"})

PROFILES = ("economy", "balanced", "best")

# class -> (balanced tier index, lowest tier index allowed)
_CLASS_TIERS = {
    "fiction": (1, 1),
    "specialist": (1, 1),
    "general": (1, 0),
    "light": (0, 0),
}


@dataclass(frozen=True)
class ModelChoice:
    model: str                  # model of the translation provider (the primary)
    backup_model: Optional[str]  # claude alias used when the primary fails, if any
    tier: str
    book_class: str
    reason: str
    chain: tuple = ()           # [{"provider", "model"}] of the active engines (auto mode)


def book_class(genre: str) -> str:
    if genre in FICTION_GENRES:
        return "fiction"
    if genre in SPECIALIST_GENRES:
        return "specialist"
    if genre in LIGHT_GENRES:
        return "light"
    return "general"


def is_fiction(genre: str) -> bool:
    return genre in FICTION_GENRES


def check_allowed(model: str) -> str:
    """Refuse opus: the agent never uses it, on any provider."""
    if "opus" in (model or "").lower():
        raise ValueError(f"model '{model}' is not allowed: the agent never uses opus "
                         "(claude is capped at sonnet)")
    return model


def models_for(provider: str, tier: str, override: Optional[str] = None):
    """(primary model, backup model or None) of ``provider`` for ``tier``."""
    if provider not in TRANSLATE_PROVIDERS:
        raise ValueError(f"translate provider must be one of {', '.join(TRANSLATE_PROVIDERS)}")
    if override:
        check_allowed(override)
    if provider == PROVIDER_CODEX:
        return override or "", None
    if provider == PROVIDER_CLAUDE:
        return override or tier, None
    primary = override or AGY_MODELS[tier]
    return primary, (tier if provider == PROVIDER_AGY_CLAUDE else None)


def choose_model(genre: str, *, profile: str = "balanced", override: Optional[str] = None,
                 provider: str = DEFAULT_TRANSLATE_PROVIDER, engines=None) -> ModelChoice:
    """Models for a book of ``genre``; ``override`` replaces the primary model.

    In ``auto`` mode ``engines`` are the detected engines; their chain is in ``.chain``.
    """
    klass = book_class(genre)
    if override:
        check_allowed(override)
    if profile not in PROFILES:
        raise ValueError(f"profile must be one of {', '.join(PROFILES)}")
    base, floor = _CLASS_TIERS[klass]
    shift = {"economy": -1, "balanced": 0, "best": 1}[profile]
    tier = LADDER[max(floor, min(len(LADDER) - 1, base + shift))]
    reason_tail = ", model set explicitly" if override else ""
    if provider == PROVIDER_AUTO:
        from src.core.agent.engines import chain_for
        chain = chain_for(engines or [], tier, override)
        names = " > ".join(link["provider"] for link in chain) or "no engine"
        return ModelChoice(chain[0]["model"] if chain else "", None, tier, klass,
                           f"{klass} book, {profile} profile, engines {names}{reason_tail}",
                           tuple(chain))
    primary, backup = models_for(provider, tier, override)
    reason = f"{klass} book, {profile} profile" + (", model set explicitly" if override else "")
    return ModelChoice(primary, backup, tier, klass, reason)
