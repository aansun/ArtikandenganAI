"""
Summarise the translation activity log (see ``src/core/llm/activity.py``) as Markdown.

The summary is what a user may choose to share: counts and speeds per model, and the quality
signals of translated volumes. These are automatic signals (retries, untranslated chunks,
check flags), not a judgement of the prose.
"""

import json
from collections import Counter, defaultdict
from pathlib import Path
from statistics import median
from typing import Dict, Iterable, List

from src.core.llm.activity import FIELDS, FILE_PATTERN

#: The folder of the log inside the library.
FOLDER = "_activity-log"


def read_records(folder: Path) -> List[dict]:
    """Every readable record of the log, oldest file first; damaged lines are skipped."""
    records: List[dict] = []
    for path in sorted(folder.glob(FILE_PATTERN)) if folder.is_dir() else []:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict) and entry.get("event") in FIELDS:
                records.append(entry)
    return records


def _cell(value) -> str:
    return str(value).replace("|", "/").replace("\n", " ")


def _table(header: List[str], rows: Iterable[List]) -> List[str]:
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return lines + ["| " + " | ".join(_cell(c) for c in row) + " |" for row in rows]


def _requests(records: List[dict]) -> List[str]:
    groups: Dict[tuple, List[dict]] = defaultdict(list)
    for r in records:
        if r["event"] == "request":
            key = (f"{r.get('engine', '?')} / {r.get('model') or '?'}", r.get("phase") or "other")
            groups[key].append(r)
    rows = []
    for (model, step), found in sorted(groups.items()):
        answered = [r for r in found if r.get("ok")]
        seconds = sum(r.get("seconds") or 0 for r in answered)
        speed = sum(r.get("answer_chars") or 0 for r in answered) / seconds if seconds else 0
        failures = Counter(r.get("error") or "other" for r in found if not r.get("ok"))
        rows.append([
            model, step, len(found), f"{100 * len(answered) / len(found):.0f}%",
            f"{median([r.get('seconds') or 0 for r in answered]):.1f}" if answered else "-",
            f"{speed:.0f}" if speed else "-",
            ", ".join(f"{name} {count}" for name, count in failures.most_common()) or "-"])
    if not rows:
        return ["No request recorded yet."]
    return _table(["Engine / model", "Step", "Requests", "Answered", "Median seconds",
                   "Answer characters per second", "Failures"], rows)


def _main_model(volume: dict) -> str:
    """The model that answered most of a volume's translation requests."""
    answered = (volume.get("models") or {}).get("translate") or {}
    if not answered:
        return "-"
    model, count = max(answered.items(), key=lambda item: item[1])
    share = count / sum(answered.values())
    return model if share >= 0.9 else f"{model} (with backups)"


def _volumes(records: List[dict]) -> List[str]:
    groups: Dict[tuple, List[dict]] = defaultdict(list)
    for r in records:
        if r["event"] == "volume":
            groups[(_main_model(r), r.get("book_class") or "?", r.get("target_language") or "?",
                    "on" if r.get("polish") else "off", r.get("parallel") or 1)].append(r)

    def total(found: List[dict], name: str) -> int:
        return sum(v.get(name) or 0 for v in found)

    rows = []
    for key, found in sorted(groups.items(), key=lambda item: str(item[0])):
        done = [v for v in found if v.get("status") == "completed"]
        whole = [v.get("seconds") or 0 for v in done if not v.get("resumed")]
        flagged = [v["qa_flags"] for v in done if v.get("qa_flags") is not None]
        rows.append([
            *key, len(found), len(done),
            f"{median(whole) / 60:.1f}" if whole else "-",
            total(found, "chunks_total"), total(found, "chunks_retried"),
            total(found, "chunks_untranslated"), total(found, "chunks_failed"),
            total(found, "chunks_token_aligned"),
            f"{sum(flagged) / len(flagged):.1f}" if flagged else "-"])
    if not rows:
        return ["No translated volume recorded yet."]
    return _table(["Main model", "Book class", "Language", "Polish", "At once", "Runs", "Completed",
                   "Median minutes (uninterrupted)", "Chunks", "Retried", "Left untranslated",
                   "Failed", "Layout approximated", "Check flags per volume"], rows)


def _engines(records: List[dict]) -> List[str]:
    checks: Dict[tuple, Counter] = defaultdict(Counter)
    for r in records:
        if r["event"] != "engines":
            continue
        for e in r.get("engines") or []:
            model = (e.get("models") or {}).get("sonnet") or "-"
            checks[(e.get("engine", "?"), model)][e.get("state") or "other"] += 1
    rows = [[engine, model, sum(states.values()), states["ok"],
             ", ".join(f"{s} {n}" for s, n in states.most_common() if s != "ok") or "-"]
            for (engine, model), states in sorted(checks.items())]
    if not rows:
        return ["No engine check recorded yet."]
    return _table(["Engine", "Model for novels", "Checks", "Usable", "Otherwise"], rows)


def summary(folder: Path) -> str:
    records = read_records(folder)
    if not records:
        return "# Translation log summary\n\nThe log is empty.\n"
    times = sorted(r.get("time") or "" for r in records)
    versions = sorted({r["app"] for r in records if r.get("app")})
    lines = ["# Translation log summary", "",
             f"Period: {times[0][:10]} to {times[-1][:10]}. "
             f"Runs: {len({r.get('run') for r in records})}. "
             f"App version: {', '.join(versions) or 'not recorded'}.", "",
             "No book text, title, file name or account detail is part of this summary.", "",
             "## Translated volumes", "", *_volumes(records), "",
             "## Requests by model and step", "", *_requests(records), "",
             "## Engine checks", "", *_engines(records), "",
             "Quality columns are automatic signals, not a judgement of the translation."]
    return "\n".join(lines) + "\n"
