"""Shared canned answers of the fake `claude` and `agy` binaries (no network)."""
import json
import os
import re


PROBE = "Reply with the single word OK."   # the engine detection's test question


def log_call(provider: str, model: str, prompt: str, system: str, **extra) -> None:
    path = os.environ.get("FAKE_LLM_LOG")
    if path and not prompt.startswith(PROBE):
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"provider": provider, "model": model, "prompt": prompt[:2500],
                                "system": system[:4000],
                                "glossary": "# GLOSSARY" in prompt, **extra}) + "\n")


def respond(prompt: str, system: str) -> str:
    """The model's answer for the kind of prompt it was given."""
    if prompt.startswith(PROBE):
        return "OK"
    text = system + "\n" + prompt
    if "Return exactly this JSON" in prompt:
        genre = os.environ.get("FAKE_GENRE", "fiction_novel")
        return json.dumps({"title": "Fake Saga", "title_translated": "Saga Palsu",
                           "source_language": "English", "genre": genre,
                           "is_fiction": genre.endswith("novel"), "reason": "fake"})
    if "Return the cleaned list" in prompt:
        # cleanup: echo the entries, dropping the generic word
        rows = [line.split(" | ") for line in prompt.splitlines()
                if line.count(" | ") == 3 and not line.startswith("source |")]
        kept = [{"source": r[0], "target": r[1], "category": r[2], "gender": r[3] or "unknown"}
                for r in rows if r[0] != "Doctor"]
        return "<NER_JSON>" + json.dumps(kept) + "</NER_JSON>"
    if "<NER_JSON>" in text:
        return ('<NER_JSON>[{"source": "Aldric", "target": "Aldrik", "category": "character", '
                '"gender": "male"}, {"source": "Captain Aldric", "target": "Kapten Aldrik", '
                '"category": "character", "gender": "male"}, '
                '{"source": "Lyra Thorne", "target": "Lyra Thorne", "category": "character", '
                '"gender": "female"}, {"source": "Kaldmoor", "target": "Kaldmoor", '
                '"category": "location", "gender": "unknown"}, {"source": "Baker Street", '
                '"target": "Jalan Baker", "category": "location", "gender": "unknown"}, '
                '{"source": "Doctor", "target": "Dokter", "category": "title", '
                '"gender": "unknown"}]</NER_JSON>')
    if "Choose the best translation style" in prompt:
        return json.dumps({"style": os.environ.get("FAKE_STYLE", "sastra"),
                           "why": "Banyak deskripsi dunia, jadi diksi kaya menjaga suasana."})
    if "Write the style guide" in prompt:
        return ("Sure.\n## Register and address\n- Use saya and Anda between strangers.\n\n"
                "## Narration\n- Past tense, plain diction.\n\n## Dialogue\n- Short and direct.\n\n"
                "## Names, titles and terms\n- Keep ranks in the source form.\n\n"
                "## Avoid\n- Literal idioms.")
    # The real passage is the LAST tagged block: the instructions mention the tags too.
    matches = re.findall(r"<SOURCE_TEXT>\n?(.*?)\n?</SOURCE_TEXT>", prompt, re.DOTALL)
    body = matches[-1] if matches else prompt
    # "Translate" by changing words, so the engine's copied-source guard accepts it.
    translated = body.replace("Hello", "Halo").replace("The ", "Itu ").replace("pump", "pompa")
    if os.environ.get("FAKE_NAME_DRIFT"):
        translated = translated.replace("Aldric", "Aldrik")
    if os.environ.get("FAKE_SHORT"):
        words = translated.split(" ")
        translated = " ".join(words[:max(3, len(words) // 3)])
    return "<TRANSLATION>\n" + translated.rstrip() + " Selesai.\n</TRANSLATION>"
