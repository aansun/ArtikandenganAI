"""Sending to an Xteink reader, against a stand-in of its web server on this computer."""
import io
import json
import threading
import zipfile
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import pytest
from lxml import etree
from PIL import Image

import translate_book
from src.core.agent import xteink, xteink_optimize
from tests.unit.agent.test_pipeline_e2e import book_dir, env, upload  # noqa: F401 - env is a fixture


class Card:
    """The reader's card and what was asked of it."""

    def __init__(self):
        self.folders, self.files, self.asked = {"/"}, {}, []
        self.status = {"version": "9.9", "firmwareFamily": "crosspoint", "device": "X3"}
        self.cut = False


def _handler(card: Card):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, code, text):
            body = text.encode() if isinstance(text, str) else text
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlsplit(self.path)
            card.asked.append(("GET", url.path))
            if url.path == "/api/status":
                return self._reply(200, json.dumps(card.status))
            folder = parse_qs(url.query).get("path", ["/"])[0]
            prefix = folder.rstrip("/") + "/"
            entries = [{"name": d[len(prefix):], "size": 0, "isDirectory": True} for d in card.folders
                       if d != "/" and d.startswith(prefix) and "/" not in d[len(prefix):]]
            entries += [{"name": p[len(prefix):], "size": len(v), "isDirectory": False} for p, v in card.files.items()
                        if p.startswith(prefix) and "/" not in p[len(prefix):]]
            self._reply(200, json.dumps(entries))

        def do_POST(self):
            url = urlsplit(self.path)
            query = parse_qs(url.query)
            body = self.rfile.read(int(self.headers["Content-Length"]))
            card.asked.append(("POST", url.path))
            if url.path == "/mkdir":
                form = parse_qs(body.decode())
                card.folders.add(form["path"][0].rstrip("/") + "/" + form["name"][0])
                return self._reply(200, "Folder created")
            message = BytesParser(policy=default).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
            [part] = list(message.iter_parts())
            name = part.get_filename()
            where = query["path"][0].rstrip("/") + "/" + name
            if where in card.files and query.get("overwrite") != ["1"]:
                return self._reply(400, f"File already exists: {name}")
            data = part.get_payload(decode=True)
            card.files[where] = data[:-10] if card.cut else data
            self._reply(200, f"File uploaded successfully: {name}")

    return Handler


@pytest.fixture
def reader():
    card = Card()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(card))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    card.address = f"127.0.0.1:{server.server_address[1]}"
    yield card
    server.shutdown()
    server.server_close()


@pytest.fixture
def book(env, capsys):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    capsys.readouterr()
    return book_dir(env)


def run(capsys, *args):
    code = translate_book.main(list(args))
    return code, json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def send(capsys, book, reader, *more):
    return run(capsys, "--xteink-send", str(book), "--xteink-address", reader.address, *more)


def test_the_reader_says_who_it_is(env, capsys, reader):
    code, answer = run(capsys, "--xteink-test", "--xteink-address", f"http://{reader.address}/")
    assert code == 0 and answer == {"ok": True, "device": "X3", "version": "9.9", "firmware": "crosspoint"}
    assert reader.files == {}


def test_volumes_go_to_the_folder_once_and_again_when_changed(book, env, capsys, reader):
    code, answer = send(capsys, book, reader, "--xteink-folder", "Books/Terjemahan")
    assert code == 0 and [r["result"] for r in answer["results"]] == ["sent", "sent"]
    assert {"/Books", "/Books/Terjemahan"} <= reader.folders
    assert sorted(reader.files) == ["/Books/Terjemahan/Fake Saga - Volume 1 - Jane Author.epub",
                                    "/Books/Terjemahan/Fake Saga - Volume 2 - Jane Author.epub"]
    for data in reader.files.values():
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            assert z.testzip() is None and z.namelist()[0] == "mimetype"

    asked = len(reader.asked)
    code, answer = send(capsys, book, reader)
    assert code == 0 and {r["result"] for r in answer["results"]} == {"already"}
    assert len(reader.asked) == asked                       # nothing twice, not even a request

    translate_book.main(["--set-metadata", str(book), "--field", "publisher", "--value", "Fixed"])
    capsys.readouterr()
    code, found = run(capsys, "--xteink-check", str(book))
    assert [f["state"] for f in found["files"]] == ["changed", "changed"] and "path" not in found["files"][0]
    code, answer = send(capsys, book, reader, "--xteink-folder", "Books/Terjemahan", "--volumes", "2")
    assert code == 0 and answer["results"][0]["result"] == "sent"    # its own old file is replaced

    lines = (env / "books" / "_diagnostics" / "xteink.jsonl").read_text().splitlines()
    last = json.loads(lines[-1])
    assert (last["action"], last["ok"], last["device"]) == ("send", True, "X3")
    assert "Fake Saga" not in "".join(lines)


def test_a_file_of_the_same_name_is_replaced_only_when_asked(book, capsys, reader):
    reader.folders.add("/Books")
    mine = "/Books/FAKE SAGA - Volume 1 - Jane Author.epub"
    reader.files[mine] = b"the user's own copy"
    code, answer = send(capsys, book, reader, "--volumes", "1")
    assert code == 1 and answer["results"][0]["result"] == "exists"
    assert reader.files == {mine: b"the user's own copy"}
    code, answer = send(capsys, book, reader, "--volumes", "1", "--resend")
    assert code == 0 and list(reader.files) == [mine] and reader.files[mine].startswith(b"PK")


def test_a_file_that_did_not_arrive_whole_is_not_marked_sent(book, capsys, reader):
    reader.cut = True
    code, answer = send(capsys, book, reader, "--volumes", "1")
    assert code == 1 and answer["results"][0]["detail"].startswith("incomplete")
    assert xteink.read_record(book) == []


@pytest.mark.parametrize("address,error", [
    ("93.184.216.34", "not_local"), ("not a name!", "address"), ("127.0.0.1/files", "address"),
    ("127.0.0.1:1", "unreachable"),
])
def test_only_a_reader_on_the_local_network_is_reached(env, capsys, address, error):
    code, answer = run(capsys, "--xteink-test", "--xteink-address", address)
    assert code == 1 and answer["error"] == error


def test_something_else_at_the_address_is_named(env, capsys, reader):
    reader.status = {"hello": "router"}
    code, answer = run(capsys, "--xteink-test", "--xteink-address", reader.address)
    assert code == 1 and answer["error"] == "not_crosspoint"


@pytest.mark.parametrize("typed,folder", [("", "/Books"), ("/", "/"), ("a//b/", "/a/b")])
def test_folder_names(typed, folder):
    assert xteink.parse_folder(typed) == folder


@pytest.mark.parametrize("typed", ["../x", ".hidden", "a/b:c"])
def test_folder_names_the_reader_would_refuse(typed):
    with pytest.raises(xteink.XteinkError):
        xteink.parse_folder(typed)


def test_names_on_the_card_are_plain_and_short():
    assert xteink.file_name("Pendekar: Bagian 1/2?", "José Ñ.") == "Pendekar Bagian 1 2 - Jose N.epub"
    assert len(xteink.file_name("a" * 300, "b")) == 95
    assert xteink.file_name("三体", "") == "book.epub"


# ------------------------------------------------------------ the preparation
def _png(size, mode="RGBA"):
    out = io.BytesIO()
    Image.new(mode, size, (200, 30, 30, 0) if mode == "RGBA" else (200, 30, 30)).save(out, "PNG")
    return out.getvalue()


def _epub(path, extra=None):
    opf = """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>
<item id="c" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
<item id="s" href="Styles/book.css" media-type="text/css"/>
<item id="i" href="Images/wide%20map.png" media-type="image/png" properties="cover-image"/>
<item id="j" href="Images/map.jpg" media-type="image/jpeg"/>
<item id="k" href="Images/map.png" media-type="image/png"/>
<item id="f" href="Fonts/fancy.ttf" media-type="font/ttf"/></manifest><spine><itemref idref="c"/></spine></package>"""
    page = """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body>
<p>“Aku di sini,” katanya. See map.png.</p><img src="../Images/wide%20map.png" alt="map.png"/>
<img src="../Images/map.png"/><img src="../Images/map.jpg"/><a href="https://example.org/map.png">x</a></body></html>"""
    css = '@font-face { font-family: F; src: url("../Fonts/fancy.ttf"); }\np { background: url(../Images/map.png) }'
    jpg = io.BytesIO()
    Image.new("RGB", (100, 60), (0, 0, 0)).save(jpg, "JPEG", progressive=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("OEBPS/content.opf", opf)
        z.writestr("OEBPS/Text/one.xhtml", page)
        z.writestr("OEBPS/Styles/book.css", css)
        z.writestr("OEBPS/Images/wide map.png", _png((2000, 1000)))
        z.writestr("OEBPS/Images/map.png", _png((40, 40), "RGB"))
        z.writestr("OEBPS/Images/map.jpg", jpg.getvalue())
        z.writestr("OEBPS/Fonts/fancy.ttf", b"font")
        z.writestr("__MACOSX/junk", b"x")
        for name, data in (extra or {}).items():
            z.writestr(name, data)


def test_pictures_fit_the_screen_fonts_leave_and_the_words_stay(tmp_path):
    source, ready = tmp_path / "a.epub", tmp_path / "b.epub"
    _epub(source)
    before = source.read_bytes()
    done = xteink_optimize.optimize(source, ready, "X4")
    assert done == {"pictures": 3, "fonts": 1, "skipped": 0} and source.read_bytes() == before
    with zipfile.ZipFile(ready) as z:
        names = set(z.namelist())
        assert names == {"mimetype", "OEBPS/content.opf", "OEBPS/Text/one.xhtml", "OEBPS/Styles/book.css",
                         "OEBPS/Images/wide map.jpg", "OEBPS/Images/map.jpg", "OEBPS/Images/map-png.jpg"}
        wide = Image.open(io.BytesIO(z.read("OEBPS/Images/wide map.jpg")))
        assert wide.format == "JPEG" and wide.size == (480, 240) and not wide.info.get("progressive")
        assert min(wide.getpixel((10, 10))) > 240           # see-through became white paper
        assert not Image.open(io.BytesIO(z.read("OEBPS/Images/map.jpg"))).info.get("progressive")
        page = z.read("OEBPS/Text/one.xhtml").decode()
        assert "“Aku di sini,” katanya. See map.png." in page and 'alt="map.png"' in page
        assert 'src="../Images/wide%20map.jpg"' in page and 'src="../Images/map-png.jpg"' in page
        assert 'src="../Images/map.jpg"' in page and "https://example.org/map.png" in page
        css = z.read("OEBPS/Styles/book.css").decode()
        assert "@font-face" not in css and "url(../Images/map-png.jpg)" in css
        opf = etree.fromstring(z.read("OEBPS/content.opf"))
        items = {i.get("id"): (i.get("href"), i.get("media-type")) for i in opf.iter("{*}item")}
        assert set(items) == {"c", "s", "i", "j", "k"}
        assert items["i"] == ("Images/wide%20map.jpg", "image/jpeg")
        assert items["k"] == ("Images/map-png.jpg", "image/jpeg") and items["j"] == ("Images/map.jpg", "image/jpeg")


def test_an_encrypted_book_is_refused(tmp_path):
    source = tmp_path / "a.epub"
    _epub(source, {"META-INF/encryption.xml": '<e xmlns:x="urn:x"><x:CipherReference URI="OEBPS/Text/one.xhtml"/></e>'})
    with pytest.raises(xteink_optimize.OptimizeError) as refused:
        xteink_optimize.optimize(source, tmp_path / "b.epub")
    assert refused.value.code == "drm"
