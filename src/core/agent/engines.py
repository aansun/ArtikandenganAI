"""
Which translation engines are active on this machine.

The engines are command line tools, each with its own sign-in: ``claude``, ``codex``,
``agy`` and ``opencode``. An engine is *active* when its program is installed AND one of its
recommended models (see ``models.py``) answers one tiny test question; being installed alone
does not count, because a signed-out or used-up engine would fail the first real chunk, and
neither does a model list, which a CLI prints even with an expired key. The first active engine (in the configured order) is the main one
and every other active engine is a backup, in order.

Probing costs a few tokens per engine, so a result is kept in a small cache file for a few
minutes (and ``refresh`` forces a new probe).
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set

from src.core.agent import models as model_list
from src.core.agent.routing import check_allowed
from src.core.llm import ProviderConfig, activity, create_llm_provider
from src.core.llm.base import LLMRequest
from src.core.llm.exceptions import ProviderError
from src.core.llm.providers.agy import find_agy_executable
from src.core.llm.providers.claude_cli import find_claude_executable
from src.core.llm.providers.codex_cli import find_codex_executable
from src.core.llm.providers.opencode_cli import find_opencode_executable, listed_models

logger = logging.getLogger("core.agent.engines")

DEFAULT_ORDER = ("claude", "codex", "agy", "opencode")
CACHE_SECONDS = 600
PROBE_TIMEOUT = 90
#: The test question; the fakes of the tests recognise it by this prefix.
PROBE_PROMPT = "Reply with the single word OK."
NO_MODEL = "no recommended model"

#: engine -> (label, provider type, finder, lister of the models it offers or None)
_META = {
    "claude": ("Claude", "claude-cli", find_claude_executable, None),
    "codex": ("Codex", "codex", find_codex_executable, None),
    "agy": ("Antigravity", "agy", find_agy_executable, None),
    "opencode": ("OpenCode", "opencode", find_opencode_executable, listed_models),
}


@dataclass
class Engine:
    name: str          # claude | codex | agy | opencode
    label: str
    provider: str      # provider type of the llm factory
    path: str          # program location, '' when not installed
    active: bool
    reason: str        # why it is not active, or 'ok'
    role: str = ""     # 'main' | 'backup' (set among the active ones)
    models: Dict[str, str] = field(default_factory=dict)   # tier -> model, when active


async def _probe(name: str) -> Engine:
    label, provider_type, finder, lister = _META[name]
    path = finder() or ""
    if not path:
        return Engine(name, label, provider_type, "", False, "not installed")

    def inactive(reason: str) -> Engine:
        return Engine(name, label, provider_type, path, False, reason[:200])

    strong, light = model_list.candidates(name, "sonnet"), model_list.candidates(name, "haiku")
    if not strong:
        return inactive(f"{NO_MODEL} yet: this engine has not been checked for translation quality")
    if lister:
        offered: Optional[Set[str]] = await lister(path)
        if offered is not None:
            strong = [m for m in strong if m in offered]
            light = [m for m in light if m in offered]
        if not strong:
            return inactive(f"{NO_MODEL} is available with this sign-in")
    reason = f"{NO_MODEL} answered"
    for model in strong:          # the strong tier carries every novel: it is the one that must answer
        provider = create_llm_provider(ProviderConfig(provider=provider_type, model=model))
        request = LLMRequest(prompt=PROBE_PROMPT, system_prompt=None, model=model,
                             api_key=None, timeout=PROBE_TIMEOUT)
        try:
            response = await provider._send(request)
        except ProviderError as error:
            reason = error.message
            continue
        except Exception as error:  # a broken engine must not break the detection
            reason = f"{type(error).__name__}: {error}"
            continue
        if not (response.content or "").strip():
            reason = "empty answer"
            continue
        # the light model comes from the same provider as the one that just answered, when it can
        family = model.rpartition("/")[0]
        near = [m for m in light if m.rpartition("/")[0] == family]
        tiers = {"sonnet": model, "haiku": (near or light or [model])[0]}
        return Engine(name, label, provider_type, path, True, "ok", models=tiers)
    return inactive(reason)


def state_word(engine: Engine) -> str:
    """Why an engine is or is not usable, as one word (its reason may name the account)."""
    if engine.active:
        return "ok"
    if engine.reason == "not installed":
        return "not_installed"
    if engine.reason.startswith(NO_MODEL):
        return "no_model"
    lowered = engine.reason.lower()
    if any(w in lowered for w in ("quota", "limit", "429")):
        return "quota"
    if any(w in lowered for w in ("sign", "auth", "log in", "login", "key", "401")):
        return "auth"
    return "other"


def _read_cache(path: Optional[Path]) -> Optional[Dict[str, dict]]:
    if not path or not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if time.time() - float(data["at"]) <= CACHE_SECONDS:
            return data["engines"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def detect_engines(order: Optional[Sequence[str]] = None, *, cache_path: Optional[Path] = None,
                   refresh: bool = False) -> List[Engine]:
    """Every engine of ``order`` with its state; the active ones get the role main or backup."""
    names = [n for n in (order or DEFAULT_ORDER) if n in _META]
    cached = None if refresh else _read_cache(cache_path)
    found: Dict[str, Engine] = {}
    if cached:
        for name in names:
            entry = cached.get(name)
            if not entry or (entry.get("active") and not entry.get("models")):
                continue        # a cache written before the models were recorded
            # a model taken off the list (or an untested one no longer allowed) is not reused
            allowed = {m for tier in ("haiku", "sonnet") for m in model_list.candidates(name, tier)}
            if set((entry.get("models") or {}).values()) <= allowed:
                found[name] = Engine(**entry)
    missing = [n for n in names if n not in found]
    if missing:
        async def run():
            return await asyncio.gather(*(_probe(n) for n in missing))
        for engine in asyncio.run(run()):
            found[engine.name] = engine
        activity.record("engines", engines=[
            {"engine": n, "active": found[n].active, "models": found[n].models,
             "state": state_word(found[n])} for n in names])
        if cache_path:
            try:
                cache_path.parent.mkdir(parents=True, exist_ok=True)
                merged = {n: asdict(e) for n, e in found.items()}
                cache_path.write_text(json.dumps({"at": time.time(), "engines": merged}), encoding="utf-8")
            except OSError:
                pass
    engines = [found[n] for n in names]
    first = True
    for engine in engines:
        engine.role = ("main" if first else "backup") if engine.active else ""
        first = first and not engine.active
    return engines


def chain_for(engines: Sequence[Engine], tier: str, override: Optional[str] = None) -> List[dict]:
    """``[{"provider", "model"}]`` of the active engines, in order, for a quality tier.

    ``override`` replaces the model of the main engine only. No model of any engine may be an
    opus model.
    """
    chain = []
    for engine in engines:
        if not engine.active:
            continue
        listed = engine.models.get(tier) or model_list.first_choice(engine.name, tier)
        model = override if (override and not chain) else listed
        chain.append({"provider": engine.provider, "model": check_allowed(model)})
    return chain
