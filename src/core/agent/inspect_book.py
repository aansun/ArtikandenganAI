"""
What the app shows when a book is dropped in: title, author, volumes, fiction or not, and a
time estimate. One cheap classification call on the active engines; a local heuristic when no
engine is active or the call fails. Nothing is written.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from src.core.agent.classifier import classify_book, heuristic_profile
from src.core.agent.epub_metadata import read_metadata
from src.core.agent.volumes import clean_stem, count_volumes
from src.core.auto_prep import extract_source_text
from src.core.llm.exceptions import RateLimitError

#: Minutes of work per 1000 words, measured on a real novel (translation + polish pass).
MINUTES_PER_KWORD_FICTION = 1.1
MINUTES_PER_KWORD_OTHER = 0.55


def inspect_book(path: Path, llm_provider=None, *, target_language: str = "Indonesian") -> dict:
    """A JSON-ready description of the book at ``path``."""
    path = Path(path)
    first = path
    if path.is_dir():
        files = sorted(p for p in path.iterdir() if p.is_file())
        first = files[0] if files else path
    text = extract_source_text(file_path=str(first))
    meta = read_metadata(first) if first.suffix.lower() == ".epub" else {}
    volumes = count_volumes(path)
    profile = heuristic_profile(text, path.name)
    method = "heuristic"
    if llm_provider is not None and text.strip():
        try:
            profile = asyncio.run(classify_book(text, path.name, llm_provider, target_language=target_language))
            method = profile.method
        except RateLimitError:      # only a first look: the guess will do
            pass
    # Words of the whole file: the sampled text is capped, so scale by the file size.
    words = max(1, int(len(text) / 5.8))
    if first.exists() and first.suffix.lower() == ".epub":
        words = max(words, int(first.stat().st_size / 5))
    per_kword = MINUTES_PER_KWORD_FICTION if profile.is_fiction else MINUTES_PER_KWORD_OTHER
    return {
        "file": path.name,
        "title": meta.get("title") or profile.title or clean_stem(path.stem),
        "author": ", ".join(c for c in meta.get("creators", []) if c) or "",
        "volumes": volumes,
        "source_language": profile.source_language,
        "kind": "fiksi" if profile.is_fiction else "nonfiksi",
        "genre": profile.genre,
        "classified_by": method,
        "words": words,
        "estimated_minutes": int(words / 1000 * per_kword),
    }
