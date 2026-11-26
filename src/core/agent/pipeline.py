"""
The book translator agent.

One run takes a book (a file, or a folder of volume files) through:

    1. adopt     move the upload into its own folder under books/ (library.py)
    2. split     one file per volume (multi-volume EPUB / TXT; see volumes.py)
    3. classify  genre, source language, titles (one cheap call on excerpts)
    4. route     pick the models from the genre (routing.py)
    5. bible     fiction only: one shared glossary built from ALL the text of every
                 volume BEFORE any translation starts, saved as editable JSON
    6. style     ``style.md``: the register, narration and dialogue decisions of the
                 book, written once; fiction also gets ``calibration.md`` (two
                 translated passages) to judge quality before the whole book
    7. translate each volume in order with the glossary and style guide, then (fiction)
                 a polish pass that must not change meaning, names or terms
    8. check     repair drifted names, complete the EPUB metadata, audit every document
                 against its source (qa_report.md), write book.json and books/INDEX.md

Before step 2 the boilerplate pages of an e-book (licence, transcriber's notes) are
removed from the working copy, so they are neither translated nor paid for.

Progress is kept in ``state.json`` and the engine's own checkpoints, so a stopped
run (usage limit, crash, redeploy) continues where it left off.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from src.core.agent import library
from src.core.agent.classifier import BookProfile, classify_book
from src.core.agent.epub_metadata import (
    GENRE_SUBJECTS_ID, audit_metadata, finalize_metadata, read_metadata, strip_volume_suffix)
from src.core.agent import engines as engines_mod
from src.core.agent.glossary_builder import build_glossary
from src.core.agent import qa as qa_mod
from src.core.agent import style as style_mod
from src.core.agent.intake import boilerplate_documents, clean_volume, remove_documents
from src.core.agent.routing import (
    DEFAULT_TRANSLATE_PROVIDER, GLOSSARY_MODEL, PROVIDER_AUTO, PROVIDER_CLAUDE, ModelChoice, choose_model, models_for)
from src.core.agent.volumes import Volume, slugify, split_into_volumes
from src.core.auto_prep import extract_source_text
from src.core.job import JobConfig, JobStatus
from src.core.llm import ProviderConfig, create_llm_provider

logger = logging.getLogger("core.agent")

DEFAULT_TARGET_LANGUAGE = "Indonesian"
#: Tier of the cheap classification call.
CLASSIFIER_TIER = "haiku"
#: The agent uses larger chunks than the engine's 450-token default, which is
#: meant for small local models: fewer CLI calls, more context per call.
DEFAULT_CHUNK_TOKENS = 1800

STATUS_PENDING = "pending"


@dataclass
class AgentOptions:
    input_path: Path
    books_dir: Path = field(default_factory=lambda: library.books_root())
    workdir: Optional[Path] = None             # default: books_dir/<book>
    target_language: str = DEFAULT_TARGET_LANGUAGE
    source_language: Optional[str] = None      # None: detected
    profile: str = "balanced"                  # economy | balanced | best
    translate_provider: str = DEFAULT_TRANSLATE_PROVIDER
    model: Optional[str] = None                # forces the primary translation model
    glossary_path: Optional[Path] = None       # a ready glossary: skip the build
    fiction: Optional[bool] = None             # None: decided by the classifier
    split: bool = True
    volume_pattern: Optional[str] = None
    only_volumes: Optional[Set[int]] = None
    redo: bool = False                         # translate the selected volumes again
    glossary_only: bool = False
    refine: Optional[bool] = None              # None: the polish pass runs for fiction
    keep_original_title: bool = True           # book title stays in the source language
    refresh_metadata: bool = False             # only redo the metadata of finished volumes
    max_tokens_per_chunk: int = DEFAULT_CHUNK_TOKENS
    parallel: int = 1
    effort: Optional[str] = None
    engines: Optional[List[str]] = None        # order / subset of claude, codex, agy (auto mode)
    refresh_engines: bool = False              # probe the engines again, ignoring the cache
    style: str = "auto"                        # auto | formal | santai | sastra


@dataclass
class VolumeState:
    index: int
    label: str
    source: str
    output: str
    status: str = STATUS_PENDING
    job_id: str = ""
    error: str = ""
    title: str = ""                 # translated title read back from the output
    finished_at: str = ""
    metadata_missing: List[str] = field(default_factory=list)
    qa_flags: int = 0               # documents flagged by the audit
    fixed_variants: Dict[str, str] = field(default_factory=dict)


@dataclass
class RunState:
    source: str = ""
    profile: Optional[Dict[str, Any]] = None
    model: str = ""
    backup_model: str = ""
    provider: str = ""
    glossary: str = ""
    glossary_terms: int = 0
    volumes: List[VolumeState] = field(default_factory=list)


def parse_volume_selection(text: str) -> Set[int]:
    """'1-3,5' -> {1, 2, 3, 5}."""
    chosen: Set[int] = set()
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = part.split("-", 1)
            chosen.update(range(int(low), int(high) + 1))
        else:
            chosen.add(int(part))
    return chosen


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class BookAgent:
    def __init__(self, options: AgentOptions, say=None):
        self.opt = options
        self.root = Path(options.books_dir).resolve()
        self.workdir = (Path(options.workdir) if options.workdir
                        else self.root / slugify(Path(options.input_path).stem)).resolve()
        self.say = say or (lambda message: logger.info(message))
        self.state_path = self.workdir / "state.json"
        self.state = self._load_state()
        self.profile: Optional[BookProfile] = None
        self.style_text = ""
        self.refine_on = False
        self._qa_results: Dict[int, list] = {}
        self.engines: List[engines_mod.Engine] = []
        self._engines_ready = False

    # ----------------------------------------------------------------- state
    def _load_state(self) -> RunState:
        if not self.state_path.exists():
            return RunState()
        try:
            raw = json.loads(self.state_path.read_text(encoding="utf-8"))
            volumes = [VolumeState(**v) for v in raw.pop("volumes", [])]
            return RunState(volumes=volumes, **raw)
        except (OSError, ValueError, TypeError):
            logger.warning("Ignoring unreadable %s", self.state_path)
            return RunState()

    def _save_state(self) -> None:
        self.workdir.mkdir(parents=True, exist_ok=True)
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self.state), ensure_ascii=False, indent=2),
                       encoding="utf-8")
        tmp.replace(self.state_path)
        self._write_book_json()
        library.write_index(self.root)

    def _write_book_json(self) -> None:
        """book.json: everything known about the book, for people and other tools."""
        profile = self.profile or (BookProfile(**self.state.profile) if self.state.profile else None)
        book = {
            "title": profile.title if profile else "",
            "title_translated": profile.title_translated if profile else "",
            "source_language": profile.source_language if profile else "",
            "target_language": self.opt.target_language,
            "genre": profile.genre if profile else "",
            "is_fiction": profile.is_fiction if profile else None,
            "classified_by": profile.method if profile else "",
            "source": self.state.source,
            "translate_provider": self.state.provider,
            "model": self.state.model,
            "backup_model": self.state.backup_model,
            "glossary": self.state.glossary,
            "glossary_terms": self.state.glossary_terms,
            "style_guide": str(self.workdir / "style.md") if (self.workdir / "style.md").exists() else "",
            "calibration": (str(self.workdir / "calibration.md")
                            if (self.workdir / "calibration.md").exists() else ""),
            "polish_pass": self.refine_on,
            "qa_report": (str(self.workdir / "qa_report.md")
                          if (self.workdir / "qa_report.md").exists() else ""),
            "updated_at": _now(),
            "volumes": [asdict(v) for v in self.state.volumes],
        }
        (self.workdir / "book.json").write_text(
            json.dumps(book, ensure_ascii=False, indent=2), encoding="utf-8")

    # ------------------------------------------------------------------ steps
    @property
    def auto(self) -> bool:
        return self.opt.translate_provider == PROVIDER_AUTO

    def _active_engines(self) -> List[engines_mod.Engine]:
        """The engines found on this machine (probed once per run, cached for a few minutes)."""
        if not self._engines_ready:
            self.engines = engines_mod.detect_engines(
                self.opt.engines, cache_path=self.root / ".engines.json",
                refresh=self.opt.refresh_engines)
            self._engines_ready = True
        return self.engines

    def _chain(self, tier: str):
        """A provider over every active engine, each at its model for ``tier``."""
        chain = engines_mod.chain_for(self._active_engines(), tier)
        options: Dict[str, Any] = {"chain": chain}
        if self.opt.effort:
            options["effort"] = self.opt.effort
        return create_llm_provider(ProviderConfig(provider="chain", model="", options=options))

    def _provider(self, provider: str, model: str, backup: Optional[str] = None):
        options: Dict[str, Any] = {}
        if backup:
            options["backup_model"] = backup
        if self.opt.effort:
            options["effort"] = self.opt.effort
        return create_llm_provider(ProviderConfig(provider=provider, model=model, options=options))

    def _split(self, source: Path) -> List[Volume]:
        """Volumes of this book; a previous run's split is reused as is."""
        known = self.state.volumes
        if known and all(Path(v.source).exists() for v in known):
            return [Volume(v.index, v.label, Path(v.source)) for v in known]
        volumes = split_into_volumes(
            source, self.workdir / library.VOLUMES,
            pattern=self.opt.volume_pattern, split=self.opt.split)
        cleaned = []
        for v in volumes:
            path, removed = clean_volume(v.path, self.workdir / library.VOLUMES)
            if removed:
                self.say(f"Intake: left out {len(removed)} boilerplate document(s) of {v.label}: "
                         + ", ".join(f"{name} ({why})" for name, why in removed))
            cleaned.append(Volume(v.index, v.label, path))
        volumes = cleaned
        out_dir = self.workdir / library.TRANSLATION
        self.state.volumes = [
            VolumeState(
                index=v.index, label=v.label, source=str(v.path),
                output=str(out_dir / f"{slugify(v.path.stem)}"
                                     f" ({self.opt.target_language}){v.path.suffix}"))
            for v in volumes
        ]
        self._save_state()
        return volumes

    async def _classify(self, volumes: List[Volume]) -> BookProfile:
        if self.state.profile:
            return BookProfile(**self.state.profile)
        text = extract_source_text(file_path=str(volumes[0].path))
        if self.auto:
            provider = self._chain(CLASSIFIER_TIER)
        else:
            model, backup = models_for(self.opt.translate_provider, CLASSIFIER_TIER)
            provider = self._provider(self.opt.translate_provider, model, backup)
        profile = await classify_book(text, Path(self.opt.input_path).name, provider,
                                      target_language=self.opt.target_language)
        if self.opt.source_language:
            profile.source_language = self.opt.source_language
        if self.opt.fiction is not None:
            profile.is_fiction = self.opt.fiction
        self.state.profile = asdict(profile)
        self._save_state()
        return profile

    async def _glossary(self, profile: BookProfile, volumes: List[Volume]) -> Optional[Path]:
        if self.opt.glossary_path:
            self.say(f"Glossary: using {self.opt.glossary_path}")
            return Path(self.opt.glossary_path)
        if not profile.is_fiction:
            self.say("Glossary: skipped (not fiction)")
            return None
        path = self.workdir / "glossary.json"
        if path.exists():
            self.say(f"Glossary: reusing {path} (edit it freely, it is read as is)")
            return path
        self.say(f"Glossary: building from {len(volumes)} volume(s)")
        count = await build_glossary(
            [v.path for v in volumes], profile.source_language, self.opt.target_language,
            self._chain(GLOSSARY_MODEL) if self.auto else self._provider(PROVIDER_CLAUDE, GLOSSARY_MODEL),
            path, progress=self.say)
        if not count:
            self.say("Glossary: no terms found, translating without one")
            return None
        self.state.glossary_terms = count
        self.say(f"Glossary: {count} terms written to {path}")
        return path

    async def _style_and_calibrate(self, profile: BookProfile, volumes: List[Volume],
                                   glossary: Optional[Path], choice: ModelChoice) -> None:
        """Write (or reuse) style.md, and for fiction calibration.md."""
        from src.core.glossary.cli_loader import load_glossary_from_file
        style_path = self.workdir / "style.md"
        terms: List[Dict[str, str]] = []
        prompt_options: Dict[str, Any] = {}
        if glossary and Path(glossary).exists():
            mapping, metadata = load_glossary_from_file(str(glossary))
            prompt_options["glossary_terms"] = mapping
            if metadata:
                prompt_options["glossary_term_metadata"] = metadata
            terms = [{"source": s, "category": metadata.get(s, {}).get("category", ""),
                      "gender": metadata.get(s, {}).get("gender", "")} for s in mapping]
        text = extract_source_text(file_path=str(volumes[0].path))
        provider = (self._chain(choice.tier) if self.auto else
                    self._provider(self.opt.translate_provider, choice.model, choice.backup_model))

        style_provider = (self._chain(GLOSSARY_MODEL) if self.auto
                          else self._provider(PROVIDER_CLAUDE, GLOSSARY_MODEL))
        choice_path = self.workdir / "style.json"
        known = {}
        if choice_path.exists():
            try:
                known = json.loads(choice_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                known = {}
        if known.get("recommended"):
            recommended = {"id": known["recommended"], "why": known.get("why", "")}
        else:
            recommended = await style_mod.recommend_style(text, profile, self.opt.target_language,
                                                          style_provider)
        chosen = recommended["id"] if self.opt.style == "auto" else self.opt.style
        if known.get("chosen") and known["chosen"] != chosen:
            style_path.unlink(missing_ok=True)                    # another style: write it again
            (self.workdir / "calibration.md").unlink(missing_ok=True)
        style_mod.write_style_choice(choice_path, recommended, chosen, self.opt.target_language)
        presets = style_mod.presets_for(self.opt.target_language)
        self.say(f"Style: {presets[chosen][0]}"
                 + (" (recommended: " + recommended["why"] + ")" if chosen == recommended["id"] and recommended.get("why")
                    else f" (recommended was {recommended['id']})"))

        if style_path.exists():
            self.style_text = style_path.read_text(encoding="utf-8")
            self.say(f"Style guide: reusing {style_path} (edit it freely, it is read as is)")
        else:
            self.say("Style guide: writing style.md")
            name, meaning = presets[chosen]
            self.style_text = await style_mod.build_style_guide(
                text, profile, self.opt.target_language, terms, style_provider, style_path,
                direction=f"{name}. {meaning}")
        prompt_options["custom_instructions"] = self.style_text

        calibration = self.workdir / "calibration.md"
        if profile.is_fiction and not calibration.exists():
            done = await style_mod.calibrate(
                text, profile, self.opt.target_language, prompt_options, provider, calibration)
            self.say(f"Calibration: {done} passage(s) written to {calibration}" if done
                     else "Calibration: could not translate the sample passages")

    def _prepare_job(self, job: JobConfig, choice: ModelChoice) -> JobConfig:
        options = dict(job.provider.options or {})
        if choice.backup_model:
            options["backup_model"] = choice.backup_model
        if choice.chain:
            options["chain"] = list(choice.chain)
        if self.opt.effort:
            options["effort"] = self.opt.effort
        prompt_options = dict(job.prompt_options or {})
        if self.style_text:
            prompt_options["custom_instructions"] = self.style_text
            prompt_options["refinement_instructions"] = style_mod.refinement_instructions(
                self.style_text, self.opt.target_language)
        # The polish pass and the number of parallel requests follow this run, not the one
        # that saved the checkpoint: both may be changed before a volume is resumed.
        prompt_options["refine"] = self.refine_on
        return job.with_changes(
            max_tokens_per_chunk=self.opt.max_tokens_per_chunk, prompt_options=prompt_options,
            refine_after=self.refine_on, parallel_workers=max(1, self.opt.parallel),
            provider=job.provider.with_changes(options=options))

    def _translate_volume(self, vol: VolumeState, profile: BookProfile, choice: ModelChoice,
                          glossary: Optional[Path], cli_logger) -> JobStatus:
        # Imported here: translate.py configures stdio and logging on import.
        from translate import _resume_job, build_parser, run_cli_job
        from src.persistence.checkpoint_manager import CheckpointManager

        argv = ["-i", vol.source, "-o", vol.output,
                "-sl", profile.source_language, "-tl", self.opt.target_language,
                "--provider", "chain" if self.auto else self.opt.translate_provider, "-m", choice.model,
                "--parallel", str(self.opt.parallel), "--no-color"]
        if glossary:
            argv += ["--glossary", str(glossary)]
        if self.refine_on:
            argv += ["--refine"]
        args = build_parser().parse_args(argv)
        job = JobConfig.from_cli_args(args)

        manager = CheckpointManager(db_path=str(self.workdir / "jobs.db"))
        job_id = vol.job_id or f"agent_{slugify(self.workdir.name, 'book')[:24]}_v{vol.index:02d}"
        vol.job_id = job_id
        resume = manager.load_checkpoint(job_id) is not None
        if resume:
            try:
                job = _resume_job(argparse.Namespace(resume=job_id), manager)
            except Exception as exc:
                logger.info("Cannot resume %s (%s): starting the volume again", job_id, exc)
                resume = False
        job = self._prepare_job(job, choice)
        Path(vol.output).parent.mkdir(parents=True, exist_ok=True)
        seen = {"at": 0.0}

        def on_stats(stats):
            total = stats.get("total_chunks", 0) or 0
            if time.time() - seen["at"] >= 2 and total:
                seen["at"] = time.time()
                try:    # the polish pass counts its own chunks from 0: say which pass this percentage belongs to
                    phase = (manager.get_job(job_id) or {}).get("job_phase") or "translate"
                except Exception:
                    phase = "translate"
                self._write_status("running", vol, int(100 * (stats.get("completed_chunks", 0) or 0) / total), phase)

        self._write_status("running", vol, 0)
        result = run_cli_job(job, cli_logger, translation_id=job_id,
                             checkpoint_manager=manager, is_resume=resume, on_stats=on_stats)
        vol.error = result.error or ""
        return result.status

    @staticmethod
    def _boilerplate_names(vol: VolumeState) -> List[str]:
        """Documents of the volume's source that are not part of the book (EPUB only)."""
        source = Path(vol.source)
        if source.suffix.lower() != ".epub" or not source.exists():
            return []
        try:
            return [name for name, _why in boilerplate_documents(source)]
        except Exception:
            return []

    def _drop_boilerplate(self, vol: VolumeState) -> None:
        """Delete from a finished EPUB the pages that are not part of the book.

        A volume cleaned at intake never has them; a translation made before the cleaning
        existed (or from an upload whose source was not cleaned) is repaired here.
        """
        output = Path(vol.output)
        if output.suffix.lower() != ".epub" or not output.exists():
            return
        try:
            removed = remove_documents(output, set(self._boilerplate_names(vol)))
        except Exception as exc:
            logger.warning("Could not drop boilerplate pages of volume %d: %s", vol.index, exc)
            return
        if removed:
            self.say(f"Volume {vol.index}: deleted {len(removed)} page(s) that are not part of the "
                     f"book from the translation: {', '.join(removed)}")

    def _glossary_entries(self) -> List[Dict[str, str]]:
        """The glossary as ``[{source, target, decision}]`` (empty when there is none)."""
        path = Path(self.state.glossary) if self.state.glossary else None
        if not path or not path.exists():
            return []
        try:
            if path.suffix.lower() == ".json":
                data = json.loads(path.read_text(encoding="utf-8"))
                terms = data.get("terms", []) if isinstance(data, dict) else data
                return [{"source": t["source"], "target": t.get("target", ""),
                         "decision": t.get("decision") or ("keep" if t["source"] == t.get("target")
                                                           else "translate")}
                        for t in terms if t.get("source")]
            from src.core.glossary.cli_loader import load_glossary_from_file
            mapping, _meta = load_glossary_from_file(str(path))
            return [{"source": s, "target": t, "decision": "keep" if s == t else "translate"}
                    for s, t in mapping.items()]
        except Exception as exc:
            logger.info("Cannot read the glossary for the checks (%s)", exc)
            return []

    def _run_term_fix(self, cli_logger, argv: List[str]) -> bool:
        from translate import build_parser, run_cli_job
        from src.persistence.checkpoint_manager import CheckpointManager
        args = build_parser().parse_args(argv + ["--provider", "claude-cli", "--no-color"])
        job = JobConfig.from_cli_args(args)
        result = run_cli_job(job, cli_logger, translation_id=f"fix_{int(time.time() * 1000)}",
                             checkpoint_manager=CheckpointManager(db_path=str(self.workdir / "jobs.db")))
        return result.status is JobStatus.COMPLETED

    def _repair_names(self, vol: VolumeState, entries: List[Dict[str, str]], cli_logger) -> None:
        """Replace drifted spellings of locked names by the locked form (no LLM)."""
        output = Path(vol.output)
        if not entries or not output.exists():
            return
        try:
            source_docs, output_docs = qa_mod.load_documents(Path(vol.source)), qa_mod.load_documents(output)
            variants = qa_mod.find_name_variants(
                " ".join(t for t, _ in source_docs.values()), " ".join(t for t, _ in output_docs.values()),
                entries)
            if not variants:
                return
            rules = self.workdir / "name_fixes.txt"
            qa_mod.write_rules(rules, variants)
            if qa_mod.apply_variant_fixes(output, rules, self.opt.target_language,
                                          lambda argv: self._run_term_fix(cli_logger, argv)):
                vol.fixed_variants = {v: c for v, (c, _n) in variants.items()}
                self.say(f"Volume {vol.index}: repaired name variants: "
                         + ", ".join(f"{v} -> {c} (x{n})" for v, (c, n) in variants.items()))
        except Exception as exc:  # a repair is an improvement, never a reason to lose the volume
            logger.warning("Name repair of volume %d failed: %s", vol.index, exc)

    def _audit(self, vol: VolumeState, entries: List[Dict[str, str]]) -> None:
        output = Path(vol.output)
        try:
            results = qa_mod.audit_volume(Path(vol.source), output, entries,
                                          skip=self._boilerplate_names(vol))
        except Exception as exc:
            logger.warning("Audit of volume %d failed: %s", vol.index, exc)
            return
        self._qa_results[vol.index] = results
        vol.qa_flags = sum(1 for r in results if r.flags)
        if vol.qa_flags:
            self.say(f"Volume {vol.index}: {vol.qa_flags} document(s) flagged, see qa_report.md")

    def _write_qa_report(self) -> None:
        if not self._qa_results:
            return
        title = (self.profile.title if self.profile else "") or self.workdir.name
        rows = [(v.label, self._qa_results[v.index], v.fixed_variants)
                for v in self.state.volumes if v.index in self._qa_results]
        (self.workdir / "qa_report.md").write_text(qa_mod.report_markdown(title, rows), encoding="utf-8")

    def _write_status(self, state: str, vol: Optional[VolumeState] = None, pct: int = 0,
                      phase: str = "translate") -> None:
        """books/status.json: what is running now, for the app (written atomically)."""
        from src.core.llm.providers.chain import last_engine
        engine = {"claude-cli": "Claude", "codex": "Codex", "agy": "Antigravity"}.get(last_engine(), "")
        title = ((self.profile.title if self.profile else "") or self.workdir.name)
        data = {"state": state, "updated_at": _now(), "book": self.workdir.name, "title": title,
                "volume": vol.index if vol else 0, "volumes": len(self.state.volumes), "pct": pct,
                "phase": phase, "engine": engine}
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            tmp = self.root / "status.json.tmp"
            tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.root / "status.json")
        except OSError:
            pass

    def _finish_volume(self, vol: VolumeState, profile: BookProfile, cli_logger=None) -> None:
        """Complete the metadata of a translated EPUB and record what is still missing."""
        vol.finished_at = _now()
        output = Path(vol.output)
        if not output.exists():
            return
        self._drop_boilerplate(vol)
        entries = self._glossary_entries()
        if cli_logger is not None:
            self._repair_names(vol, entries, cli_logger)
        if output.suffix.lower() != ".epub":
            self._audit(vol, entries)
            return
        import src.config as cfg
        count = len(self.state.volumes)
        first = vol.index == min(v.index for v in self.state.volumes)
        # Keep the original title: it is read back from the untranslated volume file, so a
        # split volume is "Title - Volume N". The series is that title without the number.
        # Otherwise the series follows the title the engine translated.
        title = ""
        if self.opt.keep_original_title:
            original = ""
            if Path(vol.source).suffix.lower() == ".epub":
                original = read_metadata(Path(vol.source)).get("title", "")
            title = original or profile.title
            base = strip_volume_suffix(title)
        else:
            base = strip_volume_suffix(read_metadata(output).get("title", ""))
        if base and (first or not profile.title_translated):
            profile.title_translated = base
        self.state.profile = asdict(profile)
        subject = GENRE_SUBJECTS_ID.get(profile.genre, "") \
            if self.opt.target_language.strip().lower() in ("indonesian", "bahasa indonesia", "id") \
            else ""
        try:
            finalize_metadata(
                output, series=profile.title_translated or profile.title, volume=vol.index,
                volume_count=count, original_title=profile.title,
                source_language=profile.source_language,
                target_language=self.opt.target_language, subject=subject, title=title,
                strip_attribution=not cfg.ATTRIBUTION_ENABLED)
        except Exception as exc:  # metadata is a finishing touch: never lose a translation
            logger.warning("Could not finish metadata of %s: %s", output.name, exc)
        vol.title = read_metadata(output).get("title", "")
        vol.metadata_missing = audit_metadata(
            output, expect_series=count > 1, target_language=self.opt.target_language)
        if vol.metadata_missing:
            self.say(f"Volume {vol.index}: metadata still missing: {', '.join(vol.metadata_missing)}")
        self._audit(vol, entries)

    # -------------------------------------------------------------------- run
    def run(self) -> int:
        self.workdir.mkdir(parents=True, exist_ok=True)
        from src.utils.unified_logger import setup_cli_logger
        cli_logger = setup_cli_logger(enable_colors=False)

        source = library.adopt_source(Path(self.opt.input_path), self.workdir, self.root)
        self.state.source = str(source)
        self.say(f"Book folder: {self.workdir}")

        volumes = self._split(source)
        self.say(f"Volumes: {len(volumes)} ({', '.join(v.label for v in volumes[:5])}"
                 f"{', ...' if len(volumes) > 5 else ''})")
        if self.auto and not self.opt.refresh_metadata:
            self._active_engines()
            if not any(e.active for e in self.engines):
                self.say("No translation engine is active. Install and sign in to at least one of "
                         "claude, codex or agy, then try again. Found: "
                         + "; ".join(f"{e.label}: {e.reason}" for e in self.engines))
                return 2
        self.profile = asyncio.run(self._classify(volumes))
        profile = self.profile
        if self.opt.redo:
            self._redo_volumes()
        choice = choose_model(profile.genre, profile=self.opt.profile, override=self.opt.model,
                              provider=self.opt.translate_provider, engines=self.engines)
        self.state.provider = self.opt.translate_provider
        self.state.model = choice.model
        self.state.backup_model = choice.backup_model or ""
        self.say(f"Book: '{profile.title}' | {profile.source_language} -> "
                 f"{self.opt.target_language} | genre {profile.genre} "
                 f"({profile.method}: {profile.reason})")
        if self.auto:
            self.say("Engines: " + ", ".join(
                f"{e.label} ({'main' if e.role == 'main' else 'backup'})" for e in self.engines
                if e.active) + ("" if all(e.active for e in self.engines) else "; not active: " + ", ".join(
                    f"{e.label} ({e.reason[:60]})" for e in self.engines if not e.active)))
        else:
            backup = f", backup claude '{choice.backup_model}'" if choice.backup_model else ""
            self.say(f"Translation: {self.opt.translate_provider} '{choice.model}'{backup} "
                     f"({choice.reason})")

        if self.opt.refresh_metadata:
            for vol in self.state.volumes:
                if vol.status == JobStatus.COMPLETED.value and Path(vol.output).exists():
                    self._finish_volume(vol, profile, cli_logger)
            self._write_qa_report()
            self._save_state()
            self.say("Metadata refreshed for the finished volumes.")
            return 0

        glossary = asyncio.run(self._glossary(profile, volumes))
        self.state.glossary = str(glossary or "")
        self.refine_on = profile.is_fiction if self.opt.refine is None else self.opt.refine
        asyncio.run(self._style_and_calibrate(profile, volumes, glossary, choice))
        self._save_state()
        if self.opt.glossary_only:
            self.say("Stopped after the preparation (--glossary-only). Review glossary.json, "
                     "style.md and calibration.md, edit them, then run again.")
            return 0
        if self.refine_on:
            self.say("Polish pass: on (the translated text is refined without changing "
                     "meaning, names or terms)")

        return self._translate_all(profile, choice, glossary, cli_logger)

    def _redo_volumes(self) -> None:
        """Mark the selected volumes for translation again, keeping the old output."""
        archive = self.workdir / "previous"
        for vol in self.state.volumes:
            if self.opt.only_volumes and vol.index not in self.opt.only_volumes:
                continue
            output = Path(vol.output)
            if output.exists():
                archive.mkdir(exist_ok=True)
                output.replace(archive / f"{output.stem}.{int(time.time())}{output.suffix}")
            base = vol.job_id.split("_r")[0] or f"agent_{slugify(self.workdir.name, 'book')[:24]}_v{vol.index:02d}"
            vol.job_id = f"{base}_r{int(time.time())}"      # a new job id: old checkpoints are ignored
            vol.status, vol.error, vol.qa_flags, vol.fixed_variants = STATUS_PENDING, "", 0, {}
            self.say(f"Volume {vol.index}: will be translated again (the old file is in previous/)")
        self._save_state()

    def _translate_all(self, profile: BookProfile, choice: ModelChoice, glossary: Optional[Path],
                       cli_logger) -> int:
        started = time.time()
        for vol in self.state.volumes:
            if self.opt.only_volumes and vol.index not in self.opt.only_volumes:
                continue
            if vol.status == JobStatus.COMPLETED.value and Path(vol.output).exists():
                self.say(f"Volume {vol.index}: already translated, skipped")
                continue
            self.say(f"Volume {vol.index}/{len(self.state.volumes)}: {vol.label}")
            try:
                status = self._translate_volume(vol, profile, choice, glossary, cli_logger)
            except Exception as exc:  # one broken volume must not lose the others
                logger.exception("Volume %d failed", vol.index)
                vol.status, vol.error = JobStatus.FAILED.value, str(exc)
                self._save_state()
                continue
            vol.status = status.value
            if status is JobStatus.COMPLETED:
                self._finish_volume(vol, profile, cli_logger)
                self._write_qa_report()
            self._save_state()
            if status is JobStatus.RATE_LIMITED:
                self.say("Usage limit reached: stopping. Run the same command later to continue.")
                break

        self._write_status("idle")
        return self._report(time.time() - started)

    def _report(self, seconds: float) -> int:
        chosen = self.opt.only_volumes
        rows = [v for v in self.state.volumes if not chosen or v.index in chosen]
        done = [v for v in rows if v.status == JobStatus.COMPLETED.value]
        self.say(f"Finished {len(done)}/{len(rows)} volume(s) in {seconds / 60:.1f} min")
        if done:
            self.say(f"Translations: {self.workdir / library.TRANSLATION}")
            self.say(f"Index: {self.root / 'INDEX.md'}")
        for v in rows:
            if v.status != JobStatus.COMPLETED.value:
                self.say(f"  volume {v.index} ({v.label}): {v.status} {v.error}".rstrip())
        return 0 if len(done) == len(rows) else 1
