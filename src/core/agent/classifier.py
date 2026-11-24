"""
Work out what kind of book this is before translating it.

One cheap LLM call over excerpts returns the genre, the source language and
the title. When the call fails, a local heuristic (quote density for fiction,
``langdetect`` for the language) keeps the run going: classification never
blocks a translation.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Optional

from src.core.agent.routing import FICTION_GENRES
from src.utils import document_sampler

logger = logging.getLogger("core.agent.classifier")

GENRES = (
    "fiction_novel", "light_novel", "literary_fiction",
    "nonfiction_general", "business", "technical", "academic", "legal",
    "children", "simple", "other",
)

SAMPLE_CHARS = 6000
SAMPLE_PIECES = 6

_SYSTEM = (
    "You are a literary analyst. Classify the book from the excerpts and answer with "
    "one JSON object only, no commentary."
)

_PROMPT = """Filename: {filename}

Excerpts (separated by lines of ---):
{sample}

Return exactly this JSON:
{{"title": "<book title, in the source language if visible, else empty>",
  "title_translated": "<that title in {target_language}, as a published edition would call it>",
  "source_language": "<English name of the language the book is written in>",
  "genre": "<one of: {genres}>",
  "is_fiction": <true|false>,
  "reason": "<one short sentence>"}}"""

_LANG_NAMES = {
    "en": "English", "ja": "Japanese", "zh-cn": "Chinese", "zh-tw": "Chinese", "ko": "Korean",
    "fr": "French", "de": "German", "es": "Spanish", "ru": "Russian", "id": "Indonesian",
    "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "vi": "Vietnamese", "th": "Thai",
    "ar": "Arabic", "tr": "Turkish", "pl": "Polish",
}


@dataclass
class BookProfile:
    title: str
    source_language: str
    genre: str
    is_fiction: bool
    reason: str
    method: str  # "llm" or "heuristic"
    title_translated: str = ""


def parse_classification(raw: str) -> Optional[dict]:
    """First JSON object in ``raw``, or None."""
    if not raw:
        return None
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL)
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        data = json.loads(cleaned[start:end + 1])
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def heuristic_profile(text: str, filename: str = "") -> BookProfile:
    """Offline fallback: dialogue density decides fiction, langdetect the language."""
    sample = text[:60000]
    quotes = len(re.findall(r"[\"“”「」『』«»]", sample))
    density = quotes / max(1, len(sample)) * 1000
    fiction = density >= 4.0
    language = "English"
    try:
        from langdetect import detect
        language = _LANG_NAMES.get(detect(sample[:5000]), "English")
    except Exception:
        pass
    return BookProfile(
        title=re.sub(r"[_\-]+", " ", filename.rsplit(".", 1)[0]).strip(),
        source_language=language,
        genre="fiction_novel" if fiction else "nonfiction_general",
        is_fiction=fiction,
        reason=f"dialogue density {density:.1f} per 1000 characters",
        method="heuristic",
    )


async def classify_book(text: str, filename: str, llm_provider, *, model: Optional[str] = None,
                        target_language: str = "Indonesian") -> BookProfile:
    """Classify the book; never raises."""
    fallback = heuristic_profile(text, filename)
    if not text.strip():
        return fallback
    try:
        sample, _count = document_sampler.take_distributed_samples(
            text, SAMPLE_CHARS, SAMPLE_PIECES, min_sample_size=500, separator="\n---\n")
        response = await llm_provider.generate(
            _PROMPT.format(filename=filename, sample=sample, genres=", ".join(GENRES),
                                    target_language=target_language),
            system_prompt=_SYSTEM, model=model,
        )
    except Exception as exc:  # classification must never block the run
        logger.warning("Book classification failed (%s); using the heuristic", exc)
        return fallback
    data = parse_classification(getattr(response, "content", "") if response else "")
    if not data or data.get("genre") not in GENRES:
        logger.warning("Book classification returned no usable answer; using the heuristic")
        return fallback
    genre = data["genre"]
    return BookProfile(
        title=str(data.get("title") or fallback.title).strip(),
        title_translated=str(data.get("title_translated") or "").strip(),
        source_language=str(data.get("source_language") or fallback.source_language).strip(),
        genre=genre,
        is_fiction=bool(data.get("is_fiction")) or genre in FICTION_GENRES,
        reason=str(data.get("reason") or "").strip(),
        method="llm",
    )
