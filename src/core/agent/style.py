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

import json
import logging
import re
from pathlib import Path
from typing import Dict, List

from src.core.llm.exceptions import RateLimitError
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

Direction chosen for this book: {direction}

Write the style guide for translating this book into {target_language}. Use exactly these
sections, each with 2-4 short, concrete bullets decided FROM THE EXCERPTS (not generic advice):

## Register and address
Fixed rules, one bullet per pair of main speakers and one for the narrator: the exact
{target_language} words for "I" and "you" (for Indonesian: saya/aku, Anda/kamu/kau, dia; titles
such as Tuan/Nyonya), and the level of formality.

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

#: Added to the style of a book that is only polished: its pronouns are already chosen.
KEEP_PRONOUNS_TITLE = "## Pronouns already in the text"
KEEP_PRONOUNS = (KEEP_PRONOUNS_TITLE + "\n- Keep every pronoun and form of address exactly as the draft "
                 "has it; this overrides any other rule about them.")

#: The styles offered to the user: id -> (name, what it means for the translation).
STYLE_PRESETS = {
    "formal": ("Formal and restrained",
               "Use saya and Anda between characters, complete sentences and a polite, measured tone."),
    "santai": ("Casual and modern",
               "Use aku and kamu between close characters, short sentences and easy, everyday wording."),
    "sastra": ("Literary and poetic",
               "Rich diction, long rhythmic sentences, with atmosphere and imagery emphasised."),
}

_RECOMMEND_SYSTEM = "You are a literary translator choosing a style. Answer with one JSON object only."

_RECOMMEND_PROMPT = """Book: {title} ({genre}), {source_language} -> {target_language}.

Excerpts (separated by lines of ---):
{sample}

Choose the best translation style for this book from:
{options}

Return exactly: {{"style": "<formal|santai|sastra>", "why": "<one sentence in Indonesian saying what in the book \
makes this style fit>"}}"""

_CALIBRATION_NOTE = (
    "Calibration samples: the same glossary and style guide as the full translation, "
    "applied to two passages. Judge naturalness, meaning and names here; edit `glossary.json` "
    "or `style.md`, delete this file and run again to see the effect.")


def is_indonesian(target_language: str) -> bool:
    return target_language.strip().lower() in ("indonesian", "bahasa indonesia", "id")


#: The same styles for any other target language: the Indonesian pronouns are left out.
GENERIC_STYLE_PRESETS = {
    "formal": ("Formal and restrained",
               "Use the polite, formal register and forms of address of the target language, "
               "complete sentences and a measured tone."),
    "santai": ("Casual and modern",
               "Use the informal register and everyday forms of address between close characters, "
               "short sentences and easy, everyday wording."),
    "sastra": STYLE_PRESETS["sastra"],
}


def presets_for(target_language: str) -> dict:
    """The style options (id -> (name, meaning)) that fit the target language."""
    return STYLE_PRESETS if is_indonesian(target_language) else GENERIC_STYLE_PRESETS


def baseline_for(target_language: str) -> str:
    return INDONESIAN_BASELINE if is_indonesian(target_language) else ""


def _cast(terms: List[Dict[str, str]]) -> str:
    rows = [f"- {t['source'].split('|')[0]} ({t.get('gender') or 'unknown'})"
            for t in terms if t.get("category") == "character"][:25]
    return "\n".join(rows) or "(none found)"


def keep_pronouns(style: str) -> str:
    """The style of a polish: its rules on register and address would change pronouns the book
    already has, so they give way to one rule that keeps them."""
    style = re.sub(r"(?ms)^## Register and address\n.*?(?=^## |\Z)", "", style)
    return style.rstrip() + "\n\n" + KEEP_PRONOUNS + "\n"


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


def _json_object(raw: str) -> dict:
    start, end = raw.find("{"), raw.rfind("}")
    try:
        data = json.loads(raw[start:end + 1]) if 0 <= start < end else {}
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def heuristic_style(profile) -> dict:
    """Offline recommendation from the genre alone."""
    pick = {"literary_fiction": "sastra", "light_novel": "santai"}.get(profile.genre, "formal")
    return {"id": pick, "why": "Disarankan dari jenis bukunya; belum dibaca isinya.", "method": "heuristic"}


async def recommend_style(text: str, profile, target_language: str, llm_provider) -> dict:
    """``{"id", "why", "method"}``: the style that fits the book's content; never raises."""
    fallback = heuristic_style(profile)
    if not text.strip():
        return fallback
    sample, _n = document_sampler.take_distributed_samples(
        text, SAMPLE_CHARS, SAMPLE_PIECES, min_sample_size=500, separator="\n---\n")
    presets = presets_for(target_language)
    options = "\n".join(f"- {key}: {name}. {meaning}" for key, (name, meaning) in presets.items())
    try:
        response = await llm_provider.generate(
            _RECOMMEND_PROMPT.format(title=profile.title or "untitled", genre=profile.genre,
                                     source_language=profile.source_language,
                                     target_language=target_language, sample=sample, options=options),
            system_prompt=_RECOMMEND_SYSTEM)
        data = _json_object(getattr(response, "content", "") or "")
    except RateLimitError:
        raise
    except Exception as exc:
        logger.info("Style recommendation failed (%s); using the genre", exc)
        return fallback
    if data.get("style") not in presets:
        return fallback
    return {"id": data["style"], "why": str(data.get("why") or "").strip() or fallback["why"],
            "method": "llm"}


def write_style_choice(path: Path, recommended: dict, chosen: str,
                       target_language: str = "Indonesian") -> None:
    """style.json: the options, the recommendation and the choice, for the app to show."""
    path.write_text(json.dumps({
        "options": [{"id": k, "name": n, "description": d} for k, (n, d) in presets_for(target_language).items()],
        "recommended": recommended["id"], "why": recommended["why"], "chosen": chosen,
    }, ensure_ascii=False, indent=2), encoding="utf-8")


async def build_style_guide(text: str, profile, target_language: str, terms: List[Dict[str, str]],
                            llm_provider, output: Path, direction: str = "") -> str:
    """Write ``output`` (``style.md``) and return its text; the baseline alone on failure."""
    baseline = baseline_for(target_language)
    generated = ""
    if text.strip():
        sample, _n = document_sampler.take_distributed_samples(
            text, SAMPLE_CHARS, SAMPLE_PIECES, min_sample_size=500, separator="\n---\n")
        prompt = _PROMPT.format(
            title=profile.title or "untitled", genre=profile.genre,
            source_language=profile.source_language, target_language=target_language,
            cast=_cast(terms), sample=sample, direction=direction or "none, decide from the excerpts")
        try:
            response = await llm_provider.generate(prompt, system_prompt=_SYSTEM)
            generated = _clean_sections(getattr(response, "content", "") or "")
        except RateLimitError:
            raise
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
        except RateLimitError:
            raise
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
