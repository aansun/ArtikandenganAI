"""
Split a multi-volume book into one file per volume.

Supported inputs:

* EPUB: volume boundaries come from the table of contents (entries such as
  "Volume 3", "Vol. IV", "Jilid 2", "第5巻"); when the TOC has none, from the
  first heading of every spine document. Each volume is written as a complete
  EPUB (own spine, own TOC, only the images its pages use).
* TXT / Markdown: volume boundaries are lines such as "Volume 3".
* A directory: every supported file in it is one volume, in natural order.

A book without detectable markers is returned as a single volume, untouched.
Nothing in this module calls an LLM.
"""

from __future__ import annotations

import logging
import posixpath
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import unquote, urldefrag

from lxml import etree

logger = logging.getLogger("core.agent.volumes")

_NUMBER_WORDS = (
    "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|"
    "fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty"
)
_NUMBER = rf"(?:\d{{1,3}}|[ivxlc]{{1,6}}|{_NUMBER_WORDS}|[0-9０-９一二三四五六七八九十百]+)"

#: A TOC label or text line that opens a volume. Anchored and short on purpose:
#: "Volume 3" yes, "The volume of the sound rose" no.
DEFAULT_VOLUME_PATTERN = (
    rf"^\s*(?:(?:vol(?:ume)?|jilid|buku|book|tome|band|tomo|livre)\b\.?\s*{_NUMBER}\b"
    rf"|第\s*{_NUMBER}\s*[巻卷册冊部]"
    rf"|{_NUMBER}\s*[巻卷册冊]\s*$)"
    rf"(?:\s*[:：\-–—.]\s*.{{0,60}})?\s*$"
)
_MAX_LABEL_LEN = 90

SUPPORTED_SUFFIXES = {".epub", ".txt", ".md", ".docx", ".pdf", ".srt"}


@dataclass
class Volume:
    """One volume ready to translate."""
    index: int          # 1-based
    label: str          # "Volume 3", or the file stem for a single-file book
    path: Path          # file to translate


def natural_key(text: str) -> List:
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", text)]


def compile_pattern(pattern: Optional[str]) -> "re.Pattern[str]":
    return re.compile(pattern or DEFAULT_VOLUME_PATTERN, re.IGNORECASE)


#: Download-site debris in file names: "z_library_sk", "1lib_sk", "(1)", "[PDF]".
_FILENAME_JUNK = re.compile(
    r"(?i)(z[-_ ]?lib(?:rary)?[\w.]*|1lib[\w.]*|libgen[\w.]*|\(\d+\)|\[[^\]]*\])")


def clean_stem(text: str) -> str:
    """A file name without download-site debris: 'Book_z_library_sk,_1lib_sk, (1)' -> 'Book'."""
    cleaned = _FILENAME_JUNK.sub(" ", text)
    cleaned = re.sub(r"[\s_,.\-]+", " ", cleaned).strip()
    return cleaned or text


def slugify(text: str, fallback: str = "book") -> str:
    slug = re.sub(r"[^\w\-. ]+", "", clean_stem(text), flags=re.UNICODE).strip().replace(" ", "_")
    return slug[:60] or fallback


def split_into_volumes(source: Path, out_dir: Path, *, pattern: Optional[str] = None,
                       split: bool = True) -> List[Volume]:
    """Return the volumes of ``source``, writing split files into ``out_dir``.

    ``source`` may be a file or a directory of volume files. With ``split``
    False a single file is returned as one volume.
    """
    source = Path(source)
    out_dir = Path(out_dir)
    if source.is_dir():
        files = sorted((p for p in source.iterdir()
                        if p.is_file() and p.suffix.lower() in SUPPORTED_SUFFIXES),
                       key=lambda p: natural_key(p.name))
        return [Volume(i, p.stem, p) for i, p in enumerate(files, 1)]

    single = [Volume(1, clean_stem(source.stem), source)]
    if not split:
        return single

    regex = compile_pattern(pattern)
    suffix = source.suffix.lower()
    if suffix == ".epub":
        volumes = _split_epub(source, out_dir, regex)
    elif suffix in (".txt", ".md"):
        volumes = _split_text(source, out_dir, regex)
    else:
        volumes = []
    if len(volumes) < 2:
        if suffix in (".epub", ".txt", ".md"):
            logger.info("No volume markers found in %s: treating it as one volume", source.name)
        return single
    logger.info("Split %s into %d volumes", source.name, len(volumes))
    return volumes


# --------------------------------------------------------------------- text

def _split_text(source: Path, out_dir: Path, regex: "re.Pattern[str]") -> List[Volume]:
    raw = source.read_bytes()
    for encoding in ("utf-8-sig", "utf-16", "gb18030", "cp1252"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        text = raw.decode("utf-8", "replace")

    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines)
              if 0 < len(line.strip()) <= _MAX_LABEL_LEN and regex.match(line.strip())]
    if len(starts) < 2:
        return []

    out_dir.mkdir(parents=True, exist_ok=True)
    volumes: List[Volume] = []
    bounds = starts + [len(lines)]
    for n, (begin, end) in enumerate(zip(bounds, bounds[1:]), 1):
        label = lines[begin].strip()
        # Anything before the first marker (title page, blurb) joins volume 1.
        body = lines[0:end] if n == 1 else lines[begin:end]
        path = out_dir / f"{n:02d}_{slugify(label, f'volume_{n}')}.txt"
        path.write_text("".join(body), encoding="utf-8")
        volumes.append(Volume(n, label, path))
    return volumes


# --------------------------------------------------------------------- epub

_NS = {
    "c": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
    "xh": "http://www.w3.org/1999/xhtml",
    "epub": "http://www.idpf.org/2007/ops",
}
_NCX_MEDIA_TYPE = "application/x-dtbncx+xml"


def _text(node) -> str:
    return " ".join("".join(node.itertext()).split())


class _Epub:
    """Just enough of an EPUB package to cut it into volumes."""

    def __init__(self, path: Path):
        self.path = path
        with zipfile.ZipFile(path) as z:
            self.names = z.namelist()
            container = etree.fromstring(z.read("META-INF/container.xml"))
            rootfile = container.find(".//c:rootfile", _NS)
            if rootfile is None:
                raise ValueError("EPUB has no rootfile")
            self.opf_path = rootfile.get("full-path")
            self.opf = etree.fromstring(z.read(self.opf_path))
            self.opf_dir = posixpath.dirname(self.opf_path)

            # manifest: id -> (zip path, media type, properties)
            self.manifest: Dict[str, Tuple[str, str, str]] = {}
            for item in self.opf.findall(".//opf:manifest/opf:item", _NS):
                self.manifest[item.get("id")] = (
                    self._resolve(self.opf_dir, item.get("href")),
                    item.get("media-type", ""), item.get("properties", ""),
                )
            self.spine: List[Tuple[str, str]] = []  # (idref, zip path)
            for ref in self.opf.findall(".//opf:spine/opf:itemref", _NS):
                entry = self.manifest.get(ref.get("idref"))
                if entry:
                    self.spine.append((ref.get("idref"), entry[0]))
            self.toc_files = self._toc_files()
            self.toc_entries = self._read_toc(z)

    @staticmethod
    def _resolve(base_dir: str, href: str) -> str:
        return posixpath.normpath(posixpath.join(base_dir, unquote(urldefrag(href)[0])))

    def _toc_files(self) -> Dict[str, str]:
        files = {}
        for _id, (path, media, props) in self.manifest.items():
            if "nav" in props.split():
                files["nav"] = path
            if media == _NCX_MEDIA_TYPE:
                files["ncx"] = path
        return files

    def _read_toc(self, z: zipfile.ZipFile) -> List[Tuple[str, str]]:
        """Flattened TOC as (label, zip path of the target document)."""
        entries: List[Tuple[str, str]] = []
        if "nav" in self.toc_files:
            base = posixpath.dirname(self.toc_files["nav"])
            doc = etree.fromstring(z.read(self.toc_files["nav"]), etree.HTMLParser())
            for a in doc.xpath("//nav[@*[local-name()='type']='toc']//a[@href]") \
                    or doc.xpath("//nav//a[@href]"):
                entries.append((_text(a),
                                self._resolve(base, a.get("href"))))
        elif "ncx" in self.toc_files:
            base = posixpath.dirname(self.toc_files["ncx"])
            ncx = etree.fromstring(z.read(self.toc_files["ncx"]))
            for point in ncx.iter("{%s}navPoint" % _NS["ncx"]):
                text = point.find("ncx:navLabel/ncx:text", _NS)
                content = point.find("ncx:content", _NS)
                if text is not None and content is not None:
                    entries.append((" ".join((text.text or "").split()),
                                    self._resolve(base, content.get("src"))))
        return entries

    def first_heading(self, z: zipfile.ZipFile, zip_path: str) -> str:
        try:
            doc = etree.fromstring(z.read(zip_path), etree.HTMLParser())
        except Exception:
            return ""
        for xpath in ("//h1", "//h2", "//h3", "//title"):
            for node in doc.xpath(xpath):
                text = _text(node)
                if text:
                    return text
        return ""

    @property
    def title(self) -> str:
        node = self.opf.find(".//dc:title", _NS)
        return (node.text or "").strip() if node is not None else self.path.stem


def _find_boundaries(epub: _Epub, regex: "re.Pattern[str]") -> List[Tuple[int, str]]:
    """(spine index, label) of each volume start, in spine order."""
    index_of = {path: i for i, (_id, path) in enumerate(epub.spine)}
    found: Dict[int, str] = {}
    for label, path in epub.toc_entries:
        if path in index_of and len(label) <= _MAX_LABEL_LEN and regex.match(label):
            found.setdefault(index_of[path], label)
    if len(found) >= 2:
        return sorted(found.items())

    # Fallback: the first heading of every spine document.
    found = {}
    with zipfile.ZipFile(epub.path) as z:
        for i, (_id, path) in enumerate(epub.spine):
            heading = epub.first_heading(z, path)
            if heading and len(heading) <= _MAX_LABEL_LEN and regex.match(heading):
                found.setdefault(i, heading)
    return sorted(found.items()) if len(found) >= 2 else []


def _split_epub(source: Path, out_dir: Path, regex: "re.Pattern[str]") -> List[Volume]:
    try:
        epub = _Epub(source)
    except Exception as exc:
        logger.warning("Cannot read %s as an EPUB package (%s): not splitting", source.name, exc)
        return []
    starts = _find_boundaries(epub, regex)
    if len(starts) < 2:
        return []

    out_dir.mkdir(parents=True, exist_ok=True)
    bounds = [i for i, _ in starts] + [len(epub.spine)]
    volumes: List[Volume] = []
    for n, ((begin, label), end) in enumerate(zip(starts, bounds[1:]), 1):
        first = 0 if n == 1 else begin  # front matter joins volume 1
        keep = {path for _id, path in epub.spine[first:end]}
        target = out_dir / f"{n:02d}_{slugify(label, f'volume_{n}')}.epub"
        _write_volume(epub, keep, target, n, label)
        volumes.append(Volume(n, label, target))
    return volumes


def _write_volume(epub: _Epub, keep_docs: set, target: Path, number: int, label: str) -> None:
    spine_paths = {path for _id, path in epub.spine}
    drop_docs = spine_paths - keep_docs

    with zipfile.ZipFile(epub.path) as zin:
        referenced = _referenced_resources(zin, epub, keep_docs)
        cover_ids = _cover_image_ids(epub)
        drop_files = set(drop_docs)
        for item_id, (path, media, _props) in epub.manifest.items():
            if media.startswith("image/") and path not in referenced and item_id not in cover_ids:
                drop_files.add(path)

        opf = etree.fromstring(etree.tostring(epub.opf))
        _rewrite_opf(opf, epub, drop_files, number, label)
        rewritten = {epub.opf_path: etree.tostring(opf, xml_declaration=True, encoding="utf-8")}
        for kind, path in epub.toc_files.items():
            rewritten[path] = _filter_toc(zin.read(path), kind, drop_files, path)

        with zipfile.ZipFile(target, "w") as zout:
            if "mimetype" in zin.namelist():
                zout.writestr("mimetype", zin.read("mimetype"), compress_type=zipfile.ZIP_STORED)
            for info in zin.infolist():
                if info.filename == "mimetype" or info.filename in drop_files \
                        or info.filename.endswith("/"):
                    continue
                data = rewritten.get(info.filename, zin.read(info.filename))
                zout.writestr(info.filename, data, compress_type=zipfile.ZIP_DEFLATED)


def _cover_image_ids(epub: _Epub) -> set:
    ids = {i for i, (_p, _m, props) in epub.manifest.items() if "cover-image" in props.split()}
    meta = epub.opf.find(".//opf:meta[@name='cover']", _NS)
    if meta is not None and meta.get("content"):
        ids.add(meta.get("content"))
    return ids


_CSS_URL = re.compile(rb"url\(\s*['\"]?([^)'\"]+)")


def _referenced_resources(z: zipfile.ZipFile, epub: _Epub, keep_docs: set) -> set:
    """Zip paths of resources the kept documents (and every stylesheet) point at."""
    refs = set()
    for doc_path in keep_docs:
        try:
            doc = etree.fromstring(z.read(doc_path), etree.HTMLParser())
        except Exception:
            continue
        base = posixpath.dirname(doc_path)
        for node in doc.xpath("//*[@src or @href or @*[local-name()='href']]"):
            for attr in ("src", "href", "{http://www.w3.org/1999/xlink}href"):
                value = node.get(attr)
                if value and not value.startswith(("http:", "https:", "data:", "#")):
                    refs.add(posixpath.normpath(posixpath.join(base, unquote(urldefrag(value)[0]))))
    for path, media, _props in epub.manifest.values():
        if media == "text/css":
            try:
                css = z.read(path)
            except KeyError:
                continue
            base = posixpath.dirname(path)
            for match in _CSS_URL.findall(css):
                refs.add(posixpath.normpath(posixpath.join(base, unquote(match.decode("utf-8", "ignore")))))
    return refs


def _rewrite_opf(opf, epub: _Epub, drop_files: set, number: int, label: str) -> None:
    removed_ids = set()
    manifest = opf.find(".//opf:manifest", _NS)
    for item in list(manifest):
        path = _Epub._resolve(epub.opf_dir, item.get("href", ""))
        if path in drop_files:
            removed_ids.add(item.get("id"))
            manifest.remove(item)
    spine = opf.find(".//opf:spine", _NS)
    for ref in list(spine):
        if ref.get("idref") in removed_ids:
            spine.remove(ref)
    guide = opf.find(".//opf:guide", _NS)
    if guide is not None:
        for ref in list(guide):
            path = _Epub._resolve(epub.opf_dir, ref.get("href", ""))
            if path in drop_files:
                guide.remove(ref)

    if not number:  # a cleaned copy of the whole book keeps its title and identifier
        return
    title = opf.find(".//dc:title", _NS)
    if title is not None:
        base = (title.text or "").strip()
        title.text = f"{base} - {label}" if base and label not in base else (base or label)
    ident = opf.find(".//dc:identifier", _NS)
    if ident is not None and ident.text:
        ident.text = f"{ident.text.strip()}-v{number:02d}"


def _filter_toc(data: bytes, kind: str, drop_files: set, toc_path: str) -> bytes:
    """Remove TOC entries that point at documents left out of this volume."""
    base = posixpath.dirname(toc_path)

    def gone(href: Optional[str]) -> bool:
        return bool(href) and _Epub._resolve(base, href) in drop_files

    if kind == "ncx":
        root = etree.fromstring(data)
        for point in reversed(list(root.iter("{%s}navPoint" % _NS["ncx"]))):
            content = point.find("ncx:content", _NS)
            if content is not None and gone(content.get("src")):
                parent = point.getparent()
                at = parent.index(point)
                for child in list(point):  # keep nested entries that survive
                    if child.tag == "{%s}navPoint" % _NS["ncx"]:
                        parent.insert(at, child)
                        at += 1
                parent.remove(point)
        for n, point in enumerate(root.iter("{%s}navPoint" % _NS["ncx"]), 1):
            point.set("playOrder", str(n))
        return etree.tostring(root, xml_declaration=True, encoding="utf-8")

    root = etree.fromstring(data)  # nav documents are XHTML, hence well-formed XML
    xh = "{%s}" % _NS["xh"]
    for li in reversed(list(root.iter(xh + "li"))):
        anchor = li.find(xh + "a")
        if anchor is not None and gone(anchor.get("href")):
            parent = li.getparent()
            at = parent.index(li)
            for sub_list in li.findall(xh + "ol"):
                for child in list(sub_list):
                    parent.insert(at, child)
                    at += 1
            parent.remove(li)
    for ol in reversed(list(root.iter(xh + "ol"))):
        if len(ol) == 0 and ol.getparent() is not None and ol.getparent().tag == xh + "nav":
            ol.getparent().remove(ol)
    return etree.tostring(root, xml_declaration=True, encoding="utf-8")


__all__ = [
    "DEFAULT_VOLUME_PATTERN", "Volume", "split_into_volumes", "natural_key",
    "compile_pattern", "slugify", "clean_stem",
]
