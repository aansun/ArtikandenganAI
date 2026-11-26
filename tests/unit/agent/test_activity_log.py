"""The local activity log: what it records, what it never records, and its summary."""
import json

import translate_book
from src.core.agent import log_report
from src.core.llm import activity
from src.core.llm.exceptions import ProviderError
from tests.unit.agent.test_pipeline_e2e import (book_dir, claude_out_of_quota_for, env,  # noqa: F401
                                                upload)


def folder(env):  # noqa: F811
    return env / "books" / log_report.FOLDER


def test_a_translation_is_logged_with_models_speed_and_quality(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--fiction"]) == 0
    records = log_report.read_records(folder(env))
    kinds = {r["event"] for r in records}
    assert kinds == {"engines", "request", "volume"}
    assert len({r["run"] for r in records}) == 1

    requests = [r for r in records if r["event"] == "request"]
    assert {"classify", "glossary", "style", "calibrate", "translate", "refine"} <= {r["phase"] for r in requests}
    translated = next(r for r in requests if r["phase"] == "translate")
    assert translated["engine"] == "claude-cli" and translated["model"] == "sonnet" and translated["ok"]
    assert translated["seconds"] >= 0 and translated["prompt_chars"] > 100 and translated["answer_chars"] > 0

    volumes = [r for r in records if r["event"] == "volume"]
    assert len(volumes) == 2
    first = volumes[0]
    assert first["status"] == "completed" and first["polish"] and first["chunks_total"] >= 1
    assert first["chunks_failed"] == 0 and first["resumed"] is False and "qa_flags" in first
    assert first["models"]["translate"]["claude-cli/sonnet"] >= 1
    assert first["models"]["refine"]["claude-cli/sonnet"] >= 1

    check = next(r for r in records if r["event"] == "engines")["engines"][0]
    assert check == {"engine": "claude", "active": True, "state": "ok",
                     "models": {"sonnet": "sonnet", "haiku": "haiku"}}


def test_nothing_of_the_book_is_logged(env):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--fiction"]) == 0
    raw = "".join(p.read_text(encoding="utf-8") for p in folder(env).iterdir())
    for secret in ("Aldric", "Lyra", "Fake Saga", "Saga Palsu", "Jane Author", "saga", str(env), "<TRANSLATION>"):
        assert secret not in raw, secret


def test_the_log_can_be_switched_off(env, monkeypatch):  # noqa: F811
    upload(env, volumes=1, chapters=1)
    assert translate_book.main(["--non-fiction", "--no-refine", "--no-log"]) == 0
    assert not folder(env).exists()
    monkeypatch.setenv("AGENT_LOG", "0")
    assert translate_book.main(["--detect", "--refresh-engines"]) == 0
    assert not folder(env).exists()


def test_failures_are_logged_as_a_category_only(env, monkeypatch):  # noqa: F811
    upload(env, volumes=1, chapters=1)
    claude_out_of_quota_for(env, monkeypatch, "</TRANSLATION>")
    translate_book.main(["--non-fiction", "--no-refine"])
    records = log_report.read_records(folder(env))
    failed = [r for r in records if r["event"] == "request" and not r["ok"]]
    assert failed and {r["error"] for r in failed} == {"rate_limit"}
    assert "Usage limit" not in "".join(p.read_text() for p in folder(env).iterdir())
    assert [r["status"] for r in records if r["event"] == "volume"] == ["rate_limited"]
    assert book_dir(env).exists()


def test_error_categories():
    assert activity.error_category(ProviderError("x", status_code=401)) == "auth"
    assert activity.error_category(ProviderError("x", status_code=400)) == "rejected"
    assert activity.error_category(ProviderError("x", context_overflow=True)) == "context_overflow"
    assert activity.error_category(ProviderError("cli timed out after 5s", transport=True)) == "timeout"
    assert activity.error_category(ProviderError("boom")) == "other"


def test_only_known_fields_are_written_and_a_broken_folder_is_harmless(tmp_path):
    activity.configure(tmp_path / "log", app_version="9.9.9")
    activity.record("request", engine="claude-cli", ok=True, text="a secret passage", path="/Users/x")
    written = next((tmp_path / "log").iterdir()).read_text()
    assert "claude-cli" in written and "secret" not in written and "/Users" not in written
    assert json.loads(written)["app"] == "9.9.9"
    blocked = tmp_path / "file"
    blocked.write_text("not a folder")
    activity.configure(blocked)
    activity.record("request", engine="claude-cli", ok=True)          # no exception
    activity.configure(None)


def test_the_report_summarises_speed_and_quality_per_model(env, capsys):  # noqa: F811
    upload(env, volumes=2, chapters=1)
    assert translate_book.main(["--fiction"]) == 0
    with open(next(folder(env).glob("activity-*.jsonl")), "a", encoding="utf-8") as f:
        f.write("damaged line\n")
    capsys.readouterr()
    assert translate_book.main(["--log-report"]) == 0
    report = capsys.readouterr().out
    assert report.startswith("# Translation log summary")
    assert "| claude-cli/sonnet | fiction | Indonesian | on | 1 | 2 | 2 |" in report
    assert "| claude-cli / sonnet | translate |" in report and "| claude | sonnet |" in report
    assert "Aldric" not in report and str(env) not in report


def test_an_empty_log_says_so(env, capsys):  # noqa: F811
    assert translate_book.main(["--log-report"]) == 0
    assert "The log is empty." in capsys.readouterr().out
