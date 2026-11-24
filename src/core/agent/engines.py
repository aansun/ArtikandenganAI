"""
Which translation engines are active on this machine.

The engines are command line tools, each with its own sign-in: ``claude``, ``codex`` and
``agy``. An engine is *active* when its program is installed AND it answers one tiny test
question; being installed alone does not count, because a signed-out or used-up engine would
fail the first real chunk. The first active engine (in the configured order) is the main one
and every other active engine is a backup, in order.

Probing costs a few tokens per engine, so a result is kept in a small cache file for a few
minutes (and ``refresh`` forces a new probe).
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence

from src.core.agent.routing import AGY_MODELS, check_allowed
from src.core.llm import ProviderConfig, create_llm_provider
from src.core.llm.base import LLMRequest
from src.core.llm.exceptions import ProviderError
from src.core.llm.providers.agy import find_agy_executable
from src.core.llm.providers.claude_cli import find_claude_executable
from src.core.llm.providers.codex_cli import find_codex_executable

logger = logging.getLogger("core.agent.engines")

DEFAULT_ORDER = ("claude", "codex", "agy")
CACHE_SECONDS = 600
PROBE_TIMEOUT = 90
#: The test question; the fakes of the tests recognise it by this prefix.
PROBE_PROMPT = "Reply with the single word OK."

#: engine -> (label, provider type, finder, model per quality tier, probe tier)
_META = {
    "claude": ("Claude", "claude-cli", find_claude_executable, {"haiku": "haiku", "sonnet": "sonnet"}),
    "codex": ("Codex", "codex", find_codex_executable, {"haiku": "", "sonnet": ""}),
    "agy": ("Antigravity", "agy", find_agy_executable, dict(AGY_MODELS)),
}


@dataclass
class Engine:
    name: str          # claude | codex | agy
    label: str
    provider: str      # provider type of the llm factory
    path: str          # program location, '' when not installed
    active: bool
    reason: str        # why it is not active, or 'ok'
    role: str = ""     # 'main' | 'backup' (set among the active ones)


def model_for(name: str, tier: str) -> str:
    """The engine's model for a quality tier (haiku, sonnet); '' means the CLI's own."""
    return _META[name][3].get(tier, "")


async def _probe(name: str) -> Engine:
    label, provider_type, finder, _tiers = _META[name]
    path = finder() or ""
    if not path:
        return Engine(name, label, provider_type, "", False, "not installed")
    provider = create_llm_provider(ProviderConfig(provider=provider_type, model=model_for(name, "haiku")))
    request = LLMRequest(prompt=PROBE_PROMPT, system_prompt=None, model=model_for(name, "haiku"),
                         api_key=None, timeout=PROBE_TIMEOUT)
    try:
        response = await provider._send(request)
    except ProviderError as error:
        return Engine(name, label, provider_type, path, False, error.message[:200])
    except Exception as error:  # a broken engine must not break the detection
        return Engine(name, label, provider_type, path, False, f"{type(error).__name__}: {error}"[:200])
    ok = bool((response.content or "").strip())
    return Engine(name, label, provider_type, path, ok, "ok" if ok else "empty answer")


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
            if name in cached:
                found[name] = Engine(**cached[name])
    missing = [n for n in names if n not in found]
    if missing:
        async def run():
            return await asyncio.gather(*(_probe(n) for n in missing))
        for engine in asyncio.run(run()):
            found[engine.name] = engine
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
        model = override if (override and not chain) else model_for(engine.name, tier)
        chain.append({"provider": engine.provider, "model": check_allowed(model)})
    return chain
