# Book Translator Agent

`translate_book.py` translates whole books into Indonesian (by default) with the `claude` CLI.
It is a layer on top of the existing translation engine, so EPUB structure, checkpoints and the
glossary machinery are the engine's own. Claude is used at `sonnet` at most; `opus` is not an
option anywhere.

## Quick start: a new book

Prerequisites, once: the `claude` CLI is installed and signed in (`claude auth login`), and
`.env` holds `ATTRIBUTION_ENABLED=false` (no translator signature in the result).

1. **Upload.** Copy the book into `books/inbox/`: an EPUB or TXT file, or a folder with one file
   per volume.
2. **Prepare** (recommended for fiction and anything long):

   ```bash
   python translate_book.py --prepare-only
   ```

   This writes `glossary.json`, `style.md` and `calibration.md` into the book's folder and stops.
   Read the calibration (two passages translated), fix names in the glossary, adjust the style
   guide. What you edit is used as it is.
3. **Translate.**

   ```bash
   python translate_book.py
   ```

   Everything in the inbox is processed. A stopped run (usage limit, closed laptop) continues
   where it left off when you run the same command again.
4. **Read the result** in `books/<book>/translation/`; `books/INDEX.md` lists every book. Look at
   `qa_report.md` for anything flagged.
5. **Correct.** Edit `glossary.json` or `style.md`, then translate again:

   ```bash
   python translate_book.py -i books/<book>/source/<file> --redo --volumes 2
   ```

   The old translation is kept in `previous/`.

Try `--volumes 1` first on a long novel to judge quality, time and cost.

## The pipeline

One run does, for each book:

1. **File** the upload: move it from `inbox/` into `<book>/source/`.
2. **Clean and split.** Boilerplate pages of an e-book (licence header, transcriber's notes,
   donation appeal, download-site credits) are removed from the working copy, so they are neither
   translated nor paid for; the original upload is never touched. A multi-volume file is then cut
   into one file per volume (EPUB via the table of contents or headings, TXT via lines such as
   `Volume 3`); a folder of volume files is used as is; with no markers the book is one volume.
3. **Classify** the book (genre, source language, title) with one cheap call. If it fails, a local
   heuristic takes over. Fiction gets steps 5 to 7 in full; other books skip the glossary.
4. **Choose the model** from the genre: `sonnet` for fiction, specialist and general books,
   `haiku` for children's and simple text (`--profile economy` also drops general non-fiction to
   `haiku`). `-m` forces another model; any opus model is refused.
5. **Book bible (fiction), on `sonnet`.** Every volume is cut into parts of about 60k characters
   and the entity pass runs on each part (excerpts spread over the part plus a window around every
   recurring name found by a local scan), not on one sample. The results of all parts and volumes
   merge, then one cleanup call drops what is not part of the story and replaces "Archivist Besh"
   by "Besh". **Names are preserved:** a person, place, organisation or item in the Latin alphabet
   keeps its original form (`decision: keep`), each form ("Holmes", "Sherlock Holmes") being its
   own entry; a name in another script keeps the transliteration chosen once (`transliterate`).
   The result is `glossary.json`, plain JSON you can edit.
6. **Style guide.** `style.md` holds a fixed baseline for natural Indonesian plus book-specific
   decisions written once (register and address between characters, narration, dialogue, titles
   and terms), about 350 words, injected into every translation and polish request.
7. **Calibration (fiction).** `calibration.md` shows two passages (the opening and the most
   dialogue-dense stretch) translated with the glossary and the style guide.
8. **Translate** the volumes in order with the glossary and style guide. Fiction then gets a
   **polish pass** (`--no-refine` skips it): the translation is smoothed for natural reading with
   the instruction never to change meaning, facts, names or glossary terms. The polish roughly
   doubles the number of calls.
9. **Check and finish** each volume:
   - **Boilerplate pages** that are not part of the book are deleted from the translation (spine,
     manifest, table of contents and file), also for a translation made before the cleaning
     existed: `--refresh-metadata` repairs such a book without translating again.
   - **Name repair:** a capitalised word in the middle of a sentence that is not in the source,
     not in the glossary and one or two letters from a locked name ("Lestrada" for "Lestrade") is
     replaced by the locked name with the engine's literal term-fix (exact whole words, no LLM).
     Names that are also ordinary words of the source ("Standard") are not hunted.
   - **Metadata** is completed and audited (below).
   - **Audit:** every translated document is compared with its source and flagged for length
     (omission or addition), missing numbers, a different number of quotation marks, leftover
     source-language text, a different paragraph count, and a locked name that never appears. The
     result is `qa_report.md`; flags are things to look at, not proven errors.
   Then `book.json` and `INDEX.md` are written.

## Where things go

```
books/
  inbox/                drop new books here (a file, or a folder of volumes)
  INDEX.md              every book in one table, with links to the translations
  <book>/
    source/             the original upload (moved here from inbox/)
    volumes/            the working copy, cleaned and split per volume
    translation/        the translated volumes   <- read these
    glossary.json       the book bible for fiction: names, places, terms (edit it)
    style.md            the style guide injected into every request (edit it)
    calibration.md      two sample passages translated with both (fiction)
    qa_report.md        the audit of every translated document
    previous/           earlier translations kept by --redo
    book.json           full metadata: titles, languages, genre, models, per-volume status
```

Book files are git-ignored; only `books/README.md` and `inbox/.gitkeep` are tracked. The library
is `./books`, or `$BOOKS_DIR`, or `--books-dir`.

## Metadata of a translated EPUB

The engine sets the language (`id`), translates `dc:description`, and keeps authors, publisher,
date, subjects and the cover. **The book title stays in the source language** (OPF, NCX and series
name); `--translate-title` translates it. With `ATTRIBUTION_ENABLED=false` the engine's translator
signature (description footer, contributor, colophon page) is left out, and the agent also removes
it from finished files. The agent adds what a multi-volume book needs: the series name and volume
number (EPUB 3 collection and Calibre form), the original title as `dc:source`,
`dcterms:modified` and a unique identifier per volume. It then audits each file and records
anything still missing (title, creator, language, identifier, description, cover, series) in
`book.json` under `metadata_missing`.

## Options

| Option | Effect |
|---|---|
| `-i PATH` | One book (file or folder of volumes) from anywhere; default: the inbox |
| `--prepare-only` (`--glossary-only`) | Stop after glossary, style guide and calibration |
| `--redo` | Translate the volumes again (all, or `--volumes`); old files go to `previous/` |
| `--refresh-metadata` | No translation: redo metadata, boilerplate deletion, name repair and audit |
| `--volumes 1-3,5` | Only these volumes |
| `-tl`, `-sl` | Target language (default Indonesian), source language (default detected) |
| `--fiction` / `--non-fiction` | Override the classifier |
| `--glossary FILE` | Use your own glossary (.json/.csv) instead of building one |
| `--no-refine` | Skip the polish pass |
| `--translate-title` | Translate the book title |
| `--profile economy\|balanced\|best` | Cost/quality trade-off for model choice |
| `-m MODEL`, `--effort LEVEL` | Force the model; effort level for the CLI |
| `--no-split`, `--volume-pattern REGEX` | Control volume splitting |
| `--chunk-tokens N`, `--parallel N` | Chunk size (default 1800); concurrent chunks (default 1) |
| `--translate-provider claude-cli\|agy-claude\|agy` | Claude only (default); `agy` first with Claude as backup; `agy` only |
| `--watch` | Worker mode: keep translating whatever lands in the inbox (cloud) |

## Cost and speed

Every chunk is one CLI call. The agent uses 1800-token chunks (the engine's 450 is meant for small
local models) and one chunk at a time, because parallel chunks lose the context carried from the
previous chunk. As a measure, a 43,000-word novel took about 44 minutes with the polish pass on
`sonnet`. A ten-volume novel is a long job.

## The agy option

`--translate-provider agy-claude` puts the Antigravity CLI (Gemini Flash) first with Claude as
backup: a failed `agy` request is answered by Claude, and after a quota or sign-in failure `agy`
is skipped for 10 minutes. It is off by default because its quota ran out; the default is one
constant, `DEFAULT_TRANSLATE_PROVIDER` in `src/core/agent/routing.py`. `agy` adds roughly 24k tokens
of fixed overhead per call (`claude` about 5k).

## Running in the cloud

The agent is a long-running batch worker, so it needs a container or VM with a persistent disk,
not a serverless function. `deployment/Dockerfile.agent` and `docker-compose.agent.yml` package it
in `--watch` mode, using `/data` as the library:

```bash
echo 'ANTHROPIC_API_KEY=YOUR_API_KEY_HERE' > .env
docker compose -f docker-compose.agent.yml up -d --build
```

Upload books into the volume's `inbox/`. The worker picks up each finished upload and retries
unfinished books every 30 minutes. The container translates with Claude only: `agy` has no
documented headless sign-in or Linux package. Authentication is `ANTHROPIC_API_KEY`
(pay-per-token) or a `CLAUDE_CODE_OAUTH_TOKEN` made with `claude setup-token`; check Anthropic's
current terms before running a subscription token unattended on a server. The image has not been
built or run yet.

## Known limits

- The polish reads the draft only (it does not see the source), so it improves naturalness but
  cannot catch a mistranslation. On plain-text books it may also join short paragraphs (use
  `--no-refine` there); EPUB structure is kept by the engine.
- There is no bilingual review pass, and chunks are cut by size, not by scene, with only the tail
  of the previous chunk as context.
- Boilerplate detection relies on specific markers (Project Gutenberg lines, licence text,
  "Transcriber's Note", download-site credits); a page without them is translated.
- Multi-volume splitting has been tested on a synthetic EPUB, not yet on a real multi-volume book.
