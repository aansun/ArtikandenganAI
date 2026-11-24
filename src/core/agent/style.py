"""
The style guide and the calibration samples.

A translation reads naturally when every chunk follows the same decisions on
register, narrator voice and dialogue. Left to itself, each chunk re-decides them.
So, before translating:

* ``build_style_guide`` writes ``style.md``: a fixed baseline for the target language
  plus book-specific decisions made once by the model from excerpts and the cast.
  The file is plain Markdown: edit it, and the edited text is what the translation
  and the polish pass receive.
* ``calibrate`` translates two short passages with the glossary and the style guide
  and writes ``calibration.md`` (source next to translation), so quality can be judged
  on a few paragraphs before the whole book is spent.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Dict, List

from src.utils import document_sampler

logger = logging.getLogger("core.agent.style")

SAMPLE_CHARS = 7000
SAMPLE_PIECES = 6
CALIBRATION_PASSAGES = 2
CALIBRATION_CHARS = 1200

#: Fixed rules for Indonesian literary translation. Short on purpose: every line of
#: a prompt dilutes the others.
INDONESIAN_BASELINE = """\
- Write natural, idiomatic Indonesian a native reader would enjoy; never word for word.
- Keep the exact meaning, facts, tone and level of detail of the source: do not add, omit or soften.
- Prefer active sentences and plain connectives; avoid the translationese of "adalah", "telah" and "merupakan" in every sentence.
- Translate idioms and figurative language by their sense; keep a metaphor only if it works in Indonesian.
- Keep every name of a person, place, organisation and invented term exactly as the glossary gives it.
- Use the dialogue punctuation of the source; keep each speaker's voice distinct.
- Keep numbers, units and dates as in the source unless the glossary says otherwise."""

_SYSTEM = ("You are a senior literary translator and editor writing a style guide for the "
           "translator of one book. Be specific to this book; answer in Markdown only.")

_PROMPT = """Book: {title} ({genre}), {source_language} -> {target_language}.

Cast (name, gender):
{cast}

Excerpts (separated by lines of ---):
{sample}

Write the style guide for translating this book into {target_language}. Use exactly these
sections, each with 2-4 short, concrete bullets decided FROM THE EXCERPTS (not generic advice):

## Register and address
Which pronouns and forms of address {target_language} should use between the main characters
and for the narrator (for Indonesian: saya/aku/kamu/Anda/dia, titles such as Tuan/Nyonya), and
the level of formality.

## Narration
Voice, tense, rhythm and diction suited to the period and genre.

## Dialogue
How speech sounds for the main characters, interjections, oaths, regional or class markers.

## Names, titles and terms
How honorifics, ranks, foreign words and invented terms are treated.

## Avoid
Pitfalls specific to this book.

Rules for the guide: at most 350 words in total; every bullet specific to this book; never tell
the translator to omit, summarize, skip or reorder any text of the book (front and back matter
are translated like everything else); leave how names are written to the glossary.
Output the five sections only."""

_CALIBRATION_NOTE = (
    "Calibration samples: the same glossary and style guide as the full translation, "
    "applied to two passages. Judge naturalness, meaning and names here; edit `glossary.json` "
    "or `style.md`, delete this file and run again to see the effect.")


def baseline_for(target_language: str) -> str:
    return INDONESIAN_BASELINE if target_language.strip().lower() in (
        "indonesian", "bahasa indonesia", "id") else ""


def _cast(terms: List[Dict[str, str]]) -> str:
    rows = [f"- {t['source'].split('|')[0]} ({t.get('gender') or 'unknown'})"
            for t in terms if t.get("category") == "character"][:25]
    return "\n".join(rows) or "(none found)"


def compose_style(baseline: str, generated: str) -> str:
    parts = ["# Style guide", ""]
    if baseline:
        parts += ["## Baseline", baseline, ""]
    if generated:
        parts += [generated.strip(), ""]
    return "\n".join(parts).strip() + "\n"


def refinement_instructions(style: str, target_language: str) -> str:
    """The polish pass: smooth the draft without touching meaning, names or terms."""
    return (
        f"Polish this {target_language} translation so it reads as if written in "
        f"{target_language}: fix stiff or literal phrasing, awkward word order and repeated "
        "constructions. Never change the meaning, facts, names or glossary terms, and never add "
        "or remove content. Follow this style guide:\n\n" + style)


async def build_style_guide(text: str, profile, target_language: str, terms: List[Dict[str, str]],
                            llm_provider, output: Path) -> str:
    """Write ``output`` (``style.md``) and return its text; the baseline alone on failure."""
    baseline = baseline_for(target_language)
    generated = ""
    if text.strip():
        sample, _n = document_sampler.take_distributed_samples(
            text, SAMPLE_CHARS, SAMPLE_PIECES, min_sample_size=500, separator="\n---\n")
        prompt = _PROMPT.format(
            title=profile.title or "untitled", genre=profile.genre,
            source_language=profile.source_language, target_language=target_language,
            cast=_cast(terms), sample=sample)
        try:
            response = await llm_provider.generate(prompt, system_prompt=_SYSTEM)
            generated = _clean_sections(getattr(response, "content", "") or "")
        except Exception as exc:  # the baseline still applies
            logger.info("Style guide generation failed (%s); using the baseline only", exc)
    style = compose_style(baseline, generated)
    output.write_text(style, encoding="utf-8")
    return style


def _clean_sections(raw: str) -> str:
    """Keep the Markdown from the first '## ' heading on (drops chatter around it)."""
    raw = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL)
    start = raw.find("## ")
    return raw[start:].strip() if start != -1 else ""


def pick_passages(text: str, count: int = CALIBRATION_PASSAGES,
                  size: int = CALIBRATION_CHARS) -> List[str]:
    """Passages that show the translation at its hardest: the opening narration, then the
    most dialogue-dense stretch."""
    text = text.strip()
    if len(text) <= size:
        return [text] if text else []
    first = len(text) // 12
    passages = [_trim(text[first:first + size])]
    best, best_density = None, -1.0
    # Stay inside the story: front and back matter (licences, notes) are skipped, and so is
    # any window full of brackets, which is notes rather than prose.
    for start in range(len(text) // 5, int(len(text) * 0.85) - size, max(size // 2, 1)):
        window = text[start:start + size]
        if window.count("[") > 2:
            continue
        density = len(re.findall(r"[\"“”「」『』«»]", window)) / size
        if density > best_density:
            best, best_density = window, density
    if best and count > 1:
        passages.append(_trim(best))
    return passages[:count]


_SENTENCE_END = re.compile(r'[.!?]["”»]?\s+(?=["“«]?[A-Z])')


def _trim(passage: str) -> str:
    """Cut a passage at sentence edges, never mid-sentence, and restore dialogue lines."""
    passage = passage.strip()
    start = _SENTENCE_END.search(passage)
    if start and start.end() < len(passage) // 3:
        passage = passage[start.end():]
    ends = list(_SENTENCE_END.finditer(passage))
    if ends and ends[-1].start() > len(passage) // 2:
        passage = passage[:ends[-1].start() + 1]
    # Extraction can run paragraphs together: a quote closed and another opened is a new line.
    return re.sub(r'([.!?]["”»])(?=["“«])', r"\1\n\n", passage).strip()


async def calibrate(text: str, profile, target_language: str, prompt_options: Dict,
                    llm_provider, output: Path) -> int:
    """Translate the calibration passages and write ``output``; returns how many succeeded."""
    from src.core.translator import _build_chunk_glossary_block
    from src.prompts.prompts import generate_translation_prompt

    sections = [f"# Calibration - {profile.title}", "", _CALIBRATION_NOTE, ""]
    done = 0
    for number, passage in enumerate(pick_passages(text), 1):
        glossary_block = _build_chunk_glossary_block(
            passage, prompt_options, target_language=target_language)
        prompt = generate_translation_prompt(
            main_content=passage, previous_translation_context="",
            source_language=profile.source_language, target_language=target_language,
            has_placeholders=False, prompt_options=prompt_options, glossary_block=glossary_block)
        try:
            response = await llm_provider.generate(prompt.user, system_prompt=prompt.system)
        except Exception as exc:
            logger.info("Calibration passage %d failed: %s", number, exc)
            continue
        content = getattr(response, "content", "") if response else ""
        translated = llm_provider.extract_translation(content) or content
        if not translated.strip():
            continue
        done += 1
        sections += [f"## Passage {number}", "", "**Source**", "", passage, "",
                     "**Translation**", "", translated.strip(), ""]
    if done:
        output.write_text("\n".join(sections), encoding="utf-8")
    return done
