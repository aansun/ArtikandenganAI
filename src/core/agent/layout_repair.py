"""
Layout defects of a translated EPUB that need no model to find or to mend.

* **Paragraphs cut in the middle of a sentence.** When a model loses the layout markers of a
  passage, the engine puts them back by proportion, and a paragraph can end half way through
  a sentence while the real break sits inside it as a blank line. The text is all there: it
  is cut again at the blank lines.
* **Front matter left in the source language** in the table of contents ("Cover",
  "Copyright"): the engine labels contents entries from translated headings, and these pages
  have none. They are renamed from a fixed list.
* **Signs of a poor source file**, to tell before any work is spent on it.

A repair that would lose or invent a single character is not made.
"""

from __future__ import annotations

import copy
import logging
import re
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

from lxml import etree

from src.core.agent.intake import _replace_entries

logger = logging.getLogger("core.agent.layout")

XHTML = "{http://www.w3.org/1999/xhtml}"
_PAGES = (".xhtml", ".html", ".htm")
#: A paragraph that ends like this has ended: sentence marks, closing quotes and brackets.
_ENDED = re.compile(r"""[.!?…»«"'”’“)\]}:;—–*>\-]\s*$""")
_BLANK_LINE = re.compile(r"\n[ \t\r]*\n\s*")

#: Contents entries every publisher words the same way: English -> Indonesian.
FRONT_MATTER = {
    "cover": "Sampul", "back cover": "Sampul Belakang", "title page": "Halaman Judul",
    "half title": "Halaman Judul Singkat", "copyright": "Hak Cipta", "copyright page": "Halaman Hak Cipta",
    "copyright notice": "Pemberitahuan Hak Cipta", "contents": "Daftar Isi",
    "table of contents": "Daftar Isi", "dedication": "Persembahan", "epigraph": "Epigraf",
    "foreword": "Kata Pengantar", "preface": "Prakata", "introduction": "Pendahuluan",
    "prologue": "Prolog", "epilogue": "Epilog", "afterword": "Kata Penutup",
    "acknowledgments": "Ucapan Terima Kasih", "acknowledgements": "Ucapan Terima Kasih",
    "about the author": "Tentang Penulis", "about the book": "Tentang Buku", "notes": "Catatan",
    "glossary": "Glosarium", "appendix": "Lampiran", "bibliography": "Daftar Pustaka",
    "index": "Indeks", "map": "Peta", "maps": "Peta", "landmarks": "Penanda",
    "start of content": "Awal Isi", "start reading": "Mulai Membaca",
}
INDONESIAN = ("indonesian", "bahasa indonesia", "id")


def _parse(raw: bytes):
    try:
        return etree.fromstring(raw, etree.XMLParser(resolve_entities=False))
    except etree.XMLSyntaxError:
        return None             # a page that is not well formed is left alone


def _local(element) -> str:
    return element.tag.rsplit("}", 1)[-1] if isinstance(element.tag, str) else ""


def _text(element) -> str:
    return "".join(element.itertext())


# --------------------------------------------------------------- paragraphs
def _sibling_paragraphs(root) -> List[list]:
    """Groups of ``<p>`` that follow each other directly inside one parent."""
    groups: List[list] = []
    for parent in root.iter():
        group: list = []
        for child in parent:
            if _local(child) == "p" and (not group or not (group[-1].tail or "").strip()):
                group.append(child)
                continue
            if len(group) > 1:
                groups.append(group)
            group = [child] if _local(child) == "p" else []
        if len(group) > 1:
            groups.append(group)
    return groups


def _open_ended(paragraph) -> bool:
    text = _text(paragraph).rstrip()
    return bool(text) and not _ENDED.search(text)


def _suspect(first, second) -> bool:
    """Does the break between two paragraphs fall inside a sentence?"""
    after = _text(second).lstrip()
    return _open_ended(first) and bool(after) and (after[0].islower() or bool(_BLANK_LINE.search(_text(first).strip())))


def _count_suspects(root) -> int:
    return sum(_suspect(a, b) for group in _sibling_paragraphs(root) for a, b in zip(group, group[1:]))


def _count_open(root) -> int:
    return sum(_open_ended(a) for group in _sibling_paragraphs(root) for a in group[:-1])


def _atoms(element, path: tuple = ()):
    """The content of an element in order: text and empty elements, each with its inline path."""
    if element.text:
        yield element.text, path
    for child in element:
        if len(child) == 0 and not (child.text or "").strip():
            yield child, path               # <br/>, <img/>, an anchor
        else:
            yield from _atoms(child, path + (child,))
        if child.tail:
            yield child.tail, path


def _cut(atoms: list) -> List[list]:
    """The atoms of several paragraphs, cut where their text holds a blank line."""
    whole = "".join(a for a, _p in atoms if isinstance(a, str))
    breaks = [m.span() for m in _BLANK_LINE.finditer(whole)]
    pieces, at, current = [], 0, []
    for atom, path in atoms:
        if not isinstance(atom, str):
            current.append((atom, path))
            continue
        start, end = at, at + len(atom)
        used = start
        for first, last in breaks:
            if last <= used or first >= end:
                continue
            if first > used:
                current.append((atom[used - start:first - start], path))
            if first >= start:              # the break begins in this atom: the paragraph ends
                pieces.append(current)
                current = []
            used = min(last, end)
        if used < end:
            current.append((atom[used - start:], path))
        at = end
    pieces.append(current)
    return pieces


def _fill(paragraph, atoms: list, seen: set) -> None:
    """Rewrite the content of ``paragraph`` from atoms, rebuilding the inline elements."""
    for child in list(paragraph):
        paragraph.remove(child)
    paragraph.text = None
    stack: List[Tuple[object, object]] = []        # (original, new)
    for atom, path in atoms:
        keep = 0
        while keep < len(stack) and keep < len(path) and stack[keep][0] is path[keep]:
            keep += 1
        del stack[keep:]
        for original in path[keep:]:
            parent = stack[-1][1] if stack else paragraph
            made = etree.SubElement(parent, original.tag, nsmap=original.nsmap)
            for name, value in original.attrib.items():
                if not (name == "id" and original in seen):    # an id stays unique
                    made.set(name, value)
            seen.add(original)
            stack.append((original, made))
        target = stack[-1][1] if stack else paragraph
        if isinstance(atom, str):
            if len(target):
                target[-1].tail = (target[-1].tail or "") + atom
            else:
                target.text = (target.text or "") + atom
        else:
            node = copy.deepcopy(atom)
            node.tail = None
            target.append(node)


def _letters(paragraphs: Sequence) -> str:
    return "".join("".join(_text(p) for p in paragraphs).split())


def _mend(root) -> int:
    """Cut broken runs of paragraphs again at their blank lines. Returns paragraphs mended."""
    mended = 0
    for group in _sibling_paragraphs(root):
        i = 0
        while i < len(group) - 1:
            j = i
            while j < len(group) - 1 and _open_ended(group[j]):
                j += 1
            run = group[i:j + 1]
            i = max(j, i + 1)
            if len(run) < 2:
                continue
            atoms = [atom for p in run for atom in _atoms(p)]
            pieces = _cut(atoms)
            # as many paragraphs as before, none empty: anything else is not this defect
            if len(pieces) != len(run) or not all(
                    "".join(a for a, _ in piece if isinstance(a, str)).strip() for piece in pieces):
                continue
            before, originals = _letters(run), [copy.deepcopy(p) for p in run]
            seen: set = set()
            for paragraph, piece in zip(run, pieces):
                _fill(paragraph, piece, seen)
            if _letters(run) != before:             # never at the cost of text
                for paragraph, original in zip(run, originals):
                    paragraph.getparent().replace(paragraph, original)
                continue
            mended += len(run) - 1
    return mended


def _pages(archive: zipfile.ZipFile) -> List[str]:
    return [n for n in archive.namelist() if n.lower().endswith(_PAGES)]


def split_paragraphs(source: Path, output: Path) -> List[str]:
    """Pages with more paragraphs broken inside a sentence than their source has."""
    found = []
    with zipfile.ZipFile(source) as a, zipfile.ZipFile(output) as b:
        names = set(a.namelist())
        for page in _pages(b):
            root = _parse(b.read(page))
            if root is None:
                continue
            here = _count_suspects(root)
            if not here:
                continue
            original = _parse(a.read(page)) if page in names else None
            # a line the source also leaves open is the author's own break (verse, a notice)
            extra = here - (_count_open(original) if original is not None else 0)
            if extra > 0:
                found.append(f"{page.rsplit('/', 1)[-1]}: {extra}")
    return found


def repair_paragraphs(epub: Path) -> int:
    """Mend the broken paragraphs of an EPUB in place. Returns how many breaks moved."""
    changed: Dict[str, bytes] = {}
    total = 0
    with zipfile.ZipFile(epub) as z:
        for page in _pages(z):
            raw = z.read(page)
            root = _parse(raw)
            if root is None or not _BLANK_LINE.search(_text(root)):
                continue
            done = _mend(root)
            if done:
                total += done
                changed[page] = etree.tostring(root.getroottree(), xml_declaration=True, encoding="utf-8")
    if changed:
        _replace_entries(Path(epub), changed)
    return total


# -------------------------------------------------------------- contents list
def _label_elements(root, name: str):
    """The elements that hold the words of a contents entry."""
    if name.lower().endswith(".ncx"):
        for label in root.iter("{*}navLabel"):
            yield from label.iter("{*}text")
        return
    for nav in root.iter(f"{XHTML}nav", "nav"):
        for element in nav.iter():
            if _local(element) in ("a", "span", "h1", "h2", "h3") and not len(element):
                yield element


def _english_front_matter(element) -> Optional[str]:
    words = " ".join((element.text or "").split())
    return words if words.casefold() in FRONT_MATTER else None


def _contents(epub: Path):
    """``(name, root)`` of the files that hold the table of contents."""
    with zipfile.ZipFile(epub) as z:
        for name in z.namelist():
            if name.lower().endswith(".ncx") or (
                    name.lower().endswith(_PAGES) and b"<nav" in z.read(name)):
                root = _parse(z.read(name))
                if root is not None:
                    yield name, root


def untranslated_contents(epub: Path, target_language: str) -> List[str]:
    """Front-matter entries of the contents still worded in English."""
    if target_language.strip().lower() not in INDONESIAN:
        return []
    found = {w for name, root in _contents(epub)
             for w in map(_english_front_matter, _label_elements(root, name)) if w}
    return sorted(found)


def translate_contents(epub: Path, target_language: str) -> List[str]:
    """Rename English front-matter entries of the contents. Returns the words replaced."""
    if target_language.strip().lower() not in INDONESIAN:
        return []
    changed: Dict[str, bytes] = {}
    replaced = set()
    for name, root in _contents(epub):
        here = False
        for element in _label_elements(root, name):
            words = _english_front_matter(element)
            if words:
                element.text = FRONT_MATTER[words.casefold()]
                replaced.add(words)
                here = True
        if here:
            changed[name] = etree.tostring(root.getroottree(), xml_declaration=True, encoding="utf-8")
    if changed:
        _replace_entries(Path(epub), changed)
    return sorted(replaced)


# ------------------------------------------------------------ the source file
def source_warnings(epub: Path) -> List[str]:
    """Signs that a file will translate badly: ``garbled``, ``scanned``, ``broken_paragraphs``."""
    found = []
    try:
        with zipfile.ZipFile(epub) as z:
            garbled = paragraphs = suspects = 0
            scanned = False
            for name in z.namelist():
                if not name.lower().endswith(_PAGES + (".opf", ".ncx")):
                    continue
                raw = z.read(name)
                garbled += raw.decode("utf-8", "ignore").count("�")
                scanned = scanned or b"pdftohtml" in raw[:4000]
                if name.lower().endswith(_PAGES):
                    root = _parse(raw)
                    if root is not None:
                        paragraphs += sum(len(g) for g in _sibling_paragraphs(root))
                        suspects += _count_suspects(root)
    except (OSError, zipfile.BadZipFile):
        return []
    if garbled >= 3:
        found.append("garbled")
    if scanned:
        found.append("scanned")
    if suspects >= 20 and suspects > paragraphs * 0.02:
        found.append("broken_paragraphs")
    return found
