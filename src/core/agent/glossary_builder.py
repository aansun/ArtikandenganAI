"""
The book bible: one glossary for a whole multi-volume work, built from ALL of its text.

Fiction needs the same rendering of every name, place and invented term from
volume 1 to volume N, including entities that first appear in a late volume. So:

1. each volume is cut into parts, and the entity pass runs on every part (excerpts
   spread over the part plus a window around each recurring name found by a local
   scan), instead of one pass over a single sample;
2. the results of every part and volume merge, the earliest rendering winning;
3. one cleanup call drops what is not part of the story (generic words, boilerplate,
   passing references).

Names are preserved: a person, place, organisation or invented item written in the
Latin alphabet keeps its original form (``decision: keep``, "Baker Street -> Baker
Street"), and every form of it ("Holmes", "Sherlock Holmes") is its own entry, so the
translator can neither translate nor transliterate it and no short form is stretched
into the long one. A name in another script keeps the transliteration the model chose
(``decision: transliterate``), which then locks it across the book. The file is plain JSON in the format ``--glossary``
reads (extra fields are ignored by the engine), so it can be reviewed and edited by
hand: when it exists, the agent reuses it instead of rebuilding it.
"""

from __future__ import annotations

import json
import logging
import re
import unicodedata
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

from src.core.auto_prep import extract_source_text
from src.core.glossary.models import normalize_gender
from src.core.glossary.name_scan import take_glossary_samples
from src.core.glossary.ner import parse_ner_response, suggest_terms

logger = logging.getLogger("core.agent.glossary")

#: Upper bound on merged entries. Entries are filtered per chunk before they
#: reach a prompt, so this bounds file size and review effort, not token cost.
MAX_MERGED_TERMS = 400
#: Characters of source text one entity pass is responsible for.
PART_CHARS = 60_000
#: Parts per volume, at most (bounds the number of calls on very long volumes).
MAX_PARTS = 8
#: Characters handed to one entity pass.
SAMPLE_BUDGET = 14_000
SAMPLE_COUNT = 14
#: A consolidation that keeps fewer entries than this share of its input is ignored.
MIN_KEPT_SHARE = 0.5

#: Boilerplate of e-book sources, never part of the story.
_BOILERPLATE = re.compile(r"project gutenberg|gutenberg literary|z-?library|\b1lib\b|libgen", re.I)

#: Categories whose names are preserved rather than translated.
PRESERVED_CATEGORIES = frozenset({"character", "location", "organization", "item"})

_CONSOLIDATE_SYSTEM = (
    "You are an editor preparing the name list of a book for its translator. Answer with "
    "a JSON array between <NER_JSON> and </NER_JSON>, nothing else."
)

_CONSOLIDATE_PROMPT = """Below are the entries found in a {source_language} book, one per line as
source | {target_language} rendering | category | gender.

{lines}

Return the cleaned list as a JSON array of {{"source", "target", "category", "gender"}} objects:
- Drop common words, generic titles, real people or books only mentioned in passing, and
  anything that is not a name, place, organisation, item or invented term of the story.
- When an entry is a common noun or a title joined to a name ("Archivist Besh", "Captain Aldric",
  "tablet of Orun"), replace it by the proper name alone ("Besh", "Aldric", "Orun"): the common
  word is translated normally in the text, so it must not be locked.
- Keep every other entry exactly as given, one entry per form: do NOT merge entries.
- When two entries are forms of one character and only one states the gender, give both
  that gender.
- Never invent an entry that is not in the list.
Wrap the array in <NER_JSON></NER_JSON>."""


def _is_latin(text: str) -> bool:
    letters = [c for c in text if c.isalpha()]
    return bool(letters) and all(unicodedata.name(c, "").startswith("LATIN") for c in letters)


def candidate_entries(candidates: List[Dict[str, str]]) -> Dict[str, Dict[str, str]]:
    """``{source: {target, category, gender, decision}}`` from the entity pass.

    Names are preserved: a Latin-script person, place, organisation or item keeps its
    source form whatever the model proposed. Unlike the engine's own auto glossary,
    an unchanged name is kept as an entry, because that entry is what locks it.
    """
    entries: Dict[str, Dict[str, str]] = {}
    for candidate in candidates or []:
        if not isinstance(candidate, dict):
            continue
        source = str(candidate.get("source") or "").strip()
        target = str(candidate.get("target") or "").strip()
        if not source or not target or _BOILERPLATE.search(source) or source in entries:
            continue
        category = str(candidate.get("category") or "").strip().lower()
        if category in PRESERVED_CATEGORIES:
            if _is_latin(source):
                target, decision = source, "keep"
            else:
                decision = "transliterate"
        else:
            decision = "keep" if source.casefold() == target.casefold() else "translate"
        entry = {"target": target, "decision": decision}
        if category:
            entry["category"] = category
        gender = normalize_gender(candidate.get("gender"))
        if gender:
            entry["gender"] = gender
        entries[source] = entry
    return entries


def merge_terms(per_volume: Sequence[Dict[str, Dict[str, str]]],
                max_terms: int = MAX_MERGED_TERMS) -> List[Dict[str, str]]:
    """Merge ``{source: entry}`` maps; the earliest wins, and a later gender fills a gap."""
    merged: Dict[str, Dict[str, str]] = {}
    for terms in per_volume:
        for source, entry in terms.items():
            if _BOILERPLATE.search(source):
                continue
            key = source.casefold()
            if key in merged:
                known = merged[key]
                if known["target"] != entry["target"]:
                    logger.info("Glossary conflict for %r: keeping %r over %r",
                                source, known["target"], entry["target"])
                if "gender" not in known and entry.get("gender"):
                    known["gender"] = entry["gender"]
                continue
            if len(merged) >= max_terms:
                continue
            merged[key] = {"source": source, **entry}
    return list(merged.values())


def split_parts(text: str, part_chars: int = PART_CHARS, max_parts: int = MAX_PARTS) -> List[str]:
    """Cut ``text`` into equal parts of about ``part_chars``, at most ``max_parts`` of them."""
    if len(text) <= part_chars:
        return [text]
    count = min(max_parts, -(-len(text) // part_chars))
    size = -(-len(text) // count)
    return [text[i:i + size] for i in range(0, len(text), size)]


def _lines(entries: List[Dict[str, str]]) -> str:
    return "\n".join(
        f"{e['source']} | {e['target']} | {e.get('category', '')} | {e.get('gender', '')}"
        for e in entries)


async def consolidate(entries: List[Dict[str, str]], source_language: str, target_language: str,
                      llm_provider) -> List[Dict[str, str]]:
    """Drop what is not part of the story; the input list on any failure."""
    if len(entries) < 3:
        return entries
    prompt = _CONSOLIDATE_PROMPT.format(source_language=source_language,
                                        target_language=target_language, lines=_lines(entries))
    try:
        response = await llm_provider.generate(prompt, system_prompt=_CONSOLIDATE_SYSTEM)
        candidates, _warnings = parse_ner_response(getattr(response, "content", "") or "")
    except Exception as exc:  # consolidation is an improvement, never a blocker
        logger.info("Glossary consolidation failed (%s); keeping the merged list", exc)
        return entries
    cleaned = candidate_entries(candidates)
    if len(cleaned) < max(1, int(len(entries) * MIN_KEPT_SHARE)):
        logger.info("Glossary consolidation kept %d of %d entries; ignoring it",
                    len(cleaned), len(entries))
        return entries
    return [{"source": source, **entry} for source, entry in cleaned.items()]


def write_glossary(path: Path, terms: List[Dict[str, str]], source_language: str,
                   target_language: str) -> None:
    payload = {
        "name": path.stem,
        "source_language": source_language,
        "target_language": target_language,
        "note": ("decision 'keep' locks a name in its original form; 'transliterate' locks the "
                 "rendering of a name in another script; 'translate' gives a rendering. Edit freely."),
        "terms": terms,
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


async def build_glossary(volume_files: Sequence[Path], source_language: str,
                         target_language: str, llm_provider, output: Path,
                         progress: Optional[Callable[[str], None]] = None) -> int:
    """Build the bible of every volume, write ``output`` and return the term count.

    Returns 0 when nothing usable was found, in which case no file is written and
    translation proceeds without a glossary.
    """
    say = progress or (lambda message: None)
    per_volume: List[Dict[str, Dict[str, str]]] = []
    for n, path in enumerate(volume_files, 1):
        text = extract_source_text(file_path=str(path))
        if not text.strip():
            say(f"Glossary: volume {n} has no readable text, skipped")
            continue
        entries: Dict[str, Dict[str, str]] = {}
        parts = split_parts(text)
        for k, part in enumerate(parts, 1):
            sample, _count, _names = take_glossary_samples(
                part, SAMPLE_BUDGET, SAMPLE_COUNT, min_sample_size=500)
            try:
                candidates, warnings = await suggest_terms(
                    sample, source_language, target_language, llm_provider,
                    max_chars=SAMPLE_BUDGET)
            except Exception as exc:  # one failed part must not lose the others
                logger.info("Glossary part %d.%d failed: %s", n, k, exc)
                continue
            for warning in warnings or []:
                logger.info("Glossary %d.%d: %s", n, k, warning)
            for source, entry in candidate_entries(candidates).items():
                entries.setdefault(source, entry)
        say(f"Glossary: volume {n}/{len(volume_files)} -> {len(entries)} terms "
            f"from {len(parts)} part(s)")
        per_volume.append(entries)

    merged = merge_terms(per_volume)
    if not merged:
        return 0
    before = len(merged)
    merged = await consolidate(merged, source_language, target_language, llm_provider)
    if len(merged) != before:
        say(f"Glossary: consolidated {before} entries into {len(merged)}")
    write_glossary(output, merged, source_language, target_language)
    return len(merged)
