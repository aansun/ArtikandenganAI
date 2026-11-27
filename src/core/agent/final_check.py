"""
The check made after a book is translated: is the result whole and sound?

Each volume is compared with what it was made from, without asking any model, so the check
is quick and can be repeated. It looks for the ways a translation has actually gone wrong:
a damaged file, pages or paragraphs that did not arrive, passages far shorter than the
original or left in the source language, links that stopped working, dialogue marks that
differ between chapters, doubtful names and missing book details. It cannot tell whether
the prose is right or reads well, and it never changes the translation.

Every check has a level: ``ok``, ``info`` (worth knowing), ``warn`` (look at it) or
``fail`` (part of the book is probably missing or the file is damaged).
"""

from __future__ import annotations

import json
import logging
import posixpath
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence
from urllib.parse import unquote

from lxml import etree

from src.core.agent import qa
from src.core.agent.epub_metadata import audit_metadata
from src.core.agent.intake import boilerplate_reason, judge_page
from src.core.agent.volumes import _Epub

logger = logging.getLogger("core.agent.check")

REPORT = "check.json"
LEVELS = ("ok", "info", "warn", "fail")

#: A page of the upload with more words than this must be in the translation.
STORY_PAGE_WORDS = 300
#: A page about the e-book itself (header, transcriber's note) is at most this long.
BOOK_MATTER_WORDS = 800
SMALL_PAGE_WORDS = 60
#: A paragraph of the source this long...
LONG_PARAGRAPH = 220          # characters
#: ...whose translation is shorter than this share has probably lost sentences.
SHORT_PARAGRAPH_SHARE = 0.35
#: A paragraph of this many words found unchanged in the translation was not translated.
COPIED_WORDS = 12
MAX_ITEMS = 8
#: A locked name this many times more frequent than in the original, and by at least this much.
SURPLUS_FACTOR, SURPLUS_MINIMUM = 2, 20
_BLOCKS = ("p", "h1", "h2", "h3", "h4", "h5", "h6", "li")
_SKIP = ("nav", "tbl-attribution", "toc")


def _result(check: str, level: str = "ok", items: Sequence[str] = (), count: Optional[int] = None) -> dict:
    return {"id": check, "level": level, "count": len(items) if count is None else count,
            "items": list(items)[:MAX_ITEMS]}


def worst(levels: Sequence[str]) -> str:
    return max(levels, key=LEVELS.index, default="ok")


def _name(path: str) -> str:
    return path.rsplit("/", 1)[-1]


class _Book:
    """The pages of an EPUB in reading order.

    With ``cut``, a page is read without the licence text the intake cuts from it, so a
    source is compared as it was meant to be translated.
    """

    def __init__(self, path: Path, cut: bool = False):
        self.zip = zipfile.ZipFile(path)
        epub = _Epub(path)
        self.spine = [p for _i, p in epub.spine]
        self.raw = {p: self.zip.read(p) for p in self.spine if p in self.zip.namelist()}
        if cut:
            for page, data in self.raw.items():
                replacement = judge_page(data)[1]
                if replacement is not None:
                    self.raw[page] = replacement

    def pages(self) -> List[str]:
        return [p for p in self.spine
                if p in self.raw and not any(s in _name(p).lower() for s in _SKIP)]

    def blocks(self, page: str) -> List[str]:
        root = etree.fromstring(self.raw[page], etree.HTMLParser(encoding="utf-8"))
        if root is None:
            return []
        found = (" ".join("".join(e.itertext()).split()) for e in root.iter(*_BLOCKS))
        return [text for text in found if text]

    def text(self, page: str) -> str:
        return qa._plain(self.raw[page])

    def broken_links(self) -> set:
        """``(page, target)`` of the internal links that lead nowhere."""
        names = set(self.zip.namelist())
        ids: Dict[str, set] = {}
        broken = set()
        for page, raw in self.raw.items():
            for href in re.findall(rb"""<a\b[^>]*?\bhref\s*=\s*["']([^"']*#[^"']+)["']""", raw):
                target, _, anchor = unquote(href.decode("utf-8", "ignore")).partition("#")
                if ":" in target:
                    continue
                path = posixpath.normpath(posixpath.join(posixpath.dirname(page), target)) if target else page
                if path not in ids:
                    data = self.zip.read(path) if path in names else b""
                    ids[path] = {m.decode("utf-8", "ignore") for m in
                                 re.findall(rb"""\b(?:id|name)\s*=\s*["']([^"']+)["']""", data)}
                if anchor not in ids[path]:
                    broken.add((page, f"{_name(path)}#{anchor}"))
        return broken


def _file_check(output: Path) -> dict:
    problems: List[str] = []
    try:
        with zipfile.ZipFile(output) as z:
            if z.testzip():
                problems.append(f"{z.testzip()}: damaged")
            for name in z.namelist():
                if name.lower().endswith((".xhtml", ".opf", ".ncx")):
                    try:
                        etree.fromstring(z.read(name), etree.XMLParser(resolve_entities=False))
                    except etree.XMLSyntaxError as exc:
                        problems.append(f"{_name(name)}: {str(exc)[:80]}")
    except (OSError, zipfile.BadZipFile) as exc:
        problems.append(str(exc)[:120])
    return _result("file", "fail" if problems else "ok", problems)


def _pages_check(source: _Book, output: _Book, upload: Optional[_Book]) -> dict:
    """Pages that did not arrive. The upload is looked at too: cleaning must not eat the book."""
    missing, small = [], []
    pages = [(source, p) for p in source.pages()]
    if upload is not None:
        pages += [(upload, p) for p in upload.pages() if p not in source.raw]
    for book, page in pages:
        if page in output.raw:
            continue
        text = book.text(page)
        words, reason = len(text.split()), boilerplate_reason(text)
        if words <= SMALL_PAGE_WORDS or reason == "licence text":
            continue
        if reason and words <= BOOK_MATTER_WORDS or book is upload and words <= STORY_PAGE_WORDS:
            small.append(f"{_name(page)} ({words} words, left out as not part of the book)")
        else:
            missing.append(f"{_name(page)} ({words} words)")
    if missing:
        return _result("pages", "fail", missing)
    return _result("pages", "info" if small else "ok", small)


def _text_checks(source: _Book, output: _Book, translate_language: bool) -> List[dict]:
    paragraphs, shorter, longer, lost, copied = [], [], [], [], []
    styles: Dict[str, str] = {}
    for page in source.pages():
        if page not in output.raw:
            continue
        a, b = source.blocks(page), output.blocks(page)
        before, after = source.text(page), output.text(page)
        words_a, words_b = len(before.split()), len(after.split())
        if abs(len(a) - len(b)) > max(2, len(a) // 50):
            paragraphs.append(f"{_name(page)}: {len(a)} -> {len(b)}")
        if words_a >= qa.MIN_WORDS:
            ratio = words_b / words_a
            if ratio < qa.RATIO_LOW:
                shorter.append(f"{_name(page)} ({ratio:.2f}x)")
            elif ratio > qa.RATIO_HIGH:
                longer.append(f"{_name(page)} ({ratio:.2f}x)")
        if len(a) == len(b):
            for x, y in zip(a, b):
                if len(x) >= LONG_PARAGRAPH and len(y) < SHORT_PARAGRAPH_SHARE * len(x):
                    lost.append(f"{_name(page)}: {x[:70]}…")
        if translate_language:
            seen = set(a)
            copied += [f"{_name(page)}: {y[:70]}…" for y in b
                       if y in seen and len(y.split()) >= COPIED_WORDS]
        double = len(re.findall("[“”\"]", after))
        single = len(re.findall("‘|(?<![\\w])'|(?<![\\w])’|(?<=[.,!?])['’]", after))
        if double + single >= 20:
            styles[_name(page)] = "double" if double >= single else "single"
    minority = []
    if len(set(styles.values())) > 1:
        usual = max(("double", "single"), key=list(styles.values()).count)
        minority = [f"{page}: {style}" for page, style in styles.items() if style != usual]
    return [
        _result("paragraphs", "warn" if paragraphs else "ok", paragraphs),
        _result("length", "fail" if shorter else ("warn" if lost or longer else "ok"), shorter + lost + longer),
        _result("untranslated", "warn" if copied else "ok", copied),
        _result("quotes", "warn" if minority else "ok", minority),
    ]


def _surplus(source_text: str, output_text: str, entries: Sequence[Dict[str, str]]) -> List[str]:
    """Locked names found far more often than in the original: a sign of wrong replacements."""
    found = []
    for entry in entries:
        form, target = entry.get("source", "").split("|")[0], entry.get("target", "")
        if entry.get("decision") != "keep" or len(target) < 4:
            continue
        before = len(re.findall(r"(?<!\w)" + re.escape(form) + r"(?!\w)", source_text, re.I))
        after = len(re.findall(r"(?<!\w)" + re.escape(target) + r"(?!\w)", output_text))
        if before and after > before * SURPLUS_FACTOR and after - before >= SURPLUS_MINIMUM:
            found.append(f"{target}: {before} in the original, {after} in the translation")
    return found


def check_volume(source: Path, output: Path, *, upload: Optional[Path] = None,
                 entries: Sequence[Dict[str, str]] = (), source_language: str = "",
                 target_language: str = "Indonesian") -> List[dict]:
    """Every check of one translated volume. ``upload`` is the original file of a whole book."""
    if output.suffix.lower() != ".epub":
        before, after = (qa.load_documents(p) for p in (source, output))
        words = [sum(len(text.split()) for text, _ in d.values()) for d in (before, after)]
        ratio = words[1] / max(1, words[0])
        return [_result("length", "fail" if words[0] >= qa.MIN_WORDS and ratio < qa.RATIO_LOW else "ok",
                        [f"{ratio:.2f}x"] if ratio < qa.RATIO_LOW else [])]
    results = [_file_check(output)]
    if results[0]["level"] == "fail":
        return results
    made_from, result = _Book(source, cut=True), _Book(output)
    original = (_Book(upload, cut=True)
                if upload and upload.suffix.lower() == ".epub" and upload.exists() else None)
    translate = source_language.strip().lower() != target_language.strip().lower()
    results.append(_pages_check(made_from, result, original))
    results += _text_checks(made_from, result, translate)

    # links that worked before and do not now
    already = (original or made_from).broken_links() | made_from.broken_links()
    broken = sorted(result.broken_links() - already)
    results.append(_result("links", "warn" if broken else "ok", [f"{_name(p)} -> {t}" for p, t in broken]))

    source_text = " ".join(made_from.text(p) for p in made_from.pages())
    output_text = " ".join(result.text(p) for p in result.pages())
    names = qa.find_name_variants(source_text, output_text, entries) if entries else {}
    results.append(_result("names", "info" if names else "ok",
                           [f"{word} (like {name}, {count}x)" for word, (name, count) in names.items()]))
    surplus = _surplus(source_text, output_text, entries)
    results.append(_result("surplus", "warn" if surplus else "ok", surplus))
    missing = audit_metadata(output, target_language=target_language)
    results.append(_result("metadata", "warn" if missing else "ok", missing))
    return results


def write_report(workdir: Path, volumes: Dict[int, List[dict]]) -> dict:
    """``check.json`` of the book, keeping the volumes checked earlier. Returns it."""
    path = workdir / REPORT
    try:
        known = {v["index"]: v for v in json.loads(path.read_text(encoding="utf-8"))["volumes"]}
    except (OSError, ValueError, KeyError, TypeError):
        known = {}
    for index, checks in volumes.items():
        known[index] = {"index": index, "overall": worst([c["level"] for c in checks]), "checks": checks}
    report = {"checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "overall": worst([v["overall"] for v in known.values()]),
              "volumes": [known[i] for i in sorted(known)]}
    workdir.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)
    return report


def summary(report: dict) -> str:
    """One line per volume for the log."""
    lines = []
    for volume in report["volumes"]:
        found = [f"{c['id']} {c['level']} ({c['count']})" for c in volume["checks"] if c["level"] != "ok"]
        lines.append(f"Volume {volume['index']}: {volume['overall']}" + (": " + ", ".join(found) if found else ""))
    return "\n".join(lines)
