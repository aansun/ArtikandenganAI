"""
Intake cleaning: keep the boilerplate of an e-book out of the translation.

E-books from public sources carry pages that are not the book: a licence header, a
transcriber's note, a donation appeal. Translating them wastes time and cost and puts
foreign legal text in the result. This module finds those documents and removes them
from the working copy of a volume; the original upload is never touched.

A page is left out only when it holds nothing but such matter. E-books are often cut into a
few large files, so the Project Gutenberg start and end lines usually share a file with whole
chapters: there only what is before the start line or after the end line is cut, and the text
between them stays. When in doubt a page is translated: a page too many costs a little, a
missing chapter spoils the book.
"""

from __future__ import annotations

import logging
import posixpath
import re
import shutil
import zipfile
from collections import Counter
from pathlib import Path
from typing import List, Optional, Tuple
from urllib.parse import unquote

from lxml import etree

from src.core.agent.volumes import _Epub, _write_volume

logger = logging.getLogger("core.agent.intake")

_SHORT_PAGE_WORDS = 400
#: A page that holds fewer words than this between the Gutenberg lines holds no story.
_STORY_WORDS = 60
#: A licence page is shorter than this and names the licence at least this often per 1000 words.
_LICENCE_PAGE_WORDS = 6000
_LICENCE_PER_THOUSAND = 2
_NOTE_PAGE_WORDS = 800

CUT_REASON = "licence lines cut, the text between them kept"
NOTE_REASON = "transcriber's note"

_START_LINE = re.compile(r"\*{3}\s*start of (?:this|the) project gutenberg", re.I)
_END_LINE = re.compile(r"\*{3}\s*end of (?:this|the) project gutenberg", re.I)
_END_PREFACE = re.compile(r"end of (?:the )?project gutenberg", re.I)
_GUTENBERG_LINES = re.compile(r"\*{3}\s*(?:start|end) of (?:this|the) project gutenberg", re.I)
_TRANSCRIBER_NOTE = re.compile(r"transcriber[\u2019']?s?[\u2019']? notes?", re.I)
_SITE_CREDIT = re.compile(r"z-?library|\b1lib\b|libgen|downloaded from", re.I)
_LICENCE = re.compile(r"gutenberg-tm|gutenberg license|gutenberg literary archive|"
                      r"this ebook is for the use of anyone anywhere", re.I)


def _plain(html: bytes) -> str:
    try:
        doc = etree.fromstring(html, etree.HTMLParser())
    except Exception:
        return ""
    for node in doc.xpath("//style|//script"):
        node.getparent().remove(node)
    return " ".join("".join(doc.itertext()).split())


def boilerplate_reason(text: str) -> str:
    """Why a page whose whole text is ``text`` is boilerplate, or '' when it is part of the book.

    A page with the Gutenberg lines may also hold chapters: :func:`judge_page` decides that.
    """
    words = len(text.split())
    if _GUTENBERG_LINES.search(text):
        return "Project Gutenberg start/end line"
    licence = len(_LICENCE.findall(text))
    if (licence >= 3 and words < _LICENCE_PAGE_WORDS
            and licence * 1000 >= _LICENCE_PER_THOUSAND * words):
        return "licence text"
    if _TRANSCRIBER_NOTE.search(text[:150]) and words < _NOTE_PAGE_WORDS:  # a running title may come first
        return NOTE_REASON
    if words < _SHORT_PAGE_WORDS and _SITE_CREDIT.search(text):
        return "download-site page"
    return ""


def _slots(element, found: list) -> None:
    """Every piece of text under ``element`` as ``(node, "text" | "tail")``, in reading order."""
    if isinstance(element.tag, str):            # not a comment or processing instruction
        found.append((element, "text"))
        for child in element:
            _slots(child, found)
            found.append((child, "tail"))


def cut_to_story(raw: bytes) -> Optional[Tuple[bytes, int]]:
    """``(page, words left)`` of a page with what precedes the Gutenberg start line and what
    follows the end line cut away; None when the lines cannot be located for certain."""
    try:
        root = etree.fromstring(raw, etree.XMLParser(recover=True, resolve_entities=False))
    except etree.XMLSyntaxError:
        return None
    if root is None:
        return None
    body = next((e for e in root.iter() if isinstance(e.tag, str)
                 and etree.QName(e).localname == "body"), None)
    if body is None:
        return None
    slots: list = []
    _slots(body, slots)
    text = [getattr(node, kind) or "" for node, kind in slots]
    start = next((i for i, t in enumerate(text) if _START_LINE.search(t)), None)
    end = next((i for i, t in enumerate(text) if _END_LINE.search(t)), None)
    if start is None and end is None:
        return None
    if start is not None and end is not None and end < start:
        return None

    kept = list(text)
    first, last = 0, len(slots) - 1             # the slots that survive
    if end is not None:
        cut, at = end, _END_LINE.search(text[end]).start()
        for i in range(max(start or 0, end - 4), end + 1):    # "End of Project Gutenberg's X" before it
            preface = _END_PREFACE.search(text[i])
            if preface and not text[i][:preface.start()].strip() and (i < end or preface.start() < at):
                cut, at = i, preface.start()
                break
        kept[cut] = kept[cut][:at]
        last = cut
    if start is not None:
        line = _START_LINE.search(text[start])
        closing = text[start].find("***", line.end())
        kept[start] = kept[start][closing + 3 if closing != -1 else len(text[start]):]
        first = start
    for i, (node, kind) in enumerate(slots):
        setattr(node, kind, kept[i] if first <= i <= last else None)

    # drop the elements that lie wholly outside, so no run of empty paragraphs is left
    position: dict = {}
    for i, (node, _kind) in enumerate(slots):
        for owner in [node] + list(node.iterancestors()):
            low, high = position.get(owner, (i, i))
            position[owner] = (min(low, i), max(high, i))
    for node, (low, high) in list(position.items()):
        parent = node.getparent()
        if node is body or parent is None or body not in node.iterancestors():
            continue
        if high < first or low > last:
            parent.remove(node)
    words = len(" ".join("".join(body.itertext()).split()).split())
    return etree.tostring(root.getroottree(), xml_declaration=True, encoding="utf-8"), words


def judge_page(raw: bytes) -> Tuple[str, Optional[bytes]]:
    """``(reason, replacement)`` for one page: ('', None) keeps it as it is, a reason with
    None leaves it out, a reason with bytes keeps those instead."""
    text = _plain(raw)
    reason = boilerplate_reason(text)
    if not _GUTENBERG_LINES.search(text):
        return reason, None
    cut = cut_to_story(raw)
    if cut is None:                     # leave out only a page too small to hold a chapter
        return (reason, None) if len(text.split()) < _SHORT_PAGE_WORDS else ("", None)
    page, words = cut
    return (reason, None) if words < _STORY_WORDS else (CUT_REASON, page)


_FOOTNOTE_LINKS = 3
_LINK = re.compile(rb"""<a\b[^>]*?\bhref\s*=\s*["']([^"'#]+)#""", re.I)


def _linked_pages(z: zipfile.ZipFile, paths: List[str]) -> set:
    """The pages the text points into again and again: footnote marks leading to their notes.

    One stray link is not enough: a single "return" arrow also leads into a note about the e-book.
    """
    found: Counter = Counter()
    for path in paths:
        for href in _LINK.findall(z.read(path)):
            target = posixpath.normpath(posixpath.join(
                posixpath.dirname(path), unquote(href.decode("utf-8", "ignore"))))
            if target != path:
                found[target] += 1
    return {page for page, links in found.items() if links >= _FOOTNOTE_LINKS}


def _judge_epub(epub_path: Path) -> List[Tuple[str, str, Optional[bytes]]]:
    epub = _Epub(epub_path)
    found = []
    with zipfile.ZipFile(epub_path) as z:
        paths = [path for _idref, path in epub.spine]
        # a table of contents points at every page: its links say nothing about footnotes
        toc = set(epub.toc_files.values())
        linked = _linked_pages(z, [p for p in paths if p not in toc])
        for path in paths:
            reason, page = judge_page(z.read(path))
            # notes the text refers to are part of the book, whatever their heading says
            if reason == NOTE_REASON and page is None and path in linked:
                continue
            if reason:
                found.append((path, reason, page))
    return found


def boilerplate_documents(epub_path: Path) -> List[Tuple[str, str]]:
    """``[(document, reason)]`` of the documents of an EPUB to leave out, in reading order."""
    return [(path, reason) for path, reason, page in _judge_epub(epub_path) if page is None]


def clean_epub(source: Path, target: Path) -> List[Tuple[str, str]]:
    """Write ``target`` without the boilerplate; return ``[(file, what was done)]``.

    Nothing is written when there is nothing to remove.
    """
    epub = _Epub(source)
    found = _judge_epub(source)
    dropped = {path for path, _reason, page in found if page is None}
    keep = {path for _idref, path in epub.spine} - dropped
    if not found or not keep:  # nothing to remove, or never empty a book
        return []
    target.parent.mkdir(parents=True, exist_ok=True)
    _write_volume(epub, keep, target, 0, "")
    replaced = {path: page for path, _reason, page in found if page is not None}
    if replaced:
        _replace_entries(target, replaced)
    return [(path, reason) for path, reason, _page in found]


def _replace_entries(archive: Path, entries: dict) -> None:
    scratch = archive.with_name(archive.name + ".cut")
    with zipfile.ZipFile(archive) as zin, zipfile.ZipFile(scratch, "w") as zout:
        for info in zin.infolist():
            zout.writestr(info.filename, entries.get(info.filename, zin.read(info.filename)),
                          compress_type=info.compress_type)
    scratch.replace(archive)


def remove_documents(epub_path: Path, names: set) -> List[str]:
    """Delete the documents ``names`` from ``epub_path`` in place (spine, manifest, TOC, file).

    Used on a finished translation: the pages that are not part of the book are dropped
    from the result, whatever their translation. Returns the documents actually removed.
    """
    epub = _Epub(epub_path)
    present = {path for _idref, path in epub.spine}
    gone = sorted(present & set(names))
    keep = present - set(gone)
    if not gone or not keep:
        return []
    scratch = epub_path.with_suffix(".clean")
    _write_volume(epub, keep, scratch, 0, "")
    scratch.replace(epub_path)
    return gone


_TXT_START = re.compile(r"^\*{3}\s*start of (?:this|the) project gutenberg.*$", re.I | re.M)
_TXT_END = re.compile(r"^\*{3}\s*end of (?:this|the) project gutenberg.*$", re.I | re.M)


def clean_text(source: Path, target: Path) -> List[Tuple[str, str]]:
    """Cut a Project Gutenberg text file down to the book between its marker lines."""
    raw = source.read_bytes()
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return []
    start, end = _TXT_START.search(text), _TXT_END.search(text)
    if not start and not end:
        return []
    body = text[start.end():end.start() if end else len(text)].strip("\r\n")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body + "\n", encoding="utf-8")
    return [(source.name, "Project Gutenberg header and licence")]


def clean_volume(path: Path, volumes_dir: Path) -> Tuple[Path, List[Tuple[str, str]]]:
    """The file to translate for ``path``, and what was removed from it.

    A volume the agent wrote itself (inside ``volumes_dir``) is cleaned in place; any other
    file is left alone and a cleaned copy is written into ``volumes_dir``.
    """
    suffix = path.suffix.lower()
    if suffix not in (".epub", ".txt", ".md"):
        return path, []
    in_place = volumes_dir.resolve() in path.resolve().parents
    target = path if in_place else volumes_dir / path.name
    scratch = target.with_suffix(target.suffix + ".clean")
    try:
        removed = clean_epub(path, scratch) if suffix == ".epub" else clean_text(path, scratch)
    except Exception as exc:  # cleaning is an optimisation: never lose a book over it
        logger.warning("Could not clean %s (%s): translating it as it is", path.name, exc)
        scratch.unlink(missing_ok=True)
        return path, []
    if not removed or not scratch.exists():
        scratch.unlink(missing_ok=True)
        return path, []
    shutil.move(str(scratch), str(target))
    return target, removed
