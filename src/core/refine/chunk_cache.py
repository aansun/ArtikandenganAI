"""
Polished chunks kept on disk, so a stopped polish pass continues where it was.

The polish pass of a book can run for an hour and has no checkpoint of its own: a pause, a
usage limit or a closed app used to start it again from the first chunk. Each chunk that was
polished is appended to a file beside the output; the next run takes it from there instead
of asking a model again. The key covers the draft, the language and the instructions, so a
changed translation or style is polished afresh.

Off unless :func:`use` set a file for the current job.
"""

from __future__ import annotations

import hashlib
import json
import logging
from contextvars import ContextVar
from pathlib import Path
from typing import Dict, Optional, Tuple

logger = logging.getLogger("core.refine.cache")

SUFFIX = ".polish-cache.jsonl"

_current: ContextVar[Optional[Tuple[Path, Dict[str, str]]]] = ContextVar("polish_cache", default=None)


def _read(path: Path) -> Dict[str, str]:
    found: Dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return found
    for line in lines:
        try:
            entry = json.loads(line)
            found[entry["key"]] = entry["text"]
        except (ValueError, KeyError, TypeError):
            continue            # the line being written when the process was killed
    return found


def use(path: Optional[Path]) -> None:
    """Keep this job's polished chunks in ``path``; None switches the cache off."""
    _current.set((Path(path), _read(Path(path))) if path else None)


def key(*parts: str) -> str:
    return hashlib.sha256("\x00".join(parts).encode("utf-8")).hexdigest()


def get(entry_key: str) -> Optional[str]:
    state = _current.get()
    return state[1].get(entry_key) if state else None


def put(entry_key: str, text: str) -> None:
    state = _current.get()
    if not state:
        return
    path, entries = state
    entries[entry_key] = text
    try:
        with open(path, "a", encoding="utf-8") as f:
            # a leading newline closes a line a killed run may have left half written
            f.write("\n" + json.dumps({"key": entry_key, "text": text}, ensure_ascii=False))
    except OSError as exc:      # the cache saves time; it must never cost a translation
        logger.debug("Polish cache not written: %s", exc)
