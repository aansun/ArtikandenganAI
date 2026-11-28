# NNAI Translator: the book agent

`translate_book.py` translates whole books into Indonesian (by default) with the command line
tools you already have signed in to: `claude`, `codex` and `agy` (`opencode` is wired in but
has no recommended model yet, see [Models](#models)). It is a layer on top of the
existing translation engine, so EPUB structure, checkpoints and the glossary machinery are the
engine's own. Claude is used at `sonnet` at most; `opus` is not an option anywhere.

**Engines.** The agent finds the active engines by itself (installed AND one of its recommended
models answering a tiny test question). The first active one, in the order claude, codex, agy,
opencode, is the main engine and the other
active ones are backups, in order: when the main engine hits a quota or fails, the next one answers
that request, and a failing engine rests for ten minutes. `python translate_book.py --detect` shows
what was found; `--engines codex,claude` changes the order or the set.

## Quick start: a new book

Prerequisites, once: at least one of the `claude`, `codex` and `agy` CLIs is installed and signed in
(for example `claude auth login`), and `.env` holds `ATTRIBUTION_ENABLED=false` (no translator
signature in the result).

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
   translated nor paid for; the original upload is never touched. A page is left out only when it
   holds nothing else: where the Gutenberg start or end line shares a page with chapters, just what
   lies outside those lines is cut. Footnotes the text links to are kept even under a
   "Transcriber's Notes" heading. A multi-volume file is then cut
   into one file per volume (EPUB via the table of contents or headings, TXT via lines such as
   `Volume 3`); a folder of volume files is used as is; with no markers the book is one volume.
3. **Classify** the book (genre, source language, title) with one cheap call. If it fails, a local
   heuristic takes over. Fiction gets steps 5 to 7 in full; other books skip the glossary.
4. **Choose the engines and models** from the genre: tier `sonnet` for fiction, specialist and
   general books, tier `haiku` for children's and simple text (`--profile economy` also drops general
   non-fiction to `haiku`). Each engine maps the tier to a [recommended model](#models). `-m`
   forces the main engine's model; any opus or fable model is refused.
5. **Book bible (fiction), on `sonnet`.** Every volume is cut into parts of about 60k characters
   and the entity pass runs on each part (excerpts spread over the part plus a window around every
   recurring name found by a local scan), not on one sample. The results of all parts and volumes
   merge, then one cleanup call drops what is not part of the story and replaces "Archivist Besh"
   by "Besh". **Names are preserved:** a person, place, organisation or item in the Latin alphabet
   keeps its original form (`decision: keep`), each form ("Holmes", "Sherlock Holmes") being its
   own entry; a name in another script keeps the transliteration chosen once (`transliterate`).
   The result is `glossary.json`, plain JSON you can edit.
6. **Style guide.** First a style is **recommended from the content of the book**: formal and
   restrained (saya/Anda), casual and modern (aku/kamu), or literary and poetic, with a one-sentence
   reason; `--style auto` (default) takes the recommendation, `--style formal|santai|sastra` forces
   one, and the options, recommendation and choice are written to `style.json`. Then `style.md`
   holds a fixed baseline for natural Indonesian plus book-specific decisions written once (register and address between characters, narration, dialogue, titles
   and terms), about 350 words, injected into every translation and polish request.
7. **Calibration (fiction).** `calibration.md` shows two passages (the opening and the most
   dialogue-dense stretch) translated with the glossary and the style guide.
8. **Translate** the volumes in order with the glossary and style guide. Fiction then gets a
   **polish pass** (`--no-refine` skips it): the translation is smoothed for natural reading with
   the instruction never to change meaning, facts, names or glossary terms. The polish roughly
   doubles the number of calls. Both `--no-refine` and `--parallel` apply to the run that resumes a
   stopped volume too; switching the polish off for a volume stopped while polishing keeps the
   finished translation as it is.
9. **Check and finish** each volume:
   - **Boilerplate pages** that are not part of the book are deleted from the translation (spine,
     manifest, table of contents and file), also for a translation made before the cleaning
     existed: `--refresh-metadata` repairs such a book without translating again.
   - **Layout** (no model is asked): a paragraph that a lost layout marker cut inside a sentence
     is cut again at the real break, only when the text stays the same to the character; contents
     entries every publisher words the same way ("Cover", "Copyright", "Contents") are written
     in Indonesian. `--repair <book folder>` does both to a book translated earlier and keeps the
     old file in `previous/`.
   - **Name check:** a capitalised word in the middle of a sentence that is not in the source,
     not in the glossary and one or two letters from a locked name ("Lestrada" for "Lestrade") is
     listed in `qa_report.md`. Nothing is replaced: ordinary words of the target language can look
     like a name ("toko", shop, beside "Tokyo"). Versions up to 1.0.8 did replace them, and could
     spoil a book that way.
   - **Metadata** is completed and audited (below).
   - **Audit:** every translated document is compared with its source and flagged for length
     (omission or addition), missing numbers, a different number of quotation marks, leftover
     source-language text, a different paragraph count, and a locked name that never appears. The
     result is `qa_report.md`; flags are things to look at, not proven errors.
   Then `book.json` and `INDEX.md` are written.
10. **Final check** of each volume, without asking any model: the file opens and is well formed;
    every page of the upload that belongs to the book is there; paragraph counts match; no page or
    long paragraph is far shorter than its source; nothing was left in the source language; links
    that worked still work; no paragraph breaks off inside a sentence; the front-matter contents
    entries are in the target language; dialogue marks are the same across chapters; no page writes quotation
    marks or *kau*/*kamu* unlike the rest of the book ([one voice](#one-voice-for-a-book)); no locked name appears far
    more often than in the original (a sign of wrong replacements); book details are complete. The
    result is `check.json` (`ok`, `warn`, or `fail` when part of the book is probably missing).
    It does not judge the prose, and nothing is changed. `--check <book folder>` runs it again.

## Polish only

`--polish-only -i book.epub` is for an EPUB that is already in the target language (`-tl`). It is
not split, cleaned or given a glossary, and no calibration samples are made. The style guide is
written (or taken from `--style`), the refine-only pass polishes the text, and the final check
compares the result with your file; it also lists the longer pages in which not one paragraph
changed. Only the text changes: pages and metadata stay as they were, and your file is not touched.

The book gets its own folder, `books/<book>_polish/`, so it never mixes with a translation of the
same file; the result is `translation/<book> (<language>, polished).epub`. A stopped run goes on
with the chunks it already polished. A pass in which no answer of the model could be used ends as
failed. `--redo` polishes again from your file and keeps the earlier result in `previous/`.

The pass does not see an original, so it cannot find a mistranslation. A glossary is used only if
you give one (`--glossary`).

## The source file

`--inspect` also reports signs of a poor EPUB, which the app shows before any work is spent:
`garbled` (damaged characters), `scanned` (converted from a scan) and `broken_paragraphs` (many
paragraphs break inside a sentence). A publisher's copy of the same book gives a better result.

## Send to Kindle

`--kindle-check <book folder>` prints what a Kindle would read from each finished volume (title,
author, language, cover, size), its problems and whether it was sent. `--kindle-send <book folder>`
e-mails the volumes (all, or `--volumes`) to the Send to Kindle address with Python's `smtplib`,
over an encrypted connection (port 465, else STARTTLS); `--kindle-test` only signs in. The settings
come from the environment, never the command line: `KINDLE_TO`, `KINDLE_FROM`, `KINDLE_SMTP_HOST`,
`KINDLE_SMTP_PORT`, `KINDLE_SMTP_USER` (when it differs from the sender), `KINDLE_SMTP_PASSWORD`.
In the app they are filled in under Settings and the password is kept in the Keychain.

A volume is not sent without a title, an author and a language ("Unknown" counts as none), when the
author holds an e-mail address, when the file is damaged or when it is over 50 MB. What was sent is kept in `<book>/kindle.json` (volume, file fingerprint, title,
time; no address): the same file is skipped unless `--resend`, and a changed file shows as changed.
"Sent" means your mail server took the message; Amazon delivers it only when the sender is on its
approved list.

Every `--kindle-test` and `--kindle-send` adds a line to `<library>/_diagnostics/kindle.jsonl`: time,
app version, server and port, the step that failed (`connect`, `encrypt`, `sign_in`), the server's
reply and, for Gmail, whether the password has the shape of an app password. It holds no password,
e-mail address, title or file name, stays on this computer and keeps the last 300 lines. In the app:
**Settings > Send to Kindle > Sending log**.

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
| `--refresh-metadata` | No translation: redo metadata, boilerplate deletion, name check and audit |
| `--volumes 1-3,5` | Only these volumes |
| `-tl`, `-sl` | Target language (default Indonesian), source language (default detected) |
| `--fiction` / `--non-fiction` | Override the classifier |
| `--glossary FILE` | Use your own glossary (.json/.csv) instead of building one |
| `--no-refine` | Skip the polish pass |
| `--polish-only` | [Do not translate](#polish-only): polish and check an EPUB that is already translated (needs `-i`) |
| `--translate-title` | Translate the book title |
| `--profile economy\|balanced\|best` | Cost/quality trade-off for model choice |
| `-m MODEL`, `--effort LEVEL` | Force the model; effort level for the CLI |
| `--no-split`, `--volume-pattern REGEX` | Control volume splitting |
| `--chunk-tokens N`, `--parallel N` | Chunk size (default 1800); concurrent requests while translating (default 1) |
| `--translate-provider auto\|claude-cli\|codex\|agy\|agy-claude` | `auto` (default): every active engine, first = main, rest = backups; or force one |
| `--engine-model ENGINE=MODEL`, `--list-models` | Use [your own model](#models) for an engine; list the choices |
| `--one-engine` | Use only the book's [main engine](#one-voice-for-a-book); wait (exit code 3) at its usage limit |
| `--engines codex,claude`, `--refresh-engines` | Order or subset of engines for `auto`; probe them again instead of using the cached result |
| `--style auto\|formal\|santai\|sastra` | Translation style; `auto` follows the recommendation |
| `--repair BOOK_FOLDER` | Mend broken paragraphs and front-matter contents entries of a finished translation, then check it (no model is asked) |
| `--check BOOK_FOLDER` | Run the final check again on a translated book (no model is asked) and exit |
| `--set-metadata BOOK_FOLDER --field F --value V` | Set one metadata field (title, creator, description, publisher, date, subject, language, series, isbn, cover) of every translated volume and exit; `\|` separates several subjects or authors; `cover` takes an image path |
| `--no-log`, `--log-report` | Do not keep the [translation log](TRANSLATION_LOG.md) (also `AGENT_LOG=0`); print its summary |
| `--detect` | Print the engines found, as JSON, and exit |
| `--inspect FILE` | Print what the app shows for a book (title, author, volumes, fiction or not, estimated time), as JSON, and exit |
| `--watch` | Worker mode: keep translating whatever lands in the inbox (cloud) |

## Stopping and continuing

A run can be stopped at any moment (pause, usage limit, closed app) and continued by running it
again: the translation resumes from its checkpoint, the glossary build keeps the answers it already
had, and the polish pass takes the chunks it already polished from a file beside the output instead
of asking again. The time spent in each stage is kept in `<book>/stages.json`.

## Series

A book added to the library starts from the glossary and the writing style of the books of the same
series that are already there in the same target language, whatever the order the volumes are added
in. The series is read from the book's metadata, else from its title or file name ("Vol. 2",
"Book 3", "Jilid 4", "(Saga #2)"), and the author must match. Names the series already decided win
over new proposals. Nothing is stored apart from the books: a deleted book no longer passes anything on.

## Models

The app chooses the models, not the CLI's own settings. The list is `src/core/agent/models.py`;
an engine without a listed model that is available and answers cannot be used.

| Engine | Tier `sonnet` (novels, specialist and general books) | Tier `haiku` (light books) |
|---|---|---|
| claude | `sonnet` | `haiku` |
| codex | `gpt-6-luna`, reasoning high | `gpt-6-luna`, reasoning high |
| agy | `gemini-3.8-flash-high` | `gemini-3.8-flash-low` |
| opencode | none yet | none yet |

OpenCode has candidates (Claude Sonnet and Haiku, Gemini Flash through OpenCode Zen) that have not
translated real text yet, so they are not used. To try them while checking their quality, set
`AGENT_ALLOW_UNTESTED_MODELS=1`. No free or preview model is listed: some of them train on what
they are sent. Each OpenCode request runs with every tool switched off, in an empty directory,
without the user's `AGENTS.md`, `CLAUDE.md`, plugins or MCP servers. OpenCode keeps its own local
history of the requests, which includes the passages sent.

A model that its provider retires makes the engine inactive until the list is updated.

**Your own choice.** The table is the recommendation. `--engine-model agy=gemini-3.8-flash-medium`
(app: the menu under each engine in Settings) uses another model of that engine, for every kind of
work; `--list-models` prints what each installed engine offers, the recommendation first. opus,
fable, free, preview and orchestrator models are never offered or accepted, and an engine without a
recommended model stays unusable. A chosen model that does not answer makes its engine inactive:
nothing stands in for it silently. A choice that is not the recommendation has not been checked for
translation quality. It applies from the next start or resume of a book.

## One voice for a book

Two models do not write alike, so a book has a **main engine** (auto mode): the one it began with,
or the one that wrote the other books of its series. It is asked first on every run, whatever the
engine order says later. Its model stays too. `--redo` of the whole book chooses anew.

- **Switching (default).** When the main engine fails or reaches its usage limit, the next one takes
  over. `voice.json` in the book folder holds two short passages the main engine wrote (one set for
  the translation, one for the polish pass), and every request to another engine carries them as a
  voice reference: word choice, pronouns, rhythm, punctuation. The main engine's requests are
  unchanged. An answer that repeats the sample is asked for again without it. This brings the
  engines closer; it cannot make them identical.
- **Waiting (`--one-engine`).** No other engine is used. At a usage limit the run stops with exit
  code **3**, `status.json` says `waiting` and which engine, and the same command goes on later.
  The app tries again every 20 minutes; a preparation cut short by the limit is asked again rather
  than kept in a poorer form.

The style guide asks for fixed pronoun rules per pair of speakers, and a polished book keeps the
pronouns of its text (its style guide has no register rules that would change them). The final check lists pages whose quotation marks or *kau*/*kamu* differ from
the habit of the rest of the book (a hint to read them, not proof of an error).

## Cost and speed

Every chunk is one CLI call. The agent uses 1800-token chunks (the engine's 450 is meant for small
local models) and one chunk at a time by default. `--parallel` (in the app: "Requests at once")
sends several: EPUB chunks are translated independently either way, while plain text loses the context
carried from the previous chunk. EPUB chapters are still taken one after another, so only the chunks
within a chapter overlap; the polish pass always sends one request at a time. A higher number uses
the usage limit faster. As a measure, a 43,000-word novel took about 44 minutes with the polish pass on
`sonnet`. A ten-volume novel is a long job.

## For the Mac app

The app drives `translate_book.py` and reads files; it needs no other interface:

- `--detect`: engines as JSON (`name`, `label`, `active`, `reason`, `role` main or backup, `path`,
  `models` by tier). A `reason` starting with `no recommended model` means the engine cannot be used.
- `--inspect FILE`: title, author, volumes, `kind` (fiksi or nonfiksi, recognised from the content),
  source language, word count and estimated minutes, for the Masukkan card. `--fiction` /
  `--non-fiction` overrides the recognition when the user flips it.
- `books/status.json`: what runs now (`state` running, idle or waiting, book, volume, `pct`, `engine` that
  answered last, `stage` prepare, translate, refine or check, `times` in seconds per stage, `polish`),
  updated every few seconds.
- `book.json` has `mode`: `translate`, or `polish` for a polish-only book.
- `books/<book>/book.json`, `style.json`, `glossary.json`, `qa_report.md`: the book's state, style
  options and recommendation, locked names and the quality audit.
- Order of the queue is the app's: it starts one book after another with `-i`.

## The agy engine

`agy` adds roughly 24k tokens of fixed overhead per call (`claude` about 5k, `codex` about 9k), which
uses its quota quickly. A quota that is used up shows in `--detect` with the time it comes back, and
the engine is simply left out until then. `--translate-provider agy-claude` (agy first, claude as
backup) is still available.

## Running in the cloud

The agent is a long-running batch worker, so it needs a container or VM with a persistent disk,
not a serverless function. `deployment/Dockerfile.agent` and `docker-compose.agent.yml` package it
in `--watch` mode, using `/data` as the library:

```bash
echo 'ANTHROPIC_API_KEY=YOUR_API_KEY_HERE' > .env
docker compose -f docker-compose.agent.yml up -d --build
```

Upload books into the volume's `inbox/`. The worker picks up each finished upload and retries
unfinished books every 30 minutes. The container translates with Claude only (`--translate-provider claude-cli`): `agy` has no
documented headless sign-in or Linux package, and `codex` has not been tried there. Authentication is `ANTHROPIC_API_KEY`
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
  "Transcriber's Note", download-site credits); a page without them is translated. Up to version
  1.0.6 a whole page was left out for a Gutenberg line even when it held chapters: a book translated
  then from such a file may be missing chapters and has to be translated again from the upload.
- Multi-volume splitting has been tested on a synthetic EPUB, not yet on a real multi-volume book.
