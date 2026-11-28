"""
Make a copy of an EPUB that suits an Xteink e-ink reader (X4 480x800, X3 528x792, four grays).

The reader has little memory, so every picture becomes a baseline grayscale JPEG no larger
than its screen, and embedded fonts are left out. The idea and the picture settings follow
EPUB Kit (https://github.com/b1rdmania/epubkit, MIT); this is a smaller, separate
implementation of its two safest steps. **The words of the book are never touched**, and the
original file is never changed.
"""

from __future__ import annotations

import io
import logging
import posixpath
import re
import zipfile
from pathlib import Path
from typing import Dict, List, Set
from urllib.parse import quote, unquote

from lxml import etree
from PIL import Image, ImageOps

logger = logging.getLogger("core.agent.xteink")

SCREENS = {"X4": (480, 800), "X3": (528, 792)}
QUALITY = 75
_RASTER = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff")
_FONTS = (".ttf", ".otf", ".woff", ".woff2")
_TEXT = (".xhtml", ".html", ".htm", ".css", ".opf", ".ncx", ".svg")
_JUNK = (".ds_store", "thumbs.db", "desktop.ini")
_REFERENCE = re.compile(r"""(?P<head>\b(?:src|href|xlink:href|poster)\s*=\s*(?P<q>["']))(?P<url>[^"']*)(?P=q)""")
_CSS_URL = re.compile(r"""(?P<head>url\(\s*(?P<q>["']?))(?P<url>[^"')]+)(?P=q)\s*\)""")
_FONT_FACE = re.compile(r"@font-face\s*\{[^}]*\}", re.I)
_ITEM = re.compile(r"<(?:[\w-]+:)?item\b[^>]*?(?:/>|>\s*</(?:[\w-]+:)?item>)", re.S)


class OptimizeError(Exception):
    """The file cannot be prepared: ``code`` is one word the app words for the user."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code, self.detail = code, detail


def _picture(raw: bytes, screen) -> bytes:
    """A baseline grayscale JPEG that fits the screen; never larger than the source in pixels."""
    with Image.open(io.BytesIO(raw)) as image:
        image.seek(0)
        if image.mode in ("RGBA", "LA", "PA") or "transparency" in image.info:
            image = image.convert("RGBA")
            sheet = Image.new("RGB", image.size, (255, 255, 255))
            sheet.paste(image, mask=image.split()[-1])
            image = sheet
        gray = image.convert("L")
        gray.thumbnail(screen, Image.Resampling.LANCZOS)
        gray = ImageOps.autocontrast(gray, cutoff=1)
        out = io.BytesIO()
        # three equal channels: the form the reader's decoders are known to take
        gray.convert("RGB").save(out, "JPEG", quality=QUALITY, progressive=False, optimize=True, subsampling=2)
        return out.getvalue()


def _encrypted(z: zipfile.ZipFile) -> Set[str]:
    if "META-INF/encryption.xml" not in z.namelist():
        return set()
    root = etree.fromstring(z.read("META-INF/encryption.xml"), etree.XMLParser(resolve_entities=False))
    return {unquote(e.get("URI", "")) for e in root.iter("{*}CipherReference")}


def _new_names(names: List[str], converted: Set[str]) -> Dict[str, str]:
    """``{old path: new path}`` for pictures that are JPEG now and were not called so."""
    taken = {n.lower() for n in names}
    renamed = {}
    for name in names:
        if name not in converted or name.lower().endswith((".jpg", ".jpeg")):
            continue
        stem, ext = posixpath.splitext(name)
        candidate, number = f"{stem}.jpg", 1
        while candidate.lower() in taken:
            candidate = f"{stem}-{ext[1:].lower()}{'' if number == 1 else number}.jpg"
            number += 1
        taken.add(candidate.lower())
        renamed[name] = candidate
    return renamed


def _resolve(document: str, url: str) -> str:
    path = unquote(url.split("#", 1)[0].split("?", 1)[0])
    return posixpath.normpath(posixpath.join(posixpath.dirname(document), path)) if path else ""


def _repoint(text: str, document: str, renamed: Dict[str, str]) -> str:
    def swap(match: re.Match) -> str:
        url = match.group("url")
        if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I):
            return match.group(0)                       # http:, data:, mailto:
        target = renamed.get(_resolve(document, url))
        if target is None:
            return match.group(0)
        path = posixpath.relpath(target, posixpath.dirname(document) or ".")
        mark = url.find("#")
        fresh = quote(path) + (url[mark:] if mark >= 0 else "")
        whole, start = match.group(0), match.start("url") - match.start(0)
        return whole[:start] + fresh + whole[start + len(url):]

    return _CSS_URL.sub(swap, _REFERENCE.sub(swap, text))


def _manifest(text: str, document: str, renamed: Dict[str, str], dropped: Set[str]) -> str:
    """The package file's list: dropped files leave it, converted pictures say they are JPEG."""
    new = set(renamed.values())

    def item(match: re.Match) -> str:
        tag = match.group(0)
        href = re.search(r"""\bhref\s*=\s*(["'])(.*?)\1""", tag)
        if not href:
            return tag
        path = _resolve(document, href.group(2))
        if path in dropped:
            return ""
        if path in renamed or path in new:
            tag = _repoint(tag, document, renamed)
            tag = re.sub(r"""(\bmedia-type\s*=\s*)(["'])[^"']*\2""", r"\1\2image/jpeg\2", tag)
        return tag

    return _ITEM.sub(item, text)


def optimize(source: Path, output: Path, device: str = "X4") -> dict:
    """Write the reader's copy of ``source`` to ``output``. Returns what was done."""
    screen = SCREENS.get(device, SCREENS["X4"])
    done = {"pictures": 0, "fonts": 0, "skipped": 0}
    try:
        with zipfile.ZipFile(source) as z:
            names = [n for n in z.namelist() if not n.endswith("/")]
            junk = {n for n in names if n.startswith("__MACOSX/") or posixpath.basename(n).lower() in _JUNK}
            fonts = {n for n in names if n.lower().endswith(_FONTS)}
            if _encrypted(z) - fonts:
                raise OptimizeError("drm", "the book is encrypted")
            dropped = junk | fonts
            if fonts:
                dropped |= {"META-INF/encryption.xml"} & set(names)     # it only scrambled the fonts
            content: Dict[str, bytes] = {}
            converted: Set[str] = set()
            for name in names:
                if name in dropped:
                    continue
                raw = z.read(name)
                if name.lower().endswith(_RASTER):
                    try:
                        content[name] = _picture(raw, screen)
                        converted.add(name)
                        continue
                    except Exception as exc:  # noqa: BLE001 - a picture that cannot be read stays
                        logger.warning("Picture kept as it is (%s)", type(exc).__name__)
                        done["skipped"] += 1
                content[name] = raw
    except (OSError, zipfile.BadZipFile, etree.XMLSyntaxError) as exc:
        raise OptimizeError("unreadable", type(exc).__name__)

    renamed = _new_names(list(content), converted)
    for name in list(content):
        if not name.lower().endswith(_TEXT):
            continue
        try:
            text = content[name].decode("utf-8")
        except UnicodeDecodeError:
            if renamed or fonts:
                raise OptimizeError("unreadable", f"{posixpath.basename(name)} is not UTF-8")
            continue
        fresh = text
        if name.lower().endswith(".opf"):
            fresh = _manifest(fresh, name, renamed, dropped)
        if fonts and name.lower().endswith((".css", ".xhtml", ".html", ".htm")):
            fresh = _FONT_FACE.sub("", fresh)
        fresh = _repoint(fresh, name, renamed)
        if fresh != text:
            content[name] = fresh.encode("utf-8")

    done["pictures"], done["fonts"] = len(converted), len(fonts)
    output = Path(output)
    with zipfile.ZipFile(output, "w") as out:
        if "mimetype" in content:
            out.writestr(zipfile.ZipInfo("mimetype"), content.pop("mimetype"), compress_type=zipfile.ZIP_STORED)
        for name, raw in content.items():
            out.writestr(renamed.get(name, name), raw, compress_type=zipfile.ZIP_DEFLATED)
    return done
