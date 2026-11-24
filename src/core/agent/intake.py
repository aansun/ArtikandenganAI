"""
Intake cleaning: keep the boilerplate of an e-book out of the translation.

E-books from public sources carry pages that are not the book: a licence header, a
transcriber's note, a donation appeal. Translating them wastes time and cost and puts
foreign legal text in the result. This module finds those documents and removes them
from the working copy of a volume; the original upload is never touched.

A document is boilerplate when it carries a strong marker of such a page. The markers
are specific (a licence text, the Project Gutenberg start and end lines, a download-site
credit), so a story chapter is not caught.
"""

from __future__ import annotations

import logging
import re
import shutil
import zipfile
from pathlib import Path
from typing import List, Tuple

from lxml import etree

from src.core.agent.volumes import _Epub, _write_volume

logger = logging.getLogger("core.agent.intake")

_SHORT_PAGE_WORDS = 400

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
    """Why ``text`` is boilerplate, or '' when it is part of the book."""
    words = len(text.split())
    if _GUTENBERG_LINES.search(text):
        return "Project Gutenberg start/end line"
    if len(_LICENCE.findall(text)) >= 3:
        return "licence text"
    if _TRANSCRIBER_NOTE.search(text[:150]):  # a running title may come first
        return "transcriber's note"
    if words < _SHORT_PAGE_WORDS and _SITE_CREDIT.search(text):
        return "download-site page"
    return ""


def boilerplate_documents(epub_path: Path) -> List[Tuple[str, str]]:
    """``[(document, reason)]`` of the boilerplate documents of an EPUB, in reading order."""
    epub = _Epub(epub_path)
    found = []
    with zipfile.ZipFile(epub_path) as z:
        for _idref, path in epub.spine:
            reason = boilerplate_reason(_plain(z.read(path)))
            if reason:
                found.append((path, reason))
    return found


def clean_epub(source: Path, target: Path) -> List[Tuple[str, str]]:
    """Write ``target`` without the boilerplate documents; return ``[(file, reason)]``.

    Nothing is written when no document is boilerplate.
    """
    epub = _Epub(source)
    removed = boilerplate_documents(source)
    keep = {path for _idref, path in epub.spine} - {name for name, _ in removed}
    if not removed or not keep:  # nothing to remove, or never empty a book
        return []
    target.parent.mkdir(parents=True, exist_ok=True)
    _write_volume(epub, keep, target, 0, "")
    return removed


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
