"""
Send a finished book to an Xteink e-ink reader over the local network.

The reader runs the CrossPoint firmware (https://github.com/crosspoint-reader/crosspoint-reader):
while it shows *File Transfer*, it serves a small web server at ``http://crosspoint.local`` or at
the address on its screen. This module asks it who it is, makes the target folder, uploads each
volume with ``POST /upload`` and reads the folder back to make sure the file arrived whole.
Xteink's own firmware has another interface and is not supported.

Only addresses of the local network are accepted, so a book cannot be sent to the internet by a
mistyped address. A file on the reader that this app did not put there is replaced only when
asked. What was sent is remembered beside the book (``xteink.json``).
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import logging
import re
import secrets
import socket
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple
from urllib.parse import quote

from src.core.agent.epub_metadata import read_metadata
from src.core.agent.kindle import fingerprint
from src.core.agent.xteink_optimize import OptimizeError, optimize

logger = logging.getLogger("core.agent.xteink")

RECORD = "xteink.json"
ADDRESS = "crosspoint.local"
FOLDER = "/Books"
TIMEOUT = 20
UPLOAD_TIMEOUT = 120
_HOST = re.compile(r"^([A-Za-z0-9](?:[A-Za-z0-9.-]{0,252}[A-Za-z0-9])?)(?::(\d{1,5}))?$")
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]+')


class XteinkError(Exception):
    """Why nothing could be sent: ``code`` is one word the app words for the user."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code, self.detail = code, detail


def parse_address(text: str) -> Tuple[str, int]:
    """``(host, port)`` from what the user typed, with or without ``http://`` and a slash."""
    value = re.sub(r"^\s*http://", "", text or ADDRESS, flags=re.I).strip().rstrip("/")
    match = _HOST.match(value or ADDRESS)
    port = int(match.group(2) or 80) if match else 0
    if not match or not 0 < port < 65536:
        raise XteinkError("address", "type a name or an IP address, such as crosspoint.local or 192.168.1.20")
    return match.group(1), port


def parse_folder(text: str) -> str:
    """The folder on the reader's card, as ``/A/B``; ``/`` is the card itself."""
    parts = [p.strip() for p in (text or FOLDER).split("/") if p.strip()]
    if any(p.startswith(".") or _UNSAFE.search(p) for p in parts):
        raise XteinkError("folder", "a folder name cannot start with a dot or hold \\ : * ? \" < > |")
    return "/" + "/".join(parts)


def _local_ip(host: str, port: int) -> str:
    """The reader's address on the local network; anything else is refused."""
    try:
        found = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise XteinkError("unreachable", f"{host} was not found ({exc.__class__.__name__})")
    # IPv4 first: the reader serves it, and a .local name may list other addresses too
    for _family, _type, _proto, _name, where in sorted(found, key=lambda f: f[0] != socket.AF_INET):
        ip = ipaddress.ip_address(where[0].split("%")[0])
        if ip.is_private or ip.is_link_local or ip.is_loopback:
            return where[0]
    raise XteinkError("not_local", f"{host} is not an address of the local network")


class Reader:
    """One reader on the network."""

    def __init__(self, address: str):
        self.host, self.port = parse_address(address)
        self.ip = _local_ip(self.host, self.port)

    def _ask(self, method: str, path: str, body: Optional[bytes] = None, headers: Optional[dict] = None,
             timeout: int = TIMEOUT) -> Tuple[int, str]:
        connection = http.client.HTTPConnection(self.ip, self.port, timeout=timeout)
        try:
            connection.request(method, path, body=body, headers={"Host": self.host, **(headers or {})})
            answer = connection.getresponse()
            return answer.status, answer.read(2_000_000).decode("utf-8", "replace")
        except (OSError, http.client.HTTPException) as exc:
            raise XteinkError("unreachable", f"{self.host}: {exc.__class__.__name__}")
        finally:
            connection.close()

    def status(self) -> dict:
        code, text = self._ask("GET", "/api/status")
        try:
            found = json.loads(text)
            if code != 200 or "version" not in found:
                raise ValueError
        except (ValueError, TypeError):
            raise XteinkError("not_crosspoint", f"{self.host} answered {code}, not as a CrossPoint reader")
        return {"device": str(found.get("device") or "X4"), "version": str(found.get("version")),
                "firmware": str(found.get("firmwareFamily") or "")}

    def files(self, folder: str) -> Dict[str, dict]:
        code, text = self._ask("GET", f"/api/files?path={quote(folder)}")
        try:
            return {e["name"]: e for e in json.loads(text)} if code == 200 else {}
        except (ValueError, TypeError, KeyError):
            raise XteinkError("not_crosspoint", "the reader's file list could not be read")

    def make_folder(self, folder: str) -> None:
        parent = "/"
        for name in [p for p in folder.split("/") if p]:
            entry = self.files(parent).get(name)
            if entry is None:
                body = f"name={quote(name)}&path={quote(parent)}".encode()
                code, text = self._ask("POST", "/mkdir", body,
                                       {"Content-Type": "application/x-www-form-urlencoded"})
                if code != 200 and "already exists" not in text:
                    raise XteinkError("folder", f"{code} {text[:120]}")
            elif not entry.get("isDirectory"):
                raise XteinkError("folder", f"{name} is a file on the reader")
            parent = parent.rstrip("/") + "/" + name

    def upload(self, folder: str, name: str, data: bytes, replace: bool) -> None:
        mark = "nnai" + secrets.token_hex(12)
        body = (f'--{mark}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                "Content-Type: application/epub+zip\r\n\r\n").encode() + data + f"\r\n--{mark}--\r\n".encode()
        path = f"/upload?path={quote(folder)}" + ("&overwrite=1" if replace else "")
        code, text = self._ask("POST", path, body, {"Content-Type": f"multipart/form-data; boundary={mark}"},
                               timeout=UPLOAD_TIMEOUT)
        if code != 200:
            raise XteinkError("exists" if "already exists" in text else "refused", f"{code} {text[:160]}")
        entry = self.files(folder).get(name)
        if entry is None or int(entry.get("size", -1)) != len(data):
            raise XteinkError("incomplete", "the file on the reader is not the size that was sent")


def file_name(title: str, author: str) -> str:
    """A name the reader's card takes: plain letters, no path marks, not too long."""
    whole = f"{title} - {author}" if author else title or "book"
    plain = unicodedata.normalize("NFKD", whole).encode("ascii", "ignore").decode()
    plain = " ".join(_UNSAFE.sub(" ", plain).split()).lstrip(". ")
    return (plain[:90].rstrip(" .-") or "book") + ".epub"


# ------------------------------------------------------------ what was sent
def read_record(folder: Path) -> List[dict]:
    try:
        sent = json.loads((folder / RECORD).read_text(encoding="utf-8"))["sent"]
        return [e for e in sent if isinstance(e, dict) and e.get("sha256")]
    except (OSError, ValueError, KeyError, TypeError):
        return []


def _remember(folder: Path, entry: dict) -> None:
    sent = read_record(folder) + [entry]
    tmp = folder / (RECORD + ".tmp")
    tmp.write_text(json.dumps({"sent": sent}, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(folder / RECORD)


def book_files(folder: Path) -> List[dict]:
    """Every finished volume of a book, and whether it went to the reader."""
    try:
        book = json.loads((folder / "book.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise XteinkError("book", "no finished book in this folder")
    record = read_record(folder)
    files = []
    for volume in book.get("volumes", []):
        path = Path(volume.get("output") or "")
        if volume.get("status") != "completed" or not path.is_file() or path.suffix.lower() != ".epub":
            continue
        index = int(volume.get("index", 1))
        print_ = fingerprint(path)
        mine = [e for e in record if e.get("volume") == index]
        same = [e for e in mine if e["sha256"] == print_]
        files.append({"volume": index, "path": str(path), "sha256": print_,
                      "state": "sent" if same else ("changed" if mine else "new"),
                      "sent_at": (same or mine)[-1].get("at", "") if mine else "",
                      "sent_names": [e.get("name", "") for e in mine]})
    return files


def run_check(folder: Path) -> Dict[str, list]:
    keep = ("volume", "state", "sent_at")
    return {"files": [{k: f[k] for k in keep} for f in book_files(folder)]}


def _names(files: List[dict]) -> Dict[int, str]:
    """The name of each volume on the reader; volumes under one title get their number."""
    details = {}
    for f in files:
        info = read_metadata(Path(f["path"]))
        details[f["volume"]] = (info.get("title", ""), ", ".join(c for c in info.get("creators", []) if c))
    names = {volume: file_name(*d) for volume, d in details.items()}
    taken = [n.lower() for n in names.values()]
    for volume, (title, author) in details.items():
        if taken.count(names[volume].lower()) > 1:
            names[volume] = file_name(f"{title or 'book'} vol {volume}", author)
    return names


def send(folder: Path, address: str, target: str = FOLDER, *, volumes: Optional[Set[int]] = None,
         resend: bool = False, prepare: bool = True,
         say: Callable[[str], None] = lambda message: None) -> Tuple[dict, List[dict]]:
    """Send the chosen volumes. Returns what the reader is and one result per volume."""
    target = parse_folder(target)
    every = book_files(folder)
    files = [f for f in every if volumes is None or f["volume"] in volumes]
    results = [{"volume": f["volume"], "result": "already", "detail": f["sent_at"]}
               for f in files if f["state"] == "sent" and not resend]
    due = [f for f in files if f["state"] != "sent" or resend]
    if not due:
        return {}, sorted(results, key=lambda r: r["volume"])
    reader = Reader(address)
    found = reader.status()
    reader.make_folder(target)
    names = _names(every)
    for f in due:
        path = Path(f["path"])
        name = names[f["volume"]]
        try:
            # the card does not tell capitals from small letters
            there = next((n for n in reader.files(target) if n.lower() == name.lower()), None)
            if there and not (resend or there in f["sent_names"]):
                raise XteinkError("exists", name)
            name = there or name
            with tempfile.TemporaryDirectory() as work:
                ready = path
                if prepare:
                    say(f"Preparing volume {f['volume']} for the {found['device']}")
                    ready = Path(work) / "reader.epub"
                    optimize(path, ready, found["device"])
                say(f"Sending volume {f['volume']} to the reader")
                data = ready.read_bytes()
                reader.upload(target, name, data, replace=there is not None)
        except (XteinkError, OptimizeError) as exc:
            results.append({"volume": f["volume"], "result": "exists" if exc.code == "exists" else "failed",
                            "detail": f"{exc.code}: {exc.detail}"})
            continue
        _remember(folder, {"volume": f["volume"], "sha256": f["sha256"], "name": name, "folder": target,
                           "bytes": len(data), "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        results.append({"volume": f["volume"], "result": "sent", "detail": ""})
    return found, sorted(results, key=lambda r: r["volume"])
