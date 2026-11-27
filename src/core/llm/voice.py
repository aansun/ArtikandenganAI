"""
The voice of a book, carried to whichever engine writes next.

Engines that take turns on one book each have their own diction. A short sample of what the
book's main engine wrote is kept in the book's folder (``voice.json``), one set for the
translation and one for the polish pass. A request that goes to any other engine gets it as
a reference: match how it sounds, never repeat its words. The engine that wrote the sample
gets nothing added, so a book written by one engine is asked exactly as before.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Dict, List

logger = logging.getLogger("llm.voice")

#: The steps whose writing is read in the book; every other request is left alone.
PHASES = ("translate", "refine")
SAMPLES = 2
SAMPLE_CHARS = 600
#: A shorter answer says too little about a voice.
MIN_CHARS = 300
#: This many characters of a sample found in an answer mean the sample was copied.
COPIED_CHARS = 60

REFERENCE = (
    "VOICE REFERENCE: passages already written for this same book. Write your answer in the "
    "same voice: the same choice of words, pronouns and forms of address, sentence rhythm and "
    "punctuation (including the kind of quotation marks). They are not part of your task: "
    "never translate, repeat or continue them.")

_ANSWER = re.compile(r"<TRANSLATION>(.*?)</TRANSLATION>", re.DOTALL)
#: Layout placeholders and tags: not part of how a text sounds.
_MARKUP = re.compile(r"\[id\d+\]|\[\[\d+\]\]|⟦\d+⟧|</?[A-Za-z][^>]*>")


def passage(answer: str) -> str:
    """A readable excerpt of an answer ('' when it is too short to show a voice)."""
    found = _ANSWER.findall(answer or "")
    text = " ".join(_MARKUP.sub(" ", found[-1] if found else answer or "").split())
    if len(text) < MIN_CHARS:
        return ""
    if len(text) <= SAMPLE_CHARS:
        return text
    sentences = re.split(r"(?<=[.!?”\"])\s+", text)
    # start where somebody speaks, if anybody does: address and punctuation show there
    start = next((i for i, s in enumerate(sentences) if s.startswith(("“", '"', "‘"))), 0)
    if len(" ".join(sentences[start:])) < MIN_CHARS:
        start = 0
    kept: List[str] = []
    for sentence in sentences[start:]:
        if kept and len(" ".join(kept + [sentence])) > SAMPLE_CHARS:
            break
        kept.append(sentence)
    return " ".join(kept)[:SAMPLE_CHARS]


class Voice:
    """The samples of one book. ``main`` is the provider name of its main engine."""

    def __init__(self, path: Path, main: str = ""):
        self.path, self.main = Path(path), main
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self.data: Dict[str, dict] = {k: v for k, v in data.items()
                                          if k in PHASES and v.get("samples")}
        except (OSError, ValueError, AttributeError):
            self.data = {}

    def note(self, phase: str, engine: str, answer: str) -> None:
        """Keep a sample of ``answer`` if its engine is the one whose voice the book follows."""
        if phase not in PHASES:
            return
        known = self.data.get(phase)
        # the main engine's voice replaces a stand-in's
        replaces = known is not None and engine == self.main and known["engine"] != self.main
        if known is not None and not replaces and (known["engine"] != engine
                                                   or len(known["samples"]) >= SAMPLES):
            return
        text = passage(answer)
        if not text:
            return
        if known is None or replaces:
            self.data[phase] = {"engine": engine, "samples": [text]}
        else:
            known["samples"].append(text)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp.replace(self.path)
        except OSError as exc:
            logger.debug("Voice sample not saved: %s", exc)

    def reference(self, phase: str, engine: str) -> str:
        """What to add to a request that goes to ``engine`` ('' for the sample's own engine)."""
        known = self.data.get(phase)
        if not known or known["engine"] == engine:
            return ""
        return REFERENCE + "\n<voice>\n" + "\n---\n".join(known["samples"]) + "\n</voice>"

    def copied(self, phase: str, answer: str, asked: str) -> bool:
        """Did the answer take words from the samples that the request did not hold?"""
        answer, asked = " ".join((answer or "").split()), " ".join((asked or "").split())
        for sample in self.data.get(phase, {}).get("samples", []):
            for start in range(0, max(1, len(sample) - COPIED_CHARS + 1), COPIED_CHARS // 3):
                piece = sample[start:start + COPIED_CHARS]
                if len(piece) == COPIED_CHARS and piece in answer and piece not in asked:
                    return True
        return False
