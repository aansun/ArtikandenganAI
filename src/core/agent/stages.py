"""
How long each stage of a book has been worked on.

The stages are the preparation (reading, glossary, style, sample) once per book, then the
translation and the polish of each volume. Time is counted only while the agent runs and is
saved every few seconds in the book's folder, so it adds up across pauses, usage limits and
a closed app.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Callable, Dict, Optional

logger = logging.getLogger("core.agent.stages")

PREPARE, TRANSLATE, REFINE = "prepare", "translate", "refine"
TICK_SECONDS = 3.0


class StageClock:
    def __init__(self, path: Path, *, phase: Callable[[], str] = lambda: "",
                 on_tick: Optional[Callable[[], None]] = None, interval: float = TICK_SECONDS,
                 now: Callable[[], float] = time.monotonic):
        self.path = Path(path)
        self._phase, self._on_tick, self._interval, self._now = phase, on_tick, interval, now
        self._lock = threading.RLock()
        self.stage = ""
        self.volume = 0
        self._since = 0.0
        self._stop: Optional[threading.Event] = None
        self._data = self._load()

    def _load(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(data.get("volumes"), dict):
                return data
        except (OSError, ValueError, AttributeError):
            pass
        return {PREPARE: 0.0, "volumes": {}}

    def _save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self._data), encoding="utf-8")
            tmp.replace(self.path)
        except OSError as exc:
            logger.debug("Stage times not saved: %s", exc)

    def _book(self) -> None:
        """Add the time since the last look to the running stage."""
        if not self.stage:
            return
        now = self._now()
        spent, self._since = max(0.0, now - self._since), now
        if self.stage == PREPARE:
            self._data[PREPARE] = self._data.get(PREPARE, 0.0) + spent
        else:
            volume = self._data["volumes"].setdefault(str(self.volume), {})
            volume[self.stage] = volume.get(self.stage, 0.0) + spent

    def start(self, stage: str, volume: int = 0) -> None:
        with self._lock:
            self._book()
            self.stage, self.volume, self._since = stage, volume, self._now()
            self._save()
            if self._stop is None and self._interval > 0:
                self._stop = threading.Event()
                threading.Thread(target=self._run, args=(self._stop,), daemon=True).start()

    def tick(self) -> None:
        with self._lock:
            if not self.stage:
                return
            self._book()
            if self.stage in (TRANSLATE, REFINE):       # the runner moves on to the polish by itself
                self.stage = REFINE if self._phase() == REFINE else TRANSLATE
            self._save()
        if self._on_tick:
            try:
                self._on_tick()
            except Exception as exc:  # a status that cannot be written is not worth a translation
                logger.debug("Status not written: %s", exc)

    def stop(self) -> None:
        with self._lock:
            self._book()
            self.stage = ""
            if self._stop is not None:
                self._stop.set()
                self._stop = None
            self._save()

    def _run(self, stop: threading.Event) -> None:
        while not stop.wait(self._interval):
            self.tick()

    def reset(self, volume: int) -> None:
        with self._lock:
            self._data["volumes"].pop(str(volume), None)
            self._save()

    def seconds(self, volume: int = 0) -> Dict[str, int]:
        """Whole seconds of the preparation and of ``volume``'s translation and polish."""
        with self._lock:
            of_volume = self._data["volumes"].get(str(volume), {})
            return {PREPARE: int(self._data.get(PREPARE, 0)),
                    TRANSLATE: int(of_volume.get(TRANSLATE, 0)),
                    REFINE: int(of_volume.get(REFINE, 0))}
