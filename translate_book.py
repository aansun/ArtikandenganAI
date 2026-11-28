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
import json
import logging
import os
import sys
import time
from dataclasses import asdict

from pathlib import Path

from dotenv import load_dotenv

# The settings file of the repository, whatever the working directory (the cloud worker runs
# from its data folder). Variables already set in the environment win.
load_dotenv(Path(__file__).resolve().parent / ".env")

from src.utils.console import ensure_utf8_stdio  # noqa: E402

ensure_utf8_stdio()
logging.getLogger("httpx").setLevel(logging.WARNING)

from src.core.agent import AgentOptions, BookAgent, engines as engines_mod, library, parse_volume_selection  # noqa: E402
from src.core.agent import kindle, kindle_log, xteink  # noqa: E402
from src.core.agent import log_report  # noqa: E402
from src.core.agent import models as model_list  # noqa: E402
from src.core.llm import activity  # noqa: E402
from src.core.agent.routing import (  # noqa: E402
    DEFAULT_TRANSLATE_PROVIDER, PROFILES, PROVIDER_AGY_CLAUDE, PROVIDER_AUTO, PROVIDER_CLAUDE,
    TRANSLATE_PROVIDERS, check_allowed)
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
                   help="auto (default): every active engine of claude, codex, agy and opencode; "
                        "the first is the main one and the others are backups. Or force one: "
                        "claude-cli, codex, agy, or agy-claude (agy first, claude as backup).")
    p.add_argument("--engines", default=os.getenv("AGENT_ENGINES", ""),
                   help="With auto: the engines to consider and their order, e.g. codex,claude "
                        "(default: claude,codex,agy,opencode, or $AGENT_ENGINES).")
    p.add_argument("--engine-model", action="append", default=[], metavar="ENGINE=MODEL",
                   help="With auto: use this model for an engine instead of the recommended one "
                        "(may be given once per engine; see --list-models). opus and fable are "
                        "refused.")
    p.add_argument("--list-models", action="store_true",
                   help="Print the recommended model and the choices of each installed engine as "
                        "JSON and exit.")
    p.add_argument("--one-engine", action="store_true",
                   help="With auto: use only the book's own engine and model; when its usage limit "
                        "is reached the run stops with exit code 3 until it can go on. Default: "
                        "the next engine takes over, following a sample of the book's voice.")
    p.add_argument("--refresh-engines", action="store_true",
                   help="Probe the engines again instead of using the result kept a few minutes.")
    p.add_argument("--no-log", dest="log", action="store_false",
                   help="Do not keep the local activity log (engines, models, speed and quality "
                        "signals, in <books>/_activity-log). Also off with AGENT_LOG=0.")
    p.add_argument("--log-report", action="store_true",
                   help="Print a summary of the activity log as Markdown and exit.")
    p.add_argument("--check", metavar="BOOK_FOLDER",
                   help="Check the finished translation of a book folder again (no model is asked), "
                        "write its check.json and exit.")
    p.add_argument("--repair", metavar="BOOK_FOLDER",
                   help="Mend a finished translation without asking a model (paragraphs cut inside "
                        "a sentence, front-matter contents entries), check it again and exit. The "
                        "old files are kept in <book>/previous/.")
    p.add_argument("--kindle-check", metavar="BOOK_FOLDER",
                   help="Print, as JSON, what a Kindle would read from each finished volume, what is "
                        "wrong with it and whether it was sent.")
    p.add_argument("--kindle-send", metavar="BOOK_FOLDER",
                   help="E-mail the finished volumes (all, or --volumes) to your Kindle, skipping "
                        "those already sent unchanged. Settings come from the environment: "
                        "KINDLE_TO, KINDLE_FROM, KINDLE_SMTP_HOST, KINDLE_SMTP_PORT, "
                        "KINDLE_SMTP_USER, KINDLE_SMTP_PASSWORD (never from the command line).")
    p.add_argument("--resend", action="store_true",
                   help="With --kindle-send or --xteink-send: send even a file that was "
                        "already sent (on the reader: replace a file of the same name).")
    p.add_argument("--xteink-check", metavar="BOOK_FOLDER",
                   help="Print, as JSON, whether each finished volume was sent to the e-ink reader.")
    p.add_argument("--xteink-send", metavar="BOOK_FOLDER",
                   help="Send the finished volumes (all, or --volumes) to an Xteink reader running "
                        "CrossPoint, over the local network.")
    p.add_argument("--xteink-test", action="store_true",
                   help="Ask the reader who it is and send nothing.")
    p.add_argument("--xteink-address", default=xteink.ADDRESS, metavar="ADDRESS",
                   help="The reader's name or IP address (default: %(default)s).")
    p.add_argument("--xteink-folder", default=xteink.FOLDER, metavar="FOLDER",
                   help="The folder on the reader's card (default: %(default)s).")
    p.add_argument("--xteink-as-is", action="store_true",
                   help="Send the file as it is, without preparing its pictures and fonts for e-ink.")
    p.add_argument("--kindle-test", action="store_true",
                   help="Sign in to the mail server with the Kindle settings and send nothing.")
    p.add_argument("--detect", action="store_true",
                   help="Print the engines found on this machine as JSON and exit.")
    p.add_argument("--inspect", metavar="FILE",
                   help="Print what the app shows for a book (title, volumes, fiction or not, "
                        "estimated time) as JSON and exit.")
    p.add_argument("--selfcheck", action="store_true",
                   help="Import every module a run needs (some are only imported when a book is translated) "
                        "and exit 0 if they are all there. Used after installing the engine.")
    p.add_argument("--set-metadata", metavar="BOOK_FOLDER",
                   help="Set one metadata field of every translated volume of a book and exit "
                        "(with --field and --value; an empty --value removes the field).")
    p.add_argument("--field", help="Metadata field for --set-metadata: title, creator, description, "
                                   "publisher, date, subject, language or series.")
    p.add_argument("--value", default="", help="New value for --set-metadata.")
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
    p.add_argument("--style", choices=["auto", "formal", "santai", "sastra"], default="auto",
                   help="Translation style: auto picks the one recommended from the book's content "
                        "(default); formal, santai (casual) or sastra (literary) forces it.")
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
    p.add_argument("--polish-only", action="store_true",
                   help="Do not translate: the input (-i) is an EPUB already in the target "
                        "language. Polish it, then check it against the input. The input file is "
                        "left as it is.")
    p.add_argument("--chunk-tokens", type=int, default=1800,
                   help="Tokens per translation chunk (default: 1800).")
    p.add_argument("--parallel", type=int, default=1,
                   help="Concurrent requests while translating (default: 1). More is faster and uses "
                        "the usage limit faster; the polish pass stays sequential. EPUB chunks are "
                        "translated independently either way; plain text and PDF lose the preceding "
                        "passage as context.")
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
        engines=[e.strip() for e in args.engines.split(",") if e.strip()] or None,
        refresh_engines=args.refresh_engines, style=args.style,
        glossary_only=args.glossary_only, refine=args.refine,
        keep_original_title=args.keep_original_title, refresh_metadata=args.refresh_metadata,
        max_tokens_per_chunk=args.chunk_tokens, parallel=args.parallel, effort=args.effort,
        polish_only=args.polish_only, keep_model=args.one_engine,
        engine_models=_engine_models(args.engine_model))


def _engine_models(given) -> dict:
    """``["agy=model", ...]`` as ``{engine: model}``; raises ValueError on one that is not allowed."""
    chosen = {}
    for item in given:
        engine, _, model = item.partition("=")
        engine, model = engine.strip(), model.strip()
        if engine not in engines_mod.DEFAULT_ORDER or not model_list.allowed_choice(model):
            raise ValueError(f"--engine-model {item}: expected <engine>=<model>, with an engine of "
                             f"{', '.join(engines_mod.DEFAULT_ORDER)} and a model that may be used "
                             "(no opus, fable, free or preview model)")
        chosen[engine] = model
    return chosen


def _say(message: str) -> None:
    print(f"[agent] {message}", flush=True)


def run_book(args, input_path: Path, root: Path) -> int:
    return BookAgent(_options(args, input_path, root), say=_say).run()


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


def _check(parser, args, root) -> int:
    folder = Path(args.check)
    if not (folder / "state.json").is_file():
        parser.error(f"not a book folder: {folder}")
    source = next(iter(sorted((folder / "source").glob("*"))), folder)
    agent = BookAgent(AgentOptions(input_path=source, books_dir=root, workdir=folder), say=_say)
    return agent.check_only()


def _repair(parser, args, root) -> int:
    folder = Path(args.repair)
    if not (folder / "state.json").is_file():
        parser.error(f"not a book folder: {folder}")
    source = next(iter(sorted((folder / "source").glob("*"))), folder)
    return BookAgent(AgentOptions(input_path=source, books_dir=root, workdir=folder), say=_say).repair()


def _kindle(parser, args, root) -> int:
    """The Kindle commands: one line of JSON on stdout; exit 0 only when all went well.
    A test and a send are written to the Kindle log in the library."""
    started = time.monotonic()
    action = "test" if args.kindle_test else ("send" if args.kindle_send else "")

    def answer(data: dict, code: int, stage: str = "") -> int:
        if action:
            kindle_log.record(root, app_version=os.getenv("NNAI_APP_VERSION", ""),
                              password=(os.getenv("KINDLE_SMTP_PASSWORD") or "").strip(),
                              action=action, **kindle_log.settings_facts(os.environ),
                              ok=bool(data.get("ok")), stage=stage, error=data.get("error"),
                              detail=data.get("detail"),
                              volumes=[dict(r) for r in data.get("results", [])],
                              seconds=round(time.monotonic() - started, 1))
        print(json.dumps(data, ensure_ascii=False))
        return code

    try:
        if args.kindle_test:
            kindle.connect(kindle.Settings.from_environment()).quit()
            return answer({"ok": True}, 0)
        folder = Path(args.kindle_check or args.kindle_send)
        if not (folder / "book.json").is_file():
            parser.error(f"not a book folder: {folder}")
        if args.kindle_check:
            return answer(kindle.run_check(folder), 0)
        results = kindle.send(folder, kindle.Settings.from_environment(), resend=args.resend,
                              volumes=parse_volume_selection(args.volumes) if args.volumes else None)
        done = all(r["result"] in ("sent", "already") for r in results) and bool(results)
        return answer({"ok": done, "results": results}, 0 if done else 1)
    except kindle.KindleError as exc:
        return answer({"ok": False, "error": exc.code, "detail": exc.detail}, 1, exc.stage)


def _xteink(parser, args, root) -> int:
    """The e-ink reader commands: one line of JSON on stdout; exit 0 only when all went well."""
    started = time.monotonic()
    action = "test" if args.xteink_test else ("send" if args.xteink_send else "")
    found: dict = {}

    def answer(data: dict, code: int) -> int:
        if action:
            kindle_log.record(root, app_version=os.getenv("NNAI_APP_VERSION", ""), file="xteink.jsonl",
                              action=action, address=args.xteink_address[:200], device=found.get("device"),
                              firmware=f"{found.get('firmware', '')} {found.get('version', '')}".strip(),
                              ok=bool(data.get("ok")), error=data.get("error"), detail=data.get("detail"),
                              volumes=[dict(r) for r in data.get("results", [])],
                              seconds=round(time.monotonic() - started, 1))
        print(json.dumps(data, ensure_ascii=False))
        return code

    try:
        if args.xteink_test:
            xteink.parse_folder(args.xteink_folder)
            found.update(xteink.Reader(args.xteink_address).status())
            return answer({"ok": True, **found}, 0)
        folder = Path(args.xteink_check or args.xteink_send)
        if not (folder / "book.json").is_file():
            parser.error(f"not a book folder: {folder}")
        if args.xteink_check:
            return answer(xteink.run_check(folder), 0)
        reader, results = xteink.send(
            folder, args.xteink_address, args.xteink_folder, resend=args.resend, prepare=not args.xteink_as_is,
            volumes=parse_volume_selection(args.volumes) if args.volumes else None)
        found.update(reader)
        done = all(r["result"] in ("sent", "already") for r in results) and bool(results)
        return answer({"ok": done, "results": results, **found}, 0 if done else 1)
    except xteink.XteinkError as exc:
        return answer({"ok": False, "error": exc.code, "detail": exc.detail}, 1)


def _check_tools(parser, provider: str) -> None:
    if provider == PROVIDER_AUTO:
        return  # the engines are detected, and reported, when the run starts
    needs_agy = provider in (PROVIDER_AGY_CLAUDE, "agy")
    if needs_agy and not find_agy_executable():
        parser.error("the 'agy' CLI was not found: install it or set AGY_PATH")
    if not find_claude_executable():
        if provider == PROVIDER_CLAUDE:
            parser.error("the 'claude' CLI was not found: install it or set CLAUDE_CLI_PATH")
        print("[agent] warning: the 'claude' CLI was not found; fiction glossaries and the "
              "claude backup are unavailable", file=sys.stderr)


def _inspect(parser, args, root, order) -> int:
    from src.core.agent.inspect_book import inspect_book
    from src.core.llm import ProviderConfig, create_llm_provider
    activity.set_phase("inspect")
    path = Path(args.inspect)
    if not path.exists():
        parser.error(f"not found: {path}")
    provider = None
    active = [e for e in engines_mod.detect_engines(order, cache_path=root / ".engines.json",
                                                    refresh=args.refresh_engines,
                                                    chosen=_engine_models(args.engine_model)) if e.active]
    if active:
        provider = create_llm_provider(ProviderConfig(provider="chain", model="", options={
            "chain": engines_mod.chain_for(active, "haiku")}))
    print(json.dumps(inspect_book(path, provider, target_language=args.target_lang), ensure_ascii=False))
    return 0


def _selfcheck() -> int:
    """A packaged engine can miss a file that only a real translation imports (``--help`` would not notice)."""
    import importlib
    names = ["translate", "src.core.job.runner", "src.core.agent.pipeline", "src.core.agent.engines",
             "src.core.agent.glossary_builder", "src.core.agent.style", "src.core.agent.qa",
             "src.core.agent.epub_metadata", "src.core.agent.intake", "src.core.agent.inspect_book",
             "src.core.llm.providers.claude_cli", "src.core.llm.providers.codex_cli",
             "src.core.llm.providers.agy", "src.core.llm.providers.opencode_cli",
             "src.core.llm.providers.chain", "src.core.agent.models",
             "src.core.agent.log_report", "src.core.llm.activity", "src.core.agent.series",
             "src.core.agent.stages", "src.core.refine.chunk_cache", "src.core.agent.final_check", "src.core.llm.voice",
             "src.core.agent.layout_repair", "src.core.agent.kindle",
             "src.core.agent.kindle_log",
             "src.core.agent.xteink", "src.core.agent.xteink_optimize"]
    missing = []
    for name in names:
        try:
            importlib.import_module(name)
        except Exception as exc:  # noqa: BLE001 - any failure to import is what we report
            missing.append(f"{name}: {exc}")
    if missing:
        print("[agent] selfcheck failed:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 1
    print("[agent] selfcheck ok", flush=True)
    return 0


def _set_metadata(parser, args, root) -> int:
    from src.core.agent.epub_metadata import edit_field
    folder = Path(args.set_metadata)
    folder = folder if folder.is_absolute() else root / folder
    book = library.read_book(folder)
    if not book or not args.field:
        parser.error("--set-metadata needs a book folder with a book.json, and --field")
    volumes = book.get("volumes", [])
    for vol in volumes:
        output = Path(vol.get("output", ""))
        if output.suffix.lower() == ".epub" and output.exists():
            edit_field(output, args.field, args.value, volume=int(vol.get("index", 0)),
                       volume_count=len(volumes))
    print(f"[agent] {args.field} updated in {len(volumes)} volume(s)", flush=True)
    return 0


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.model:
        try:
            check_allowed(args.model)
        except ValueError as exc:
            parser.error(str(exc))
    try:
        chosen = _engine_models(args.engine_model)
    except ValueError as exc:
        parser.error(str(exc))
    if args.polish_only:
        if not args.input:
            parser.error("--polish-only needs -i with the EPUB to polish")
        if args.refine is False or args.refresh_metadata:
            parser.error("--polish-only cannot be combined with --no-refine or --refresh-metadata")
    root = library.books_root(args.books_dir)
    order = [e.strip() for e in args.engines.split(",") if e.strip()] or None

    if args.selfcheck:
        return _selfcheck()
    if args.log_report:
        print(log_report.summary(root / log_report.FOLDER), end="")
        return 0
    keep_log = args.log and os.getenv("AGENT_LOG", "").strip() != "0"
    activity.configure(root / log_report.FOLDER if keep_log else None,
                       app_version=os.getenv("NNAI_APP_VERSION", ""))
    if args.kindle_check or args.kindle_send or args.kindle_test:
        return _kindle(parser, args, root)
    if args.xteink_check or args.xteink_send or args.xteink_test:
        return _xteink(parser, args, root)
    if args.check:
        return _check(parser, args, root)
    if args.repair:
        return _repair(parser, args, root)
    if args.detect:
        found = engines_mod.detect_engines(order, cache_path=root / ".engines.json",
                                           refresh=args.refresh_engines, chosen=chosen)
        print(json.dumps([asdict(e) for e in found], ensure_ascii=False))
        return 0
    if args.list_models:
        print(json.dumps(engines_mod.model_choices(order), ensure_ascii=False))
        return 0
    if args.inspect:
        return _inspect(parser, args, root, order)
    if args.set_metadata:
        return _set_metadata(parser, args, root)

    _check_tools(parser, args.translate_provider)
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
