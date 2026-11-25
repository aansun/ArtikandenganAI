import asyncio

from src.core.agent.glossary_builder import (
    candidate_entries, consolidate, merge_terms, split_parts)
from src.core.agent.style import baseline_for, pick_passages, refinement_instructions


def test_latin_names_are_preserved_whatever_the_model_proposed():
    entries = candidate_entries([
        {"source": "Holmes", "target": "Holmes", "category": "character", "gender": "male"},
        {"source": "Baker Street", "target": "Jalan Baker", "category": "location"},
        {"source": "Lestrade", "target": "Letrad", "category": "character"},
        {"source": "Doctor", "target": "Dokter", "category": "title"},
        {"source": "Project Gutenberg Foundation", "target": "Yayasan", "category": "organization"},
        {"source": "", "target": "x"},
    ])
    assert entries["Baker Street"] == {"target": "Baker Street", "decision": "keep",
                                       "category": "location"}
    assert entries["Lestrade"]["target"] == "Lestrade"
    assert entries["Holmes"]["gender"] == "male"
    assert entries["Doctor"] == {"target": "Dokter", "decision": "translate", "category": "title"}
    assert "Project Gutenberg Foundation" not in entries and len(entries) == 4


def test_names_in_another_script_keep_the_models_transliteration():
    entries = candidate_entries([{"source": "黒崎", "target": "Kurosaki", "category": "character"}])
    assert entries["黒崎"]["target"] == "Kurosaki" and entries["黒崎"]["decision"] == "transliterate"


def test_merge_keeps_the_earliest_rendering_and_fills_a_missing_gender():
    first = {"Lyra": {"target": "Lyra", "decision": "keep"}}
    later = {"lyra": {"target": "Liera", "decision": "translate", "gender": "female"}}
    merged = merge_terms([first, later])
    assert len(merged) == 1 and merged[0]["target"] == "Lyra" and merged[0]["gender"] == "female"


def test_text_is_covered_in_parts():
    assert split_parts("short") == ["short"]
    parts = split_parts("x" * 250_000)
    assert 2 <= len(parts) <= 8 and "".join(parts) == "x" * 250_000
    assert len(split_parts("x" * 5_000_000)) == 8     # bounded on huge volumes


class Stub:
    def __init__(self, answer):
        self.answer = answer

    async def generate(self, prompt, system_prompt=None, **kwargs):
        class R:
            content = self.answer
        return R()


def entries(n):
    return [{"source": f"Name{i}", "target": f"Name{i}", "category": "character"} for i in range(n)]


def test_consolidation_that_loses_most_entries_is_ignored():
    given = entries(10)
    answer = '<NER_JSON>[{"source": "Name0", "target": "Name0", "category": "character"}]</NER_JSON>'
    assert asyncio.run(consolidate(given, "English", "Indonesian", Stub(answer))) is given


def test_consolidation_failure_keeps_the_merged_list():
    given = entries(5)
    assert asyncio.run(consolidate(given, "English", "Indonesian", Stub("not json"))) == given


def test_consolidation_drops_what_the_model_drops():
    given = entries(4)
    answer = ('<NER_JSON>[{"source": "Name0", "target": "Name0", "category": "character"}, '
              '{"source": "Name2", "target": "Name2", "category": "character"}, '
              '{"source": "Name3", "target": "Name3", "category": "character"}]</NER_JSON>')
    cleaned = asyncio.run(consolidate(given, "English", "Indonesian", Stub(answer)))
    assert [m["source"] for m in cleaned] == ["Name0", "Name2", "Name3"]


def test_calibration_picks_opening_and_dialogue_heavy_passages():
    narration = "The sea was grey and the wind cold. " * 200
    dialogue = ('"Where?" she asked. "There," he said. "Why?" "Because." ' * 40)
    passages = pick_passages(narration + dialogue + narration)
    assert len(passages) == 2 and passages[1].count('"') > passages[0].count('"')
    assert pick_passages("") == []


def test_baseline_and_polish_instructions():
    assert "idiomatic Indonesian" in baseline_for("Indonesian")
    assert baseline_for("French") == ""
    polish = refinement_instructions("STYLE", "Indonesian")
    assert "Never change the meaning" in polish and polish.endswith("STYLE")


def test_calibration_skips_notes_and_starts_at_a_sentence():
    story = ('He paused. "Where were you?" she asked. "Away," he said. "Why?" "Business." ' * 60)
    notes = ('[ "tho cushion": "tho" should be "the"] "x" ' * 80)
    passages = pick_passages(story + notes)
    assert all("[" not in p for p in passages)
    assert passages[0][0].isupper() or passages[0][0] in "\"“"


def test_style_options_follow_the_target_language():
    from src.core.agent import style

    assert "saya" in style.presets_for("Indonesian")["formal"][1]
    for language in ("Spanish", "Japanese", "Chinese"):
        presets = style.presets_for(language)
        assert set(presets) == {"formal", "santai", "sastra"}
        assert "saya" not in presets["formal"][1] and "aku" not in presets["santai"][1]
    assert style.baseline_for("Spanish") == "" and style.baseline_for("id") != ""
