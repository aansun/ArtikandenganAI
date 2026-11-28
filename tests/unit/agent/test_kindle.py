"""Sending a finished book to a Kindle, against a stand-in mail server (no network)."""
import json
import smtplib
import socket
import threading
import zipfile

import pytest

import translate_book
from src.core.agent import kindle
from src.core.agent.epub_metadata import edit_field
from tests.unit.agent.test_pipeline_e2e import book_dir, env, upload  # noqa: F401 - env is a fixture

PASSWORD = "YOUR_APP_PASSWORD_HERE"


class FakeServer:
    """Stands in for smtplib.SMTP: remembers what happened."""
    log: list = []
    sent: list = []
    refuse: dict = {}

    def __init__(self, host, port, local_hostname=None, timeout=None, context=None):
        FakeServer.log.append(("connect", host, port))
        FakeServer.greeting = local_hostname
        self.esmtp_features = {"auth": " LOGIN PLAIN XOAUTH2"}

    def starttls(self, context=None):
        FakeServer.log.append(("starttls", context is not None))
        if "tls" in FakeServer.refuse:
            raise smtplib.SMTPNotSupportedError("STARTTLS extension not supported by server.")

    def ehlo_or_helo_if_needed(self):
        pass

    def login(self, user, password):
        FakeServer.log.append(("login", user))
        assert self.esmtp_features["auth"] == "PLAIN"
        if "login" in FakeServer.refuse:
            raise smtplib.SMTPAuthenticationError(535, f"bad password {password}".encode())

    def send_message(self, mail):
        if mail["Subject"] in FakeServer.refuse:
            raise smtplib.SMTPDataError(552, b"too big")
        FakeServer.sent.append(mail)

    def quit(self):
        FakeServer.log.append(("quit",))

    close = quit


@pytest.fixture
def mail(monkeypatch):
    FakeServer.log, FakeServer.sent, FakeServer.refuse = [], [], {}
    monkeypatch.setattr(smtplib, "SMTP", FakeServer)
    monkeypatch.setattr(smtplib, "SMTP_SSL", FakeServer)
    for name, value in {"KINDLE_TO": "reader@kindle.com", "KINDLE_FROM": "me@example.org",
                        "KINDLE_SMTP_HOST": "smtp.example.org", "KINDLE_SMTP_PORT": "587",
                        "KINDLE_SMTP_USER": "", "KINDLE_SMTP_PASSWORD": PASSWORD}.items():
        monkeypatch.setenv(name, value)
    return FakeServer


@pytest.fixture
def book(env, capsys):
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine"]) == 0
    capsys.readouterr()
    return book_dir(env)


def run(capsys, *args):
    code = translate_book.main(list(args))
    return code, json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_each_volume_shows_what_the_kindle_will_read(book, capsys):
    code, found = run(capsys, "--kindle-check", str(book))
    assert code == 0
    first, second = found["files"]
    assert first["title"] == "Fake Saga - Volume 1" and first["author"] == "Jane Author"
    assert first["language"] == "id" and first["cover"] and first["series"] == "Fake Saga #1"
    assert [f["state"] for f in (first, second)] == ["new", "new"]
    assert first["problems"] == [] and not first["blocked"] and "path" not in first


def test_volumes_are_sent_once_and_again_only_when_changed_or_asked(book, capsys, mail):
    code, answer = run(capsys, "--kindle-send", str(book))
    assert code == 0 and [r["result"] for r in answer["results"]] == ["sent", "sent"]
    assert ("starttls", True) in mail.log and ("login", "me@example.org") in mail.log
    first = mail.sent[0]
    assert first["To"] == "reader@kindle.com" and first["From"] == "me@example.org"
    [attached] = list(first.iter_attachments())
    assert attached.get_content_type() == "application/epub+zip"
    assert attached.get_filename() == "Fake Saga - Volume 1 - Jane Author.epub"
    record = (book / "kindle.json").read_text()
    assert "reader@kindle.com" not in record and PASSWORD not in record

    code, answer = run(capsys, "--kindle-send", str(book))            # nothing twice
    assert code == 0 and [r["result"] for r in answer["results"]] == ["already", "already"]
    assert len(mail.sent) == 2

    translate_book.main(["--set-metadata", str(book), "--field", "publisher", "--value", "Fixed"])
    capsys.readouterr()
    code, found = run(capsys, "--kindle-check", str(book))
    assert [f["state"] for f in found["files"]] == ["changed", "changed"]
    code, answer = run(capsys, "--kindle-send", str(book), "--volumes", "2")
    assert [(r["volume"], r["result"]) for r in answer["results"]] == [(2, "sent")]
    code, answer = run(capsys, "--kindle-send", str(book), "--volumes", "2", "--resend")
    assert answer["results"][0]["result"] == "sent" and len(mail.sent) == 4


def test_a_file_without_its_details_is_not_sent(book, capsys, mail):
    translate_book.main(["--set-metadata", str(book), "--field", "creator", "--value", ""])
    capsys.readouterr()
    code, answer = run(capsys, "--kindle-send", str(book))
    assert code == 1 and {r["result"] for r in answer["results"]} == {"blocked"}
    assert mail.sent == [] and mail.log == []                       # not even a connection
    code, found = run(capsys, "--kindle-check", str(book))
    assert "author" in found["files"][0]["problems"] and found["files"][0]["blocked"]


@pytest.mark.parametrize("field,value,problem", [
    ("title", "Unknown", "title"),
    ("title", "Tidak Diketahui", "title"),
    ("creator", "Unknown", "author"),
    ("creator", "someone@example.org", "author_email"),
    ("creator", "Jane Author <jane@example.org>", "author_email"),
])
def test_placeholder_details_and_an_address_as_author_are_not_sent(book, capsys, mail, field, value, problem):
    for output in sorted((book / "translation").glob("*.epub")):
        edit_field(output, field, value)
    code, found = run(capsys, "--kindle-check", str(book))
    assert all(problem in f["problems"] and f["blocked"] for f in found["files"])
    code, answer = run(capsys, "--kindle-send", str(book))
    assert code == 1 and {r["result"] for r in answer["results"]} == {"blocked"}
    assert mail.sent == [] and mail.log == []


def test_an_at_sign_in_a_name_is_not_an_address(book, capsys):
    for output in sorted((book / "translation").glob("*.epub")):
        edit_field(output, "creator", "J@ne Author")
    code, found = run(capsys, "--kindle-check", str(book))
    assert found["files"][0]["problems"] == [] and not found["files"][0]["blocked"]


def test_one_refused_volume_does_not_mark_it_sent(book, capsys, mail):
    mail.refuse = {"Fake Saga - Volume 1": True}
    code, answer = run(capsys, "--kindle-send", str(book))
    assert code == 1 and [r["result"] for r in answer["results"]] == ["failed", "sent"]
    assert answer["results"][0]["detail"].startswith("message_refused: 552")
    assert [e["volume"] for e in kindle.read_record(book)] == [2]


@pytest.mark.parametrize("refuse,error", [("login", "sign_in"), ("tls", "encryption")])
def test_sign_in_problems_are_named_and_the_password_stays_secret(book, capsys, mail, refuse, error):
    mail.refuse = {refuse: True}
    code, answer = run(capsys, "--kindle-send", str(book))
    assert code == 1 and answer["error"] == error and PASSWORD not in json.dumps(answer)
    assert mail.sent == [] and not (book / "kindle.json").exists()


def test_the_settings_are_tested_without_sending(env, capsys, mail, monkeypatch):
    code, answer = run(capsys, "--kindle-test")
    assert code == 0 and answer == {"ok": True} and mail.sent == []
    monkeypatch.setenv("KINDLE_SMTP_PORT", "465")
    assert run(capsys, "--kindle-test")[0] == 0
    monkeypatch.setenv("KINDLE_TO", "someone@example.org")
    assert run(capsys, "--kindle-test")[1]["error"] == "kindle_address"
    monkeypatch.setenv("KINDLE_SMTP_PASSWORD", "")
    assert run(capsys, "--kindle-test")[1]["error"] == "settings"


def _gmail_like(on_auth):
    """A mail server on this computer: answers the first sign-in and hangs up on a second one."""
    listener = socket.create_server(("127.0.0.1", 0))
    seen = []

    def serve():
        connection, _ = listener.accept()
        with connection, connection.makefile("rb") as lines:
            connection.sendall(b"220 ready\r\n")
            for line in lines:
                seen.append([line.split()[0].upper(), *line.split()[1:2]])
                if seen[-1][0] == b"EHLO":
                    connection.sendall(b"250-hello\r\n250 AUTH LOGIN PLAIN XOAUTH2\r\n")
                elif seen[-1][0] == b"AUTH" and on_auth and len([s for s in seen if s[0] == b"AUTH"]) == 1:
                    connection.sendall(on_auth)
                else:
                    break
        listener.close()

    threading.Thread(target=serve, daemon=True).start()
    return listener.getsockname()[1], seen


@pytest.mark.parametrize("reply,detail", [
    (b"535 5.7.8 Username and Password not accepted\r\n", "535 5.7.8 Username and Password not accepted"),
    (None, "the server closed the connection during sign-in"),
])
def test_a_refused_sign_in_is_not_told_as_a_lost_connection(monkeypatch, reply, detail):
    port, seen = _gmail_like(reply)
    monkeypatch.setattr(smtplib.SMTP, "starttls", lambda self, context=None: (220, b""))
    settings = kindle.Settings("reader@kindle.com", "me@example.org", "127.0.0.1", port,
                               "me@example.org", PASSWORD)
    with pytest.raises(kindle.KindleError) as refused:
        kindle.connect(settings)
    assert (refused.value.code, refused.value.detail) == ("sign_in", detail)
    assert seen[0] == [b"EHLO", b"[127.0.0.1]"]
    assert [s for s in seen if s[0] == b"AUTH"] == [[b"AUTH", b"PLAIN"]]


def test_a_character_the_sign_in_cannot_carry_is_not_quoted(monkeypatch):
    port, _seen = _gmail_like(b"535 no\r\n")
    monkeypatch.setattr(smtplib.SMTP, "starttls", lambda self, context=None: (220, b""))
    settings = kindle.Settings("reader@kindle.com", "me@example.org", "127.0.0.1", port,
                               "me@example.org", "xxxx\u00a0xxxx")
    with pytest.raises(kindle.KindleError) as refused:
        kindle.connect(settings)
    assert refused.value.code == "sign_in" and "xa0" not in refused.value.detail


def test_two_volumes_under_one_title_and_a_file_name_title_are_told(book, capsys):
    for output in sorted((book / "translation").glob("*.epub")):
        edit_field(output, "title", "My_Book_z-library")
    code, found = run(capsys, "--kindle-check", str(book))
    problems = found["files"][0]["problems"]
    assert "same_title" in problems and "title_like_file_name" in problems and not found["files"][0]["blocked"]


def test_a_damaged_file_is_not_sent(book, capsys, mail):
    first = sorted((book / "translation").glob("*.epub"))[0]
    with zipfile.ZipFile(first) as z:
        entries = {n: z.read(n) for n in z.namelist()}
    entries["OEBPS/content.opf"] = b"<broken"
    with zipfile.ZipFile(first, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)
    code, answer = run(capsys, "--kindle-send", str(book))
    assert [r["result"] for r in answer["results"]] == ["blocked", "sent"]
    assert answer["results"][0]["detail"] == "unreadable"
