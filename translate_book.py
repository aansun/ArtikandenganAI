"""
Book translator agent (command line).

Translates whole books into Indonesian by default. Translation runs on the
``claude`` CLI (Sonnet at most; ``--translate-provider agy-claude`` puts the Antigravity
CLI first), and the glossary of a fiction book is built first on Claude Sonnet. A multi-volume file is split per
volume. See docs/BOOK_AGENT.md.

    python translate_book.py                    # translate everything in books/inbox
    python translate_book.py -i novel.epub      # one book
    python translate_book.py --glossary-only    # review the glossary first
    python translate_book.py --watch            # worker mode (cloud)

Uploads go in ``books/inbox``; each book then gets its own folder under
``books/`` with ``source/``, ``translation/`` and ``book.json``; ``books/INDEX.md``
lists them all.
"""
import argparse
import logging
import sys
import time

from pathlib import Path

from dotenv import load_dotenv

# The settings file of the repository, whatever the working directory (the cloud worker runs
# from its data folder). Variables already set in the environment win.
load_dotenv(Path(__file__).resolve().parent / ".env")

from src.utils.console import ensure_utf8_stdio  # noqa: E402

ensure_utf8_stdio()
logging.getLogger("httpx").setLevel(logging.WARNING)

from src.core.agent import AgentOptions, BookAgent, library, parse_volume_selection  # noqa: E402
from src.core.agent.routing import (  # noqa: E402
    DEFAULT_TRANSLATE_PROVIDER, PROFILES, PROVIDER_AGY_CLAUDE, PROVIDER_CLAUDE, TRANSLATE_PROVIDERS,
    check_allowed)
from src.core.llm.providers.agy import find_agy_executable  # noqa: E402
from src.core.llm.providers.claude_cli import find_claude_executable  # noqa: E402

WATCH_POLL_SECONDS = 30
WATCH_SETTLE_SECONDS = 15        # an upload untouched this long is complete
WATCH_RETRY_SECONDS = 30 * 60    # wait before retrying an unfinished book


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Translate books (EPUB, TXT, or a folder of volumes) into Indonesian by default, "
                    "with the claude CLI. See docs/BOOK_AGENT.md.")
    p.add_argument("-i", "--input",
                   help="A book file, or a folder holding one file per volume. Default: "
                        "everything in books/inbox.")
    p.add_argument("--watch", action="store_true",
                   help="Worker mode: keep translating whatever lands in books/inbox, forever, "
                        "and retry unfinished books.")
    p.add_argument("--books-dir", help="Library folder (default: ./books, or $BOOKS_DIR).")
    p.add_argument("--workdir", help="Use this book folder instead of books/<book name>.")
    p.add_argument("-tl", "--target-lang", default="Indonesian",
                   help="Target language (default: Indonesian).")
    p.add_argument("-sl", "--source-lang", help="Source language (default: detected).")
    p.add_argument("--translate-provider", choices=TRANSLATE_PROVIDERS,
                   default=DEFAULT_TRANSLATE_PROVIDER,
                   help="claude-cli (default for now): claude only. agy-claude: agy first, claude "
                        "CLI as backup. agy: agy only.")
    p.add_argument("--profile", choices=PROFILES, default="balanced",
                   help="Quality/cost trade-off for model routing (default: balanced).")
    p.add_argument("-m", "--model",
                   help="Force the primary translation model (an `agy models` id, or a claude "
                        "alias with --translate-provider claude-cli). opus is refused.")
    p.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"],
                   help="--effort level passed to the CLIs (default: their own).")
    fic = p.add_mutually_exclusive_group()
    fic.add_argument("--fiction", dest="fiction", action="store_true", default=None,
                     help="Treat the book as fiction (glossary first), whatever the classifier says.")
    fic.add_argument("--non-fiction", dest="fiction", action="store_false",
                     help="Treat the book as non-fiction (no glossary).")
    p.add_argument("--glossary", help="Use this glossary file (.json/.csv) instead of building one.")
    p.add_argument("--glossary-only", "--prepare-only", dest="glossary_only", action="store_true",
                   help="Stop after the preparation (glossary.json, style.md, calibration.md) so "
                        "it can be reviewed and edited.")
    p.add_argument("--no-split", action="store_true", help="Do not split the book into volumes.")
    p.add_argument("--redo", action="store_true",
                   help="Translate the volumes again (all, or those of --volumes) with the current "
                        "glossary.json and style.md; the old files are kept in <book>/previous/.")
    p.add_argument("--volume-pattern", help="Regex a TOC entry / heading must match to open a volume.")
    p.add_argument("--volumes", help="Translate only these volumes, e.g. 1-3,5.")
    p.add_argument("--translate-title", dest="keep_original_title", action="store_false",
                   help="Translate the book title. By default the title stays in the source "
                        "language, in the EPUB metadata and the series name.")
    p.add_argument("--refresh-metadata", action="store_true",
                   help="Do not translate: redo the metadata (title, series, attribution) of "
                        "the volumes already translated.")
    refine = p.add_mutually_exclusive_group()
    refine.add_argument("--refine", dest="refine", action="store_true", default=None,
                        help="Polish pass after translation. Default: on for fiction.")
    refine.add_argument("--no-refine", dest="refine", action="store_false",
                        help="Skip the polish pass (halves the number of calls).")
    p.add_argument("--chunk-tokens", type=int, default=1800,
                   help="Tokens per translation chunk (default: 1800).")
    p.add_argument("--parallel", type=int, default=1,
                   help="Concurrent chunks per volume (default: 1; >1 drops cross-chunk context).")
    return p


def _options(args, input_path: Path, root: Path) -> AgentOptions:
    return AgentOptions(
        input_path=input_path, books_dir=root,
        workdir=Path(args.workdir) if args.workdir else None,
        target_language=args.target_lang, source_language=args.source_lang,
        profile=args.profile, translate_provider=args.translate_provider, model=args.model,
        glossary_path=Path(args.glossary) if args.glossary else None, fiction=args.fiction,
        split=not args.no_split, volume_pattern=args.volume_pattern,
        only_volumes=parse_volume_selection(args.volumes) if args.volumes else None,
        redo=args.redo,
        glossary_only=args.glossary_only, refine=args.refine,
        keep_original_title=args.keep_original_title, refresh_metadata=args.refresh_metadata,
        max_tokens_per_chunk=args.chunk_tokens, parallel=args.parallel, effort=args.effort)


def run_book(args, input_path: Path, root: Path) -> int:
    def say(message: str) -> None:
        print(f"[agent] {message}", flush=True)
    return BookAgent(_options(args, input_path, root), say=say).run()


def _settled(path: Path) -> bool:
    files = [f for f in path.rglob("*") if f.is_file()] if path.is_dir() else [path]
    newest = max((f.stat().st_mtime for f in files), default=path.stat().st_mtime)
    return time.time() - newest >= WATCH_SETTLE_SECONDS


def process_pending(args, root: Path, retry_at: dict, only_settled: bool) -> int:
    """One pass over the inbox and the unfinished books. Returns the worst exit code."""
    worst = 0
    queue = library.list_inbox(root) + library.unfinished_books(root)
    for entry in queue:
        key = str(entry)
        if retry_at.get(key, 0) > time.time():
            continue
        if only_settled and entry.is_relative_to(library.inbox_dir(root)) and not _settled(entry):
            continue
        code = run_book(args, entry, root)
        if code == 0:
            retry_at.pop(key, None)
        else:
            worst = code
            retry_at[key] = time.time() + WATCH_RETRY_SECONDS
    return worst


def _check_tools(parser, provider: str) -> None:
    needs_agy = provider in (PROVIDER_AGY_CLAUDE, "agy")
    if needs_agy and not find_agy_executable():
        parser.error("the 'agy' CLI was not found: install it or set AGY_PATH")
    if not find_claude_executable():
        if provider == PROVIDER_CLAUDE:
            parser.error("the 'claude' CLI was not found: install it or set CLAUDE_CLI_PATH")
        print("[agent] warning: the 'claude' CLI was not found; fiction glossaries and the "
              "claude backup are unavailable", file=sys.stderr)


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.model:
        try:
            check_allowed(args.model)
        except ValueError as exc:
            parser.error(str(exc))
    _check_tools(parser, args.translate_provider)

    root = library.books_root(args.books_dir)
    (library.inbox_dir(root)).mkdir(parents=True, exist_ok=True)

    if args.input:
        input_path = Path(args.input)
        if not input_path.exists():
            parser.error(f"input not found: {input_path}")
        return run_book(args, input_path, root)

    retry_at: dict = {}
    if args.watch:
        print(f"[agent] watching {library.inbox_dir(root)} (Ctrl+C to stop)", flush=True)
        try:
            while True:
                process_pending(args, root, retry_at, only_settled=True)
                time.sleep(WATCH_POLL_SECONDS)
        except KeyboardInterrupt:
            return 0
    if not (library.list_inbox(root) or library.unfinished_books(root)):
        print(f"[agent] nothing to do: put books in {library.inbox_dir(root)}", flush=True)
        return 0
    return process_pending(args, root, retry_at, only_settled=False)


if __name__ == "__main__":
    sys.exit(main())
