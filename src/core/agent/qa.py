"""
Quality checks on a finished volume, and the repair of name variants.

``audit_volume`` compares every translated document with its source and flags what a
translator, human or machine, typically gets wrong without any error being raised:

* length: far shorter (omission) or far longer (addition) than the source;
* numbers: digits of the source that are gone from the translation;
* dialogue: a very different number of quotation marks;
* untranslated: source-language function words still dominating the text;
* structure: a different number of paragraphs;
* glossary: a locked name that occurs in the source but never in the translation.

``find_name_variants`` finds the other classic failure of long books: a name that drifted
("Lestrade" ... "Lestrada"). A capitalised word in the middle of a sentence that is not in
the source, not in the glossary, and one or two letters away from a locked name is a
variant; ``apply_variant_fixes`` repairs them with the engine's literal term-fix (no LLM,
only exact whole-word replacements).
"""

from __future__ import annotations

import logging
import re
import zipfile
from collections import Counter
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from lxml import etree

logger = logging.getLogger("core.agent.qa")

#: Words in the translation / words in the source outside this window are flagged.
RATIO_LOW, RATIO_HIGH = 0.6, 1.8
#: Documents shorter than this (words) are too small for ratio and dialogue checks.
MIN_WORDS = 80
QUOTE_DRIFT = 0.35
ENGLISH_SHARE = 0.03
SIMILARITY = 0.82

_QUOTES = re.compile(r"[\"“”「」『』«»]")
_DIGITS = re.compile(r"\d[\d.,]*\d|\d")
_ENGLISH = frozenset("the and of to was he his that with for had you not this but from are "
                     "which have been they would there their what said".split())
_CAPITALISED = re.compile(r"(?<=[a-z,;] )([A-Z][\w’'-]{3,})")
_ANY_CAPITALISED = re.compile(r"\b[A-Z][\w’'-]{3,}")
_SKIPPED_DOCS = ("nav", "tbl-attribution", "toc")


def _plain(html: bytes) -> str:
    try:
        doc = etree.fromstring(html, etree.HTMLParser())
    except Exception:
        return ""
    for node in doc.xpath("//style|//script"):
        node.getparent().remove(node)
    return " ".join("".join(doc.itertext()).split())


def load_documents(path: Path) -> Dict[str, Tuple[str, int]]:
    """``{document: (text, paragraph count)}`` of an EPUB, or the whole text of a TXT file."""
    path = Path(path)
    if path.suffix.lower() != ".epub":
        text = path.read_text(encoding="utf-8", errors="replace")
        return {path.name: (" ".join(text.split()), len([p for p in text.split("\n\n") if p.strip()]))}
    documents: Dict[str, Tuple[str, int]] = {}
    with zipfile.ZipFile(path) as z:
        for name in sorted(z.namelist()):
            base = name.rsplit("/", 1)[-1].lower()
            if not name.lower().endswith((".xhtml", ".html")) or any(s in base for s in _SKIPPED_DOCS):
                continue
            raw = z.read(name)
            documents[name] = (_plain(raw), raw.lower().count(b"<p"))
    return documents


def _words(text: str) -> List[str]:
    return re.findall(r"\w+", text.lower())


def _count(form: str, text: str) -> int:
    return len(re.findall(r"(?<!\w)" + re.escape(form) + r"(?!\w)", text))


@dataclass
class DocResult:
    name: str
    source_words: int
    output_words: int
    flags: List[str] = field(default_factory=list)


def audit_pair(name: str, source: str, output: str, source_paragraphs: int, output_paragraphs: int,
               entries: Sequence[Dict[str, str]]) -> DocResult:
    sw, ow = _words(source), _words(output)
    result = DocResult(name, len(sw), len(ow))
    if len(sw) >= MIN_WORDS:
        ratio = len(ow) / max(1, len(sw))
        if ratio < RATIO_LOW:
            result.flags.append(f"much shorter than the source ({ratio:.2f}x): possible omission")
        elif ratio > RATIO_HIGH:
            result.flags.append(f"much longer than the source ({ratio:.2f}x): possible addition")
        qs, qo = len(_QUOTES.findall(source)), len(_QUOTES.findall(output))
        if max(qs, qo) >= 6 and abs(qs - qo) / max(qs, qo) > QUOTE_DRIFT:
            result.flags.append(f"dialogue marks differ ({qs} in the source, {qo} in the translation)")
        english = sum(w in _ENGLISH for w in ow) / max(1, len(ow))
        if english > ENGLISH_SHARE:
            result.flags.append(f"{english:.0%} source-language function words: untranslated passage")
    missing = sorted({d for d in _DIGITS.findall(source) if d not in output})
    if len(missing) >= 2:
        result.flags.append("numbers missing from the translation: " + ", ".join(missing[:6]))
    if source_paragraphs and output_paragraphs and source_paragraphs != output_paragraphs:
        result.flags.append(f"paragraphs: {source_paragraphs} in the source, {output_paragraphs} in the translation")
    for entry in entries:
        target = entry.get("target", "")
        for form in entry["source"].split("|"):
            # "Mormons" is rendered "Mormon" in Indonesian: a trailing plural -s is not a loss
            rendered = _count(target, output) or _count(target.rstrip("sS"), output) if target else 1
            if _count(form, source) >= 3 and not rendered:
                result.flags.append(f"locked term never rendered: '{form}' -> '{target}'")
                break
    return result


def audit_volume(source: Path, output: Path, entries: Sequence[Dict[str, str]],
                 skip: Sequence[str] = ()) -> List[DocResult]:
    """Audit every document of ``output`` against the same document of ``source``.

    ``skip`` names source documents that are deliberately not in the translation.
    """
    src, out = load_documents(source), load_documents(output)
    src = {name: doc for name, doc in src.items() if name not in set(skip)}
    if len(src) == 1 and len(out) == 1:  # a plain-text book: one document each side
        src = {next(iter(out)): next(iter(src.values()))}
    results = []
    for name, (source_text, source_paragraphs) in src.items():
        if name not in out:
            results.append(DocResult(name, len(_words(source_text)), 0, ["missing from the translation"]))
            continue
        output_text, output_paragraphs = out[name]
        results.append(audit_pair(name, source_text, output_text, source_paragraphs,
                                  output_paragraphs, entries))
    return results


def find_name_variants(source_text: str, output_text: str,
                       entries: Sequence[Dict[str, str]]) -> Dict[str, Tuple[str, int]]:
    """``{variant: (locked name it resembles, occurrences)}`` for the drifted names of a translation."""
    locked = {token for e in entries if e.get("decision") in ("keep", "transliterate")
              for token in re.findall(r"[\w’'-]+", e.get("target", ""))
              if token[:1].isupper() and len(token) >= 4}
    known = set(_ANY_CAPITALISED.findall(source_text))
    for e in entries:
        for form in e["source"].split("|") + [e.get("target", "")]:
            known.update(re.findall(r"[\w’'-]+", form))
    # A locked term that is also an ordinary word of the source ("Standard" / "standards") cannot
    # be told from its legitimate translation ("Standar"): its variants are not hunted.
    common = {w for w in re.findall(r"\b[a-z][\w\u2019'-]+\b", source_text)}
    locked = {name for name in locked
              if name.lower() not in common and name.lower() + "s" not in common}
    variants: Dict[str, Tuple[str, int]] = {}
    for token, count in Counter(_CAPITALISED.findall(output_text)).items():
        if token in known or token in locked:
            continue
        best = max(locked, key=lambda name: SequenceMatcher(None, token, name).ratio(), default="")
        if (best and token[0] == best[0] and abs(len(token) - len(best)) <= 2
                and SequenceMatcher(None, token, best).ratio() >= SIMILARITY):
            variants[token] = (best, count)
    return variants


def write_rules(path: Path, variants: Dict[str, Tuple[str, int]]) -> None:
    """The term-fix rules file: one ``variant -> locked name`` line per canonical name."""
    grouped: Dict[str, List[str]] = {}
    for variant, (canonical, _count_) in variants.items():
        grouped.setdefault(canonical, []).append(variant)
    path.write_text("".join(f"{'|'.join(forms)} -> {canonical}\n" for canonical, forms in grouped.items()),
                    encoding="utf-8")


def apply_variant_fixes(output: Path, rules: Path, target_language: str, run_job) -> bool:
    """Repair ``output`` in place with the literal term-fix; ``run_job(argv)`` runs it.

    Returns True when the file was replaced.
    """
    fixed = output.with_name(output.stem + ".fixed" + output.suffix)
    status_ok = run_job(["-i", str(output), "-o", str(fixed), "-tl", target_language,
                         "--fix-terms", str(rules), "--fix-terms-mode", "literal"])
    # the engine writes a change report next to its output: it is not part of the book's files
    fixed.with_name(fixed.stem + ".term-fix.md").unlink(missing_ok=True)
    if status_ok and fixed.exists() and fixed.stat().st_size > 0:
        fixed.replace(output)
        return True
    fixed.unlink(missing_ok=True)
    return False


def report_markdown(title: str, volumes: List[Tuple[str, List[DocResult], Dict[str, str]]]) -> str:
    """The QA report of a book. ``volumes`` is ``[(label, results, fixed variants)]``."""
    flagged = sum(1 for _label, results, _fixed in volumes for r in results if r.flags)
    lines = [f"# Quality report - {title}", "",
             f"{flagged} document(s) flagged. Flags are things to look at, not proven errors.", ""]
    for label, results, fixed in volumes:
        lines += [f"## {label}", ""]
        if fixed:
            lines += ["Name variants repaired: " + ", ".join(f"{v} -> {c}" for v, c in fixed.items()), ""]
        rows = [r for r in results if r.flags]
        if not rows:
            lines += [f"All {len(results)} documents passed.", ""]
            continue
        lines += ["| Document | Words (source / translation) | Flags |", "|---|---|---|"]
        for r in rows:
            lines.append(f"| {r.name} | {r.source_words} / {r.output_words} | "
                         + "; ".join(f.replace("|", "/") for f in r.flags) + " |")
        lines.append("")
    return "\n".join(lines)
