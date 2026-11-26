"""
The translation activity log: which engine and model did what, how fast, and how well.

It is a local file, one JSON object per line, meant to learn from later (which model to
recommend, where translations fail). It is off until :func:`configure` gives it a folder, and
nothing in this module ever sends it anywhere.

**What never goes in:** text of a book or of an answer, titles, authors, file names, paths,
error messages, account names. Only the fields listed in ``FIELDS`` are written, so a caller
cannot add one by mistake. Sizes are recorded as character counts.
"""

import json
import logging
import time
import uuid
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional

logger = logging.getLogger("llm.activity")

#: Version of the record format.
SCHEMA = 1

#: event -> the fields it may carry (besides schema, time, run, app and event).
FIELDS = {
    "engines": ("engines",),
    "request": ("engine", "model", "phase", "seconds", "prompt_chars", "answer_chars",
                "prompt_tokens", "completion_tokens", "cost", "ok", "error", "truncated"),
    "volume": ("status", "genre", "book_class", "profile", "source_language", "target_language",
               "polish", "parallel", "chunk_tokens", "resumed", "seconds", "models",
               "chunks_total", "chunks_failed", "chunks_untranslated", "chunks_token_aligned",
               "chunks_retried", "placeholder_errors", "qa_flags", "names_fixed",
               "metadata_missing"),
}

FILE_PATTERN = "activity-*.jsonl"

_state: Dict[str, object] = {"folder": None, "run": "", "app": "", "phase": ""}
_answered: Counter = Counter()       # (phase, "engine/model") -> requests answered


def configure(folder: Optional[Path], *, app_version: str = "") -> None:
    """Start a run that logs into ``folder``; None switches the log off."""
    _state.update(folder=Path(folder) if folder else None, run=uuid.uuid4().hex[:12],
                  app=app_version[:20], phase="")
    _answered.clear()


def enabled() -> bool:
    return _state["folder"] is not None


def set_phase(name: str) -> None:
    """What the requests that follow are for (classify, glossary, translate, refine...)."""
    _state["phase"] = name


def phase() -> str:
    return str(_state["phase"])


def take_models() -> Dict[str, Dict[str, int]]:
    """``{phase: {"engine/model": answered requests}}`` since the last call."""
    found: Dict[str, Dict[str, int]] = {}
    for (step, model), count in _answered.items():
        found.setdefault(step or "other", {})[model] = count
    _answered.clear()
    return found


def record(event: str, **fields) -> None:
    """Append one record. A log that cannot be written never disturbs a translation."""
    folder = _state["folder"]
    if folder is None:
        return
    try:
        now = datetime.now(timezone.utc)
        entry = {"schema": SCHEMA, "time": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "run": _state["run"], "app": _state["app"], "event": event}
        entry.update({k: fields[k] for k in FIELDS[event] if fields.get(k) is not None})
        folder.mkdir(parents=True, exist_ok=True)
        with open(folder / f"activity-{now:%Y-%m}.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as exc:  # noqa: BLE001 - logging is a convenience, never a failure
        logger.debug("Activity log not written: %s", exc)


def error_category(error) -> str:
    """A ProviderError as one word: its message may quote the text, so it is not kept."""
    if getattr(error, "rate_limited", False):
        return "rate_limit"
    if getattr(error, "context_overflow", False):
        return "context_overflow"
    status = getattr(error, "status_code", None)
    if status in (401, 403):
        return "auth"
    if status and 400 <= status < 500:
        return "rejected"
    if "timed out" in str(getattr(error, "message", "")).lower():
        return "timeout"
    return "transport" if getattr(error, "transport", False) else "other"


def record_request(engine: str, model: str, started: float, request, response=None, error=None) -> None:
    """One attempt on one engine; ``started`` is a ``time.monotonic()`` value."""
    if not enabled():
        return
    if response is not None:
        _answered[(phase(), f"{engine}/{model}")] += 1
    record("request", engine=engine, model=model, phase=phase(),
           seconds=round(time.monotonic() - started, 2),
           prompt_chars=len(request.prompt or "") + len(request.system_prompt or ""),
           answer_chars=len(response.content or "") if response is not None else None,
           prompt_tokens=(response.prompt_tokens or None) if response is not None else None,
           completion_tokens=(response.completion_tokens or None) if response is not None else None,
           cost=response.cost if response is not None else None,
           ok=response is not None,
           error=error_category(error) if error is not None else None,
           truncated=True if response is not None and response.output_truncated else None)
