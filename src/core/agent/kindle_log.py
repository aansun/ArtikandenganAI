"""
The Send to Kindle log: what happened at each connection test and each send, to find out why
one failed.

A local file, ``<library>/_diagnostics/kindle.jsonl``, one JSON object per line, the newest
last. Nothing sends it anywhere.

**What never goes in:** the password, e-mail addresses, titles, authors, file names or paths.
Only the fields in ``FIELDS`` are written, and every address in a server's reply is replaced.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

logger = logging.getLogger("core.agent.kindle_log")

FOLDER = "_diagnostics"
FILE = "kindle.jsonl"
#: The oldest lines are dropped beyond this many.
KEEP = 300
FIELDS = ("action", "host", "port", "own_user_name", "app_password_shape", "ok", "stage", "error",
          "detail", "volumes", "seconds")
_ADDRESS = re.compile(r"[^\s<>,;:()\[\]\"']+@[^\s<>,;:()\[\]\"']+")


def clean(text: str, password: str = "") -> str:
    """A server's reply without addresses and without the password."""
    if password:
        text = text.replace(password, "***")
    return _ADDRESS.sub("<address>", text)[:300]


def settings_facts(env: Mapping[str, str]) -> dict:
    """What can be told about the settings without telling them."""
    host = (env.get("KINDLE_SMTP_HOST") or "").strip()
    password = (env.get("KINDLE_SMTP_PASSWORD") or "").strip()
    user = (env.get("KINDLE_SMTP_USER") or "").strip()
    facts = {"host": clean(host, password), "port": (env.get("KINDLE_SMTP_PORT") or "").strip()[:6],
             "own_user_name": bool(user) and user != (env.get("KINDLE_FROM") or "").strip()}
    if host.lower() == "smtp.gmail.com" and password:
        # Google's app passwords are 16 small letters; anything else is likely the account's own
        facts["app_password_shape"] = re.fullmatch(r"[a-z]{16}", password) is not None
    return facts


def record(root: Path, *, app_version: str = "", password: str = "", **fields) -> None:
    """Append one line. A log that cannot be written never stops a send."""
    try:
        entry = {"time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "app": app_version[:20]}
        entry.update({k: fields[k] for k in FIELDS if fields.get(k) not in (None, "")})
        if "detail" in entry:
            entry["detail"] = clean(entry["detail"], password)
        for volume in entry.get("volumes", []):
            volume["detail"] = clean(volume.get("detail", ""), password)
        path = Path(root) / FOLDER / FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        old = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
        lines = old[-(KEEP - 1):] + [json.dumps(entry, ensure_ascii=False)]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception as exc:  # noqa: BLE001 - the log is a help, never a failure
        logger.debug("Kindle log not written: %s", exc)
