"""
Books of one series share their names and their style.

Volumes are often added one at a time and in any order. Whatever was added first, a later
one starts from the glossary and the style of the books of the same series that are already
in the library, in the same target language. Nothing is kept apart from the books
themselves: what a book knows stays in its folder, and goes away with it.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from lxml import etree

logger = logging.getLogger("core.agent.series")

_MARK = r"(?:vol(?:ume)?\.?|book|jilid|bk\.?)"
_NUMBER = r"(?P<number>\d{1,3}|[IVXL]{1,6})\b"
_PATTERNS = (
    # "Title (Detective Galileo Series - Vol. 1)", "Title [Saga, Book 2]"
    re.compile(rf"[(\[]\s*(?P<name>[^()\[\]]+?)\s*[—–\-,:]?\s*(?:{_MARK}\s*|#\s*){_NUMBER}\s*[)\]]", re.I),
    # "Saga - Volume 2", "Saga, Vol. 2", "Saga Jilid 2"
    re.compile(rf"^(?P<name>.+?)\s*[—–\-,:]?\s+{_MARK}\s*{_NUMBER}", re.I),
)
_NS = {"opf": "http://www.idpf.org/2007/opf", "dc": "http://purl.org/dc/elements/1.1/"}


@dataclass(frozen=True)
class Series:
    name: str               # as written
    number: str = ""
    author: str = ""

    def same_as(self, other: "Series") -> bool:
        if _plain_name(self.name) != _plain_name(other.name) or not _plain_name(self.name):
            return False
        mine, theirs = _words(self.author), _words(other.author)
        return not mine or not theirs or mine == theirs      # "Higashino, Keigo" = "Keigo Higashino"


def _words(text: str) -> frozenset:
    return frozenset(re.findall(r"\w+", text.casefold()))


def _plain_name(name: str) -> str:
    return " ".join(w for w in re.findall(r"\w+", name.casefold()) if w not in ("the", "a", "series", "seri"))


def from_title(text: str) -> Optional[tuple]:
    """``(series name, number)`` when a title or file name states them."""
    for pattern in _PATTERNS:
        found = pattern.search(text or "")
        if found and _plain_name(found.group("name")):
            return found.group("name").strip(" -—–,:"), found.group("number")
    return None


def _opf(epub: Path):
    with zipfile.ZipFile(epub) as z:
        container = etree.fromstring(z.read("META-INF/container.xml"))
        path = container.find(".//{*}rootfile").get("full-path")
        return etree.fromstring(z.read(path))


def series_of(book: Path) -> Optional[Series]:
    """The series ``book`` belongs to: from its metadata, else from its title or file name."""
    title = author = name = number = ""
    if book.suffix.lower() == ".epub":
        try:
            opf = _opf(book)
            title = (opf.findtext(".//dc:title", namespaces=_NS) or "").strip()
            author = (opf.findtext(".//dc:creator", namespaces=_NS) or "").strip()
            for meta in opf.iterfind(".//opf:meta", _NS):
                if meta.get("name") == "calibre:series":
                    name = (meta.get("content") or "").strip()
                elif meta.get("name") == "calibre:series_index":
                    number = (meta.get("content") or "").strip()
                elif meta.get("property") == "belongs-to-collection" and not name:
                    name = (meta.text or "").strip()
        except Exception as exc:  # a book without readable metadata is judged by its name
            logger.debug("No metadata in %s: %s", book.name, exc)
    if not name:
        stated = from_title(book.stem) or from_title(title)
        if not stated:
            return None
        name, number = stated
    return Series(name=name, number=number, author=author)


def _book_series(folder: Path) -> Optional[Series]:
    sources = sorted((folder / "source").glob("*")) if (folder / "source").is_dir() else []
    return series_of(sources[0]) if sources else None


def related_books(root: Path, workdir: Path, series: Series, target_language: str) -> List[Path]:
    """The other library folders of this series in this language, the oldest first."""
    found = []
    for folder in sorted(root.iterdir()) if root.is_dir() else []:
        if folder == workdir or not (folder / "book.json").is_file():
            continue
        try:
            info = json.loads((folder / "book.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if str(info.get("target_language", "")).casefold() != target_language.casefold():
            continue
        other = _book_series(folder)
        if other and series.same_as(other):
            found.append(folder)
    return sorted(found, key=_age)


def _age(folder: Path) -> float:
    for name in ("glossary.json", "style.md", "book.json"):
        if (folder / name).is_file():
            return (folder / name).stat().st_mtime
    return 0.0


def inherited_terms(books: List[Path]) -> List[dict]:
    """The glossary entries of those books; the earliest book's rendering wins."""
    merged: dict = {}
    for folder in books:
        try:
            data = json.loads((folder / "glossary.json").read_text(encoding="utf-8"))
            terms = data.get("terms", [])
        except (OSError, ValueError, AttributeError):
            continue
        for term in terms:
            source = str(term.get("source") or "").strip() if isinstance(term, dict) else ""
            if source:
                merged.setdefault(source.casefold(), term)
    return list(merged.values())


def inherit_style(books: List[Path], workdir: Path, wanted: str = "auto") -> Optional[Path]:
    """Copy the newest style of the series into ``workdir`` when it has none yet.

    ``wanted`` is the style asked for; another style is written afresh. Returns the book it
    came from.
    """
    if (workdir / "style.md").exists() or (workdir / "style.json").exists():
        return None
    for folder in reversed(books):
        try:
            choice = json.loads((folder / "style.json").read_text(encoding="utf-8"))
            chosen = choice["chosen"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not (folder / "style.md").is_file() or wanted not in ("auto", chosen):
            continue
        workdir.mkdir(parents=True, exist_ok=True)
        shutil.copy(folder / "style.md", workdir / "style.md")
        choice.update(recommended=chosen, why=f"{folder.name.replace('_', ' ')}")
        (workdir / "style.json").write_text(json.dumps(choice, ensure_ascii=False, indent=2),
                                            encoding="utf-8")
        return folder
    return None
