"""
Pick the models for a book from its genre.

Translation runs on ``agy`` first (Gemini Flash) with the ``claude`` CLI as
backup, and the Claude side never goes above ``sonnet``: ``opus`` is not an
option anywhere in the agent. The glossary, the one step where a mistake is
repeated in every volume, runs on the strongest allowed model, ``sonnet``.

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
TRANSLATE_PROVIDERS = (PROVIDER_AGY_CLAUDE, PROVIDER_AGY, PROVIDER_CLAUDE)

#: Claude only, for now: the agy quota ran out. Switch back to PROVIDER_AGY_CLAUDE (agy
#: first, claude as backup) once agy is usable again.
DEFAULT_TRANSLATE_PROVIDER = PROVIDER_CLAUDE

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
    if provider == PROVIDER_CLAUDE:
        return override or tier, None
    primary = override or AGY_MODELS[tier]
    return primary, (tier if provider == PROVIDER_AGY_CLAUDE else None)


def choose_model(genre: str, *, profile: str = "balanced", override: Optional[str] = None,
                 provider: str = DEFAULT_TRANSLATE_PROVIDER) -> ModelChoice:
    """Models for a book of ``genre``; ``override`` replaces the primary model."""
    klass = book_class(genre)
    if profile not in PROFILES:
        raise ValueError(f"profile must be one of {', '.join(PROFILES)}")
    base, floor = _CLASS_TIERS[klass]
    shift = {"economy": -1, "balanced": 0, "best": 1}[profile]
    tier = LADDER[max(floor, min(len(LADDER) - 1, base + shift))]
    primary, backup = models_for(provider, tier, override)
    reason = f"{klass} book, {profile} profile" + (", model set explicitly" if override else "")
    return ModelChoice(primary, backup, tier, klass, reason)
