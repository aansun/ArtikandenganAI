"""
The ``books/`` library: where uploads arrive and where every book's files live.

    books/
      inbox/                drop new books here (a file, or a folder of volumes)
      INDEX.md              one table of every book, with links to the translations
      <book>/
        source/             the original upload
        volumes/            the per-volume split of the original
        translation/        the finished, translated volumes  <- read these
        glossary.json       shared glossary (fiction), editable
        book.json           everything known about the book and each volume
        state.json          resume state of the agent (internal)
        jobs.db             translation checkpoints (internal)
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Dict, List, Optional

from src.core.agent.volumes import SUPPORTED_SUFFIXES, natural_key

DEFAULT_BOOKS_DIR = "books"
STATUS_COMPLETED = "completed"

INBOX = "inbox"
SOURCE = "source"
VOLUMES = "volumes"
TRANSLATION = "translation"


def books_root(explicit: Optional[str] = None) -> Path:
    return Path(explicit or os.getenv("BOOKS_DIR", DEFAULT_BOOKS_DIR)).resolve()


def inbox_dir(root: Path) -> Path:
    return root / INBOX


def list_inbox(root: Path) -> List[Path]:
    """Uploads waiting in the inbox: supported files and folders, in natural order."""
    inbox = inbox_dir(root)
    if not inbox.is_dir():
        return []
    entries = [p for p in inbox.iterdir()
               if not p.name.startswith(".")
               and (p.is_dir() or p.suffix.lower() in SUPPORTED_SUFFIXES)]
    return sorted(entries, key=lambda p: natural_key(p.name))


def adopt_source(input_path: Path, workdir: Path, root: Path) -> Path:
    """Put the upload inside its book folder and return its new path.

    A file or folder from the inbox is moved; one from anywhere else is copied,
    so the original stays where the user keeps it.
    """
    input_path = Path(input_path).resolve()
    target_dir = workdir / SOURCE
    target = target_dir / input_path.name
    if input_path == target.resolve() or target_dir in input_path.parents:
        return input_path
    target_dir.mkdir(parents=True, exist_ok=True)
    if target.exists():
        return target
    if inbox_dir(root).resolve() in input_path.parents:
        shutil.move(str(input_path), str(target))
    elif input_path.is_dir():
        shutil.copytree(input_path, target)
    else:
        shutil.copy2(input_path, target)
    return target


def book_dirs(root: Path) -> List[Path]:
    return sorted((p for p in root.iterdir() if p.is_dir() and (p / "book.json").exists()),
                  key=lambda p: p.name.lower()) if root.is_dir() else []


def read_book(path: Path) -> Optional[Dict]:
    try:
        return json.loads((path / "book.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def unfinished_books(root: Path) -> List[Path]:
    """Source paths of books with volumes still to translate (for resuming)."""
    pending = []
    for folder in book_dirs(root):
        book = read_book(folder)
        if not book or all(v.get("status") == STATUS_COMPLETED for v in book.get("volumes", [])):
            continue
        source = Path(book.get("source", ""))
        if source.exists():
            pending.append(source)
    return pending


def write_index(root: Path) -> Path:
    """Regenerate ``INDEX.md``: one row per book, links to every translated volume."""
    lines = [
        "# Translated books", "",
        "| Book | Original | Languages | Genre | Volumes | Translation |",
        "|------|----------|-----------|-------|---------|-------------|",
    ]
    for folder in book_dirs(root):
        book = read_book(folder)
        if not book:
            continue
        volumes = book.get("volumes", [])
        done = [v for v in volumes if v.get("status") == STATUS_COMPLETED and v.get("output")]
        links = ", ".join(
            f"[{v.get('index')}]({_rel(Path(v['output']), root)})" for v in done) or "-"
        lines.append(
            f"| {_cell(book.get('title_translated') or book.get('title'))} "
            f"| {_cell(book.get('title'))} "
            f"| {_cell(book.get('source_language'))} -> {_cell(book.get('target_language'))} "
            f"| {_cell(book.get('genre'))} | {len(done)}/{len(volumes)} | {links} |")
    lines += ["", "Each book's folder holds `source/`, `translation/`, `glossary.json` and "
                  "`book.json` (full metadata).", ""]
    index = root / "INDEX.md"
    root.mkdir(parents=True, exist_ok=True)
    index.write_text("\n".join(lines), encoding="utf-8")
    return index


def _rel(path: Path, root: Path) -> str:
    try:
        return Path(path).resolve().relative_to(root).as_posix().replace(" ", "%20")
    except ValueError:
        return str(path)


def _cell(value) -> str:
    return str(value or "-").replace("|", "/").replace("\n", " ")
