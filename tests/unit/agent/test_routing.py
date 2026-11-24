import pytest

from src.core.agent.classifier import heuristic_profile, parse_classification
from src.core.agent.routing import (
    AGY_MODELS, DEFAULT_TRANSLATE_PROVIDER, GLOSSARY_MODEL, TRANSLATE_PROVIDERS, check_allowed,
    choose_model)


@pytest.mark.parametrize("genre,profile,tier", [
    ("fiction_novel", "balanced", "sonnet"),
    ("fiction_novel", "economy", "sonnet"),   # never below the fiction floor
    ("fiction_novel", "best", "sonnet"),      # translation never goes above sonnet
    ("technical", "balanced", "sonnet"),
    ("technical", "best", "sonnet"),
    ("technical", "economy", "sonnet"),       # specialist floor
    ("nonfiction_general", "economy", "haiku"),
    ("children", "balanced", "haiku"),
    ("children", "best", "sonnet"),
])
def test_tier_by_genre(genre, profile, tier):
    assert choose_model(genre, profile=profile).tier == tier


def test_default_is_claude_only():
    assert DEFAULT_TRANSLATE_PROVIDER == "claude-cli"
    choice = choose_model("fiction_novel")
    assert (choice.model, choice.backup_model) == ("sonnet", None)


def test_agy_first_mode_has_claude_as_backup():
    choice = choose_model("fiction_novel", provider="agy-claude")
    assert choice.model == AGY_MODELS["sonnet"] and choice.backup_model == "sonnet"
    light = choose_model("children", provider="agy-claude")
    assert light.model == AGY_MODELS["haiku"] and light.backup_model == "haiku"


def test_provider_variants():
    assert choose_model("fiction_novel", provider="agy").backup_model is None
    claude = choose_model("children", provider="claude-cli")
    assert (claude.model, claude.backup_model) == ("haiku", None)


def test_opus_is_not_an_option_anywhere():
    genres = ("fiction_novel", "technical", "nonfiction_general", "children")
    for genre in genres:
        for profile in ("economy", "balanced", "best"):
            for provider in TRANSLATE_PROVIDERS:
                choice = choose_model(genre, profile=profile, provider=provider)
                assert "opus" not in choice.model + (choice.backup_model or "")
    assert GLOSSARY_MODEL == "sonnet"
    for name in ("opus", "claude-opus-4-6-thinking", "Opus"):
        with pytest.raises(ValueError):
            check_allowed(name)
        with pytest.raises(ValueError):
            choose_model("fiction_novel", override=name)


def test_override_replaces_only_the_primary():
    choice = choose_model("fiction_novel", override="claude-sonnet-4-6", provider="agy-claude")
    assert (choice.model, choice.backup_model) == ("claude-sonnet-4-6", "sonnet")


def test_parse_classification_tolerates_prose():
    assert parse_classification('Sure!\n{"genre": "legal"}\nDone')["genre"] == "legal"
    assert parse_classification("no json") is None


def test_heuristic_detects_dialogue_heavy_text_as_fiction():
    text = ('"Where are you going?" she asked.\n"Home," he said.\n' * 60)
    assert heuristic_profile(text).is_fiction
    assert not heuristic_profile("The committee reviewed the annual budget. " * 100).is_fiction
