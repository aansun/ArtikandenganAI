"""
Send a finished book to a Kindle by e-mail (Amazon's "Send to Kindle" address).

Amazon takes what the EPUB itself says about the book, so each file is checked before it
leaves: a book without a title, an author or a language, a damaged file or one too large
for e-mail is not sent. What was sent is remembered beside the book (``kindle.json``, by
the file's fingerprint), so the same file is not sent twice, and a file that changed since
is shown as such and can be sent again.

The mail goes through the user's own SMTP server with ``smtplib``, always encrypted. The
settings, password included, come from the environment only (see ``ENVIRONMENT``): they are
never read from a command line, written to a file or logged. Only the sender address that
Amazon has on its approved list is accepted by a Kindle.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import smtplib
import ssl
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional, Set

from lxml import etree

from src.core.agent.epub_metadata import read_metadata
from src.core.epub.lang_support import get_language_code

logger = logging.getLogger("core.agent.kindle")

RECORD = "kindle.json"
#: The largest attachment Amazon accepts by e-mail.
MAX_BYTES = 50 * 1024 * 1024
KINDLE_DOMAINS = ("kindle.com", "free.kindle.com", "kindle.cn")
ENVIRONMENT = ("KINDLE_TO", "KINDLE_FROM", "KINDLE_SMTP_HOST", "KINDLE_SMTP_PORT",
               "KINDLE_SMTP_USER", "KINDLE_SMTP_PASSWORD")
TIMEOUT = 120
#: How this computer greets the mail server. Its own name can hold its owner's, and on a Mac
#: it is sometimes a reversed network address that servers turn away.
GREETING = "[127.0.0.1]"
#: Problems that stop a file from being sent; the others are only told.
BLOCKING = ("unreadable", "too_large", "title", "author", "author_email", "language")
#: What a title or an author says when whoever made the file did not know it.
PLACEHOLDERS = ("unknown", "tidak diketahui")
_ADDRESS_INSIDE = re.compile(r"[^@\s<>,;]+@[^@\s<>,;]+\.[A-Za-z]{2,}")
_ADDRESS = re.compile(r"^[^@\s<>,;]+@[^@\s<>,;]+\.[A-Za-z]{2,}$")
_FILE_NAME_TITLE = re.compile(r"_|z-?lib|\b1lib\b|libgen|\.epub\b|\(\d+\)\s*$", re.I)


class KindleError(Exception):
    """Why nothing could be sent: ``code`` is one word the app words for the user."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code, self.detail = code, detail


@dataclass
class Settings:
    to: str
    sender: str
    host: str
    port: int
    user: str
    password: str

    @classmethod
    def from_environment(cls, env: Optional[Mapping[str, str]] = None) -> "Settings":
        env = os.environ if env is None else env
        values = {name: (env.get(name) or "").strip() for name in ENVIRONMENT}
        if not all(values[n] for n in ("KINDLE_TO", "KINDLE_FROM", "KINDLE_SMTP_HOST", "KINDLE_SMTP_PASSWORD")):
            raise KindleError("settings", "the Kindle address, the sender, the server and its password are needed")
        to, sender = values["KINDLE_TO"], values["KINDLE_FROM"]
        if not _ADDRESS.match(to) or to.rsplit("@", 1)[1].lower() not in KINDLE_DOMAINS:
            raise KindleError("kindle_address", "the destination must be a Send to Kindle address (…@kindle.com)")
        if not _ADDRESS.match(sender):
            raise KindleError("sender_address", "the sender is not an e-mail address")
        try:
            port = int(values["KINDLE_SMTP_PORT"] or 587)
        except ValueError:
            raise KindleError("settings", "the server port is not a number")
        return cls(to, sender, values["KINDLE_SMTP_HOST"], port, values["KINDLE_SMTP_USER"] or sender,
                   values["KINDLE_SMTP_PASSWORD"])


# ----------------------------------------------------------------- the files
def fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _sound(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as z:
            if z.testzip():
                return False
            for name in z.namelist():
                if name.lower().endswith((".opf", ".ncx", ".xhtml")):
                    etree.fromstring(z.read(name), etree.XMLParser(resolve_entities=False))
        return True
    except (OSError, zipfile.BadZipFile, etree.XMLSyntaxError):
        return False


def inspect_file(path: Path, target_language: str = "Indonesian") -> dict:
    """What Amazon will read from this file, and what is wrong with it."""
    problems: List[str] = []
    if path.suffix.lower() != ".epub" or not path.is_file() or not _sound(path):
        return {"title": "", "author": "", "language": "", "cover": False, "series": "",
                "bytes": path.stat().st_size if path.is_file() else 0, "problems": ["unreadable"]}
    info = read_metadata(path)
    title = info.get("title", "")
    author = ", ".join(c for c in info.get("creators", []) if c)
    language = info.get("language", "")
    size = path.stat().st_size
    if size > MAX_BYTES:
        problems.append("too_large")
    if not title or title.strip().lower() in PLACEHOLDERS:
        problems.append("title")
    if not author or author.strip().lower() in PLACEHOLDERS:
        problems.append("author")
    elif _ADDRESS_INSIDE.search(author):     # a file's maker left an e-mail address there
        problems.append("author_email")
    if not language:
        problems.append("language")
    else:
        code = get_language_code(target_language)
        if code and not language.lower().startswith(code.lower()):
            problems.append("language_differs")
    if title and _FILE_NAME_TITLE.search(title):
        problems.append("title_like_file_name")
    if "�" in title + author:
        problems.append("damaged_characters")
    if not info.get("cover"):
        problems.append("cover")
    series = info.get("series") or ""
    if series and info.get("series_index"):
        series = f"{series} #{info['series_index']}"
    return {"title": title, "author": author, "language": language, "cover": bool(info.get("cover")),
            "series": series, "bytes": size, "problems": problems}


def attachment_name(title: str, author: str) -> str:
    name = f"{title} - {author}" if author else title or "book"
    name = " ".join(re.sub(r'[\\/:*?"<>|\x00-\x1f]+', " ", name).split())
    return name[:100].rstrip(" .-") + ".epub"


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
    """Every finished volume of a book, with its details and whether it was sent."""
    try:
        book = json.loads((folder / "book.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise KindleError("book", "no finished book in this folder")
    record = read_record(folder)
    files = []
    for volume in book.get("volumes", []):
        path = Path(volume.get("output") or "")
        if volume.get("status") != "completed" or not path.is_file():
            continue
        index = int(volume.get("index", 1))
        entry = {"volume": index, "path": str(path),
                 **inspect_file(path, book.get("target_language") or "Indonesian"),
                 "sha256": fingerprint(path)}
        mine = [e for e in record if e.get("volume") == index]
        same = [e for e in mine if e["sha256"] == entry["sha256"]]
        entry["state"] = "sent" if same else ("changed" if mine else "new")
        entry["sent_at"] = (same or mine)[-1].get("at", "") if mine else ""
        files.append(entry)
    titles = [f["title"] for f in files if f["title"]]
    for f in files:             # two volumes under one title look like a double on the Kindle
        if titles.count(f["title"]) > 1:
            f["problems"] = f["problems"] + ["same_title"]
    return files


# ------------------------------------------------------------------ the mail
def message(settings: Settings, path: Path, title: str, author: str) -> EmailMessage:
    mail = EmailMessage()
    mail["From"] = settings.sender
    mail["To"] = settings.to
    mail["Subject"] = title or path.stem
    mail.set_content(f"{title}\n{author}\n\nSent with NNAI Translator.")
    mail.add_attachment(path.read_bytes(), maintype="application", subtype="epub+zip",
                        filename=attachment_name(title, author))
    return mail


def connect(settings: Settings) -> smtplib.SMTP:
    """An encrypted, signed-in connection. The caller closes it."""
    context = ssl.create_default_context()
    try:
        if settings.port == 465:
            server = smtplib.SMTP_SSL(settings.host, settings.port, local_hostname=GREETING,
                                      timeout=TIMEOUT, context=context)
        else:
            server = smtplib.SMTP(settings.host, settings.port, local_hostname=GREETING, timeout=TIMEOUT)
            try:
                server.starttls(context=context)        # raises when the server cannot encrypt
            except Exception:
                server.close()
                raise
        try:
            _sign_in(server, settings)
        except Exception:
            server.close()
            raise
    except KindleError:
        raise
    except Exception as exc:
        raise _explain(exc, settings) from None
    return server


def _sign_in(server: smtplib.SMTP, settings: Settings) -> None:
    """Sign in with one attempt, so that a refusal is told as one.

    ``smtplib`` tries one method after another. Gmail hangs up after the first refusal, and the
    second attempt then fails as a lost connection, which hides that the password was refused.
    """
    server.ehlo_or_helo_if_needed()
    if "PLAIN" in server.esmtp_features.get("auth", "").split():
        server.esmtp_features["auth"] = "PLAIN"
    try:
        server.login(settings.user, settings.password)
    except smtplib.SMTPServerDisconnected:
        raise KindleError("sign_in", "the server closed the connection during sign-in") from None
    except UnicodeError:                    # its own words would quote part of the password
        raise KindleError("sign_in", "the address or the password holds a character that cannot "
                                     "be sent; type it again") from None


def _explain(exc: Exception, settings: Settings) -> KindleError:
    detail = str(exc)
    if isinstance(exc, smtplib.SMTPResponseException):
        error = exc.smtp_error
        detail = f"{exc.smtp_code} {error.decode('utf-8', 'replace') if isinstance(error, bytes) else error}"
    detail = " ".join(detail.replace(settings.password, "***").split())[:200]
    if isinstance(exc, smtplib.SMTPAuthenticationError):
        return KindleError("sign_in", detail)
    if isinstance(exc, smtplib.SMTPRecipientsRefused):
        return KindleError("recipient_refused", detail)
    if isinstance(exc, smtplib.SMTPSenderRefused):
        return KindleError("sender_refused", detail)
    if isinstance(exc, smtplib.SMTPDataError):
        return KindleError("message_refused", detail)
    if isinstance(exc, (ssl.SSLError, smtplib.SMTPNotSupportedError)):
        return KindleError("encryption", detail)
    return KindleError("connection", detail)


def send(folder: Path, settings: Settings, *, volumes: Optional[Set[int]] = None, resend: bool = False,
         say: Callable[[str], None] = lambda message: None) -> List[dict]:
    """Send the chosen volumes of a book. Each one is recorded as soon as the server took it."""
    files = [f for f in book_files(folder) if volumes is None or f["volume"] in volumes]
    results: List[dict] = []
    due = []
    for f in files:
        blocking = [p for p in f["problems"] if p in BLOCKING]
        if blocking:
            results.append({"volume": f["volume"], "result": "blocked", "detail": ", ".join(blocking)})
        elif f["state"] == "sent" and not resend:
            results.append({"volume": f["volume"], "result": "already", "detail": f["sent_at"]})
        else:
            due.append(f)
    if not due:
        return sorted(results, key=lambda r: r["volume"])
    server = connect(settings)
    try:
        for f in due:
            say(f"Sending volume {f['volume']} to the Kindle")
            try:
                server.send_message(message(settings, Path(f["path"]), f["title"], f["author"]))
            except Exception as exc:
                problem = _explain(exc, settings)
                results.append({"volume": f["volume"], "result": "failed",
                                "detail": f"{problem.code}: {problem.detail}"})
                continue
            _remember(folder, {"volume": f["volume"], "sha256": f["sha256"], "title": f["title"],
                               "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
            results.append({"volume": f["volume"], "result": "sent", "detail": ""})
    finally:
        try:
            server.quit()
        except Exception:
            pass
    return sorted(results, key=lambda r: r["volume"])


def run_check(folder: Path) -> Dict[str, list]:
    files = book_files(folder)
    for f in files:
        f["blocked"] = any(p in BLOCKING for p in f["problems"])
        del f["path"]
    return {"files": files}
