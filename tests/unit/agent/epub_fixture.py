"""Build a small multi-volume EPUB 3 (with NCX) for the agent tests."""
import zipfile
from pathlib import Path

XHTML = ('<?xml version="1.0" encoding="utf-8"?>'
         '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
         '<head><title>{title}</title></head><body><h1>{title}</h1>{body}</body></html>')


def build_omnibus(path: Path, volumes: int = 3, chapters: int = 2, attribution: bool = False,
                  boilerplate: bool = False) -> Path:
    docs = [("cover", "Cover", '<p>Cover</p>')]
    if boilerplate:
        docs.insert(0, ("gbhead", "Header", "<p>The Project Gutenberg EBook of Saga. *** START OF THIS "
                                            "PROJECT GUTENBERG EBOOK SAGA *** Produced by Someone</p>"))
    for v in range(1, volumes + 1):
        docs.append((f"v{v}", f"Volume {v}", f'<p>Hello, said Aldric in volume {v}.</p>'
                                              f'<img src="img/v{v}.png" alt=""/>'))
        for c in range(1, chapters + 1):
            docs.append((f"v{v}c{c}", f"Chapter {c}",
                         f'<p>"Hello," said Aldric. It was chapter {c} of volume {v}.</p>'))
    if boilerplate:
        docs.append(("gblicense", "License", "<p>Project Gutenberg-tm works. Project Gutenberg-tm "
                                             "terms. Project Gutenberg-tm donations.</p>"))
    manifest = "".join(
        f'<item id="{i}" href="{i}.xhtml" media-type="application/xhtml+xml"/>' for i, _, _ in docs)
    manifest += "".join(
        f'<item id="img{v}" href="img/v{v}.png" media-type="image/png"/>'
        for v in range(1, volumes + 1))
    manifest += '<item id="coverimg" href="img/cover.png" media-type="image/png" properties="cover-image"/>'
    manifest += ('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
                 'properties="nav"/><item id="ncx" href="toc.ncx" '
                 'media-type="application/x-dtbncx+xml"/>')
    if attribution:
        manifest += '<item id="tbl-attribution" href="tbl-attribution.xhtml" media-type="application/xhtml+xml"/>'
    spine = "".join(f'<itemref idref="{i}"/>' for i, _, _ in docs)
    if attribution:
        spine += '<itemref idref="tbl-attribution"/>'
    opf = ('<?xml version="1.0" encoding="utf-8"?>'
           '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           '<dc:identifier id="id">urn:test:saga</dc:identifier><dc:title>Fake Saga</dc:title>'
           '<dc:creator>Jane Author</dc:creator><dc:description>A tale of Aldric.'
           + ('\n\nTranslated using TranslateBook with LLM (TBL)\nhttps://example.test' if attribution else '')
           + '</dc:description>'
           + ('<dc:contributor id="tbl-translator">TranslateBook with LLM (TBL)</dc:contributor>'
              '<meta refines="#tbl-translator" property="role" scheme="marc:relators">trl</meta>'
              if attribution else '')
           +
           '<dc:language>en</dc:language></metadata>'
           f'<manifest>{manifest}</manifest><spine toc="ncx">{spine}</spine></package>')
    nav_items = "".join(f'<li><a href="{i}.xhtml">{t}</a></li>' for i, t, _ in docs)
    nav = ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
           'xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>'
           f'{nav_items}</ol></nav></body></html>')
    points = "".join(
        f'<navPoint id="n{n}" playOrder="{n}"><navLabel><text>{t}</text></navLabel>'
        f'<content src="{i}.xhtml"/></navPoint>' for n, (i, t, _) in enumerate(docs, 1))
    ncx = ('<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
           f'version="2005-1"><navMap>{points}</navMap></ncx>')
    container = ('<?xml version="1.0"?><container version="1.0" '
                 'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                 '<rootfile full-path="OEBPS/content.opf" '
                 'media-type="application/oebps-package+xml"/></rootfiles></container>')
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container)
        z.writestr("OEBPS/content.opf", opf)
        z.writestr("OEBPS/nav.xhtml", nav)
        z.writestr("OEBPS/toc.ncx", ncx)
        for i, t, body in docs:
            z.writestr(f"OEBPS/{i}.xhtml", XHTML.format(title=t, body=body))
        z.writestr("OEBPS/img/cover.png", b"\x89PNGcover")
        if attribution:
            z.writestr("OEBPS/tbl-attribution.xhtml", XHTML.format(title="Colophon", body="<p>TBL</p>"))
        for v in range(1, volumes + 1):
            z.writestr(f"OEBPS/img/v{v}.png", b"\x89PNG" + bytes([v]))
    return path
