"""
Finish the package metadata of a translated EPUB.

The engine already sets the language, localises title and description and adds
the translator contributor. What a multi-volume book still lacks, and this
module adds: the series name and volume number (both the EPUB 3 collection form
and the Calibre form every reader understands), the original title as
``dc:source``, a fresh ``dcterms:modified``, and an identifier if one is missing.

``audit_metadata`` then reports what is still absent, so an incomplete result is
visible instead of silent.
"""

from __future__ import annotations

import posixpath
import re
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

from lxml import etree

from src.config import GENERATOR_NAME
from src.core.epub.lang_support import get_language_code
from src.core.epub.attribution_page import ATTRIBUTION_ID

OPF = "http://www.idpf.org/2007/opf"
DC = "http://purl.org/dc/elements/1.1/"
CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container"
_NS = {"opf": OPF, "dc": DC, "c": CONTAINER}


_VOLUME_SUFFIX = re.compile(
    r"[\s\-–—:,.]*(?:jilid|volume|vol\.?|buku|bagian|book|tome|band)\s*[0-9IVXLC]+\s*$",
    re.IGNORECASE)

#: Subject written when a book has none, by genre (Indonesian editions only).
GENRE_SUBJECTS_ID = {
    "fiction_novel": "Fiksi", "light_novel": "Novel ringan", "literary_fiction": "Sastra",
    "nonfiction_general": "Nonfiksi", "business": "Bisnis", "technical": "Teknis",
    "academic": "Akademik", "legal": "Hukum", "children": "Anak-anak",
}


def strip_volume_suffix(title: str) -> str:
    """'Saga Palsu - Jilid 2' -> 'Saga Palsu': the series name behind a volume title."""
    return _VOLUME_SUFFIX.sub("", title or "").strip() or (title or "").strip()


def _open_opf(z: zipfile.ZipFile):
    container = etree.fromstring(z.read("META-INF/container.xml"))
    path = container.find(".//c:rootfile", _NS).get("full-path")
    return path, etree.fromstring(z.read(path))


def _meta(parent, **attrs) -> etree._Element:
    el = etree.SubElement(parent, f"{{{OPF}}}meta")
    for key, value in attrs.items():
        el.set(key.replace("_", "-"), value)
    return el


def _drop(metadata, xpath: str) -> None:
    for el in metadata.xpath(xpath, namespaces=_NS):
        metadata.remove(el)


def finalize_metadata(epub_path: Path, *, series: str = "", volume: int = 0, volume_count: int = 1,
                      original_title: str = "", source_language: str = "",
                      target_language: str = "Indonesian", subject: str = "",
                      title: str = "", strip_attribution: bool = False) -> None:
    """Rewrite the OPF of ``epub_path`` in place with the missing metadata.

    ``title`` replaces the book title everywhere it is stored (OPF and NCX), to keep
    the original title. ``strip_attribution`` removes the engine's translator
    signature: the description footer, the contributor and the colophon page.
    """
    epub_path = Path(epub_path)
    with zipfile.ZipFile(epub_path) as z:
        opf_path, root = _open_opf(z)
        metadata = root.find("opf:metadata", _NS)
        if metadata is None:
            return
        is_v3 = not root.get("version", "").startswith("2")
        extra: dict = {}      # path -> new bytes
        drop: set = set()     # paths removed from the archive
        opf_dir = posixpath.dirname(opf_path)

        if title:
            title_el = metadata.find("dc:title", _NS)
            if title_el is not None:
                title_el.text = title
            for item in root.findall("opf:manifest/opf:item", _NS):
                if item.get("media-type") == "application/x-dtbncx+xml":
                    ncx_path = posixpath.normpath(posixpath.join(opf_dir, item.get("href", "")))
                    ncx = etree.fromstring(z.read(ncx_path))
                    for text_el in ncx.xpath("//*[local-name()='docTitle']/*[local-name()='text']"):
                        text_el.text = title
                    extra[ncx_path] = etree.tostring(ncx, xml_declaration=True, encoding="utf-8")

        if strip_attribution:
            drop |= _strip_attribution(root, metadata, opf_dir)

        code = get_language_code(target_language)
        lang = metadata.find("dc:language", _NS)
        if code and lang is not None:
            lang.text = code

        if metadata.find("dc:identifier", _NS) is None:
            ident = etree.SubElement(metadata, f"{{{DC}}}identifier")
            ident.text = f"urn:uuid:{uuid.uuid4()}"

        if original_title and metadata.find("dc:source", _NS) is None:
            source = etree.SubElement(metadata, f"{{{DC}}}source")
            source.text = f"{original_title} ({source_language})" if source_language else original_title

        if subject and metadata.find("dc:subject", _NS) is None:
            etree.SubElement(metadata, f"{{{DC}}}subject").text = subject
        if metadata.find("dc:date", _NS) is None:
            etree.SubElement(metadata, f"{{{DC}}}date").text = datetime.now(
                timezone.utc).strftime("%Y-%m-%d")

        if series and volume_count > 1 and volume:
            _drop(metadata, "opf:meta[@name='calibre:series' or @name='calibre:series_index']")
            _meta(metadata, name="calibre:series", content=series)
            _meta(metadata, name="calibre:series_index", content=str(volume))
            if is_v3:
                _drop(metadata, "opf:meta[@id='tbl-series']"
                                "|opf:meta[@refines='#tbl-series']")
                _meta(metadata, property="belongs-to-collection", id="tbl-series").text = series
                _meta(metadata, refines="#tbl-series", property="collection-type").text = "series"
                _meta(metadata, refines="#tbl-series", property="group-position").text = str(volume)

        if is_v3:
            _drop(metadata, "opf:meta[@property='dcterms:modified']")
            _meta(metadata, property="dcterms:modified").text = datetime.now(
                timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        data = etree.tostring(root, xml_declaration=True, encoding="utf-8")
        tmp = epub_path.with_suffix(".tmp")
        with zipfile.ZipFile(tmp, "w") as out:
            if "mimetype" in z.namelist():
                out.writestr("mimetype", z.read("mimetype"), compress_type=zipfile.ZIP_STORED)
            for info in z.infolist():
                if info.filename == "mimetype" or info.filename.endswith("/"):
                    continue
                if info.filename in drop:
                    continue
                content = data if info.filename == opf_path else extra.get(
                    info.filename, z.read(info.filename))
                out.writestr(info.filename, content, compress_type=zipfile.ZIP_DEFLATED)
    tmp.replace(epub_path)


_EDITABLE = {"title": "dc:title", "creator": "dc:creator", "description": "dc:description",
             "publisher": "dc:publisher", "date": "dc:date", "subject": "dc:subject",
             "language": "dc:language"}


def edit_field(epub_path: Path, field: str, value: str, *, volume: int = 0, volume_count: int = 1) -> None:
    """Set one metadata field of a finished EPUB (the Mac app's "Change" button).

    ``field`` is title, creator, description, publisher, date, subject, language or series;
    an empty ``value`` removes the field; several subjects or authors are separated by "|".
    ``isbn`` adds an identifier and ``cover`` takes the path of an image. A title is written
    to the NCX as well.
    """
    if field == "series":
        finalize_metadata(epub_path, series=value, volume=volume or 1, volume_count=max(volume_count, 2))
        return
    if field == "cover":
        _set_cover(Path(epub_path), Path(value))
        return
    if field == "isbn":
        _add_isbn(Path(epub_path), value)
        return
    if field not in _EDITABLE:
        raise ValueError(f"unknown metadata field: {field}")
    if field == "title" and value:
        finalize_metadata(epub_path, title=value)
        return
    epub_path = Path(epub_path)
    with zipfile.ZipFile(epub_path) as z:
        opf_path, root = _open_opf(z)
        metadata = root.find("opf:metadata", _NS)
        if metadata is None:
            return
        _drop(metadata, f"{_EDITABLE[field]}")
        # Several subjects (or authors) are given separated by "|".
        for part in ([v.strip() for v in value.split("|") if v.strip()] if value else []):
            prefix, name = _EDITABLE[field].split(":")
            etree.SubElement(metadata, f"{{{DC}}}{name}").text = part
        data = etree.tostring(root, xml_declaration=True, encoding="utf-8")
        tmp = epub_path.with_suffix(".tmp")
        with zipfile.ZipFile(tmp, "w") as out:
            if "mimetype" in z.namelist():
                out.writestr("mimetype", z.read("mimetype"), compress_type=zipfile.ZIP_STORED)
            for info in z.infolist():
                if info.filename == "mimetype" or info.filename.endswith("/"):
                    continue
                out.writestr(info.filename, data if info.filename == opf_path else z.read(info.filename),
                             compress_type=zipfile.ZIP_DEFLATED)
    tmp.replace(epub_path)


def _rewrite(epub_path: Path, opf_bytes: bytes, opf_path: str, extra: dict) -> None:
    """Write ``epub_path`` again with a new OPF and extra files (path -> bytes)."""
    tmp = epub_path.with_suffix(".tmp")
    with zipfile.ZipFile(epub_path) as z, zipfile.ZipFile(tmp, "w") as out:
        if "mimetype" in z.namelist():
            out.writestr("mimetype", z.read("mimetype"), compress_type=zipfile.ZIP_STORED)
        for info in z.infolist():
            if info.filename == "mimetype" or info.filename.endswith("/") or info.filename in extra:
                continue
            out.writestr(info.filename, opf_bytes if info.filename == opf_path else z.read(info.filename),
                         compress_type=zipfile.ZIP_DEFLATED)
        for name, data in extra.items():
            out.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    tmp.replace(epub_path)


def _add_isbn(epub_path: Path, isbn: str) -> None:
    """Add the ISBN as one more identifier (the book's own unique identifier is kept)."""
    digits = "".join(ch for ch in isbn if ch.isdigit() or ch in "xX")
    if not digits:
        return
    with zipfile.ZipFile(epub_path) as z:
        opf_path, root = _open_opf(z)
        metadata = root.find("opf:metadata", _NS)
        if metadata is None:
            return
        for el in metadata.findall("dc:identifier", _NS):
            if "".join(ch for ch in (el.text or "") if ch.isdigit() or ch in "xX") == digits:
                return
        ident = etree.SubElement(metadata, f"{{{DC}}}identifier")
        ident.text = f"urn:isbn:{digits}"
        data = etree.tostring(root, xml_declaration=True, encoding="utf-8")
    _rewrite(epub_path, data, opf_path, {})


_COVER_TYPES = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif"}


def _set_cover(epub_path: Path, image: Path) -> None:
    """Make ``image`` the cover: a manifest item flagged cover-image, plus the EPUB 2 meta."""
    media = _COVER_TYPES.get(image.suffix.lower())
    if not media:
        raise ValueError("a cover must be a .jpg, .png or .gif file")
    with zipfile.ZipFile(epub_path) as z:
        opf_path, root = _open_opf(z)
        metadata = root.find("opf:metadata", _NS)
        manifest = root.find("opf:manifest", _NS)
        if metadata is None or manifest is None:
            return
        opf_dir = posixpath.dirname(opf_path)
        name = f"cover-online{image.suffix.lower()}"
        href = posixpath.join(opf_dir, name) if opf_dir else name
        old_ids = set()
        for item in list(manifest):
            if "cover-image" in (item.get("properties") or ""):
                props = [p for p in item.get("properties").split() if p != "cover-image"]
                if props:
                    item.set("properties", " ".join(props))
                else:
                    del item.attrib["properties"]
                old_ids.add(item.get("id"))
        _drop(metadata, "opf:meta[@name='cover']")
        if manifest.find("opf:item[@id='cover-online']", _NS) is not None:
            manifest.remove(manifest.find("opf:item[@id='cover-online']", _NS))
        item = etree.SubElement(manifest, f"{{{OPF}}}item")
        item.set("id", "cover-online")
        item.set("href", name)
        item.set("media-type", media)
        item.set("properties", "cover-image")
        _meta(metadata, name="cover", content="cover-online")
        data = etree.tostring(root, xml_declaration=True, encoding="utf-8")
    _rewrite(epub_path, data, opf_path, {href: image.read_bytes()})


def _strip_attribution(root, metadata, opf_dir: str) -> set:
    """Remove the engine's translator signature from the OPF; return files to drop."""
    sig = re.compile(r"\s*Translated using " + re.escape(GENERATOR_NAME) + r".*$", re.DOTALL)
    desc = metadata.find("dc:description", _NS)
    if desc is not None and desc.text:
        desc.text = sig.sub("", desc.text).strip()
    for contributor in metadata.findall("dc:contributor", _NS):
        if contributor.get("id") == "tbl-translator" or (contributor.text or "").strip() == GENERATOR_NAME:
            ident = contributor.get("id")
            metadata.remove(contributor)
            if ident:
                _drop(metadata, f"opf:meta[@refines='#{ident}']")
    dropped = set()
    for item in root.findall("opf:manifest/opf:item", _NS):
        if item.get("id") == ATTRIBUTION_ID:
            dropped.add(posixpath.normpath(posixpath.join(opf_dir, item.get("href", ""))))
            item.getparent().remove(item)
    for ref in root.findall("opf:spine/opf:itemref", _NS):
        if ref.get("idref") == ATTRIBUTION_ID:
            ref.getparent().remove(ref)
    return dropped


def read_metadata(epub_path: Path) -> dict:
    """Title, authors, language, ... of an EPUB as a plain dict (empty on failure)."""
    try:
        with zipfile.ZipFile(epub_path) as z:
            opf_path, root = _open_opf(z)
            names = set(z.namelist())
    except Exception:
        return {}
    metadata = root.find("opf:metadata", _NS)
    if metadata is None:
        return {}

    def text(tag: str) -> str:
        el = metadata.find(f"dc:{tag}", _NS)
        return (el.text or "").strip() if el is not None else ""

    base = posixpath.dirname(opf_path)
    manifest = root.find("opf:manifest", _NS)
    cover = ""
    if manifest is not None:
        cover_ids = {i.get("id") for i in manifest if "cover-image" in (i.get("properties") or "").split()}
        meta_cover = metadata.find("opf:meta[@name='cover']", _NS)
        if meta_cover is not None:
            cover_ids.add(meta_cover.get("content"))
        for item in manifest:
            if item.get("id") in cover_ids:
                candidate = posixpath.normpath(posixpath.join(base, item.get("href", "")))
                if candidate in names:
                    cover = candidate
    series = metadata.find("opf:meta[@name='calibre:series']", _NS)
    index = metadata.find("opf:meta[@name='calibre:series_index']", _NS)
    return {
        "title": text("title"),
        "creators": [(c.text or "").strip() for c in metadata.findall("dc:creator", _NS)],
        "language": text("language"),
        "identifier": text("identifier"),
        "description": text("description"),
        "publisher": text("publisher"),
        "date": text("date"),
        "source": text("source"),
        "subjects": [(s.text or "").strip() for s in metadata.findall("dc:subject", _NS)],
        "series": series.get("content") if series is not None else "",
        "series_index": index.get("content") if index is not None else "",
        "cover": cover,
    }


def audit_metadata(epub_path: Path, *, expect_series: bool = False,
                   target_language: str = "Indonesian") -> List[str]:
    """Names of the metadata fields a finished EPUB still lacks."""
    info = read_metadata(epub_path)
    if not info:
        return ["unreadable package"]
    missing = []
    if not info["title"]:
        missing.append("title")
    if not [c for c in info["creators"] if c]:
        missing.append("creator")
    code: Optional[str] = get_language_code(target_language)
    if not info["language"] or (code and not info["language"].lower().startswith(code.lower())):
        missing.append("language")
    for field in ("identifier", "description", "cover"):
        if not info[field]:
            missing.append(field)
    if expect_series and not (info["series"] and info["series_index"]):
        missing.append("series")
    return missing
