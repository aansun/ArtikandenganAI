# NNAI Translator 1.0.0

The first release of the Mac app. It translates EPUB and TXT books with the Claude, Codex and Antigravity
command-line tools you already use, keeps names and style consistent, and gives you a library to check the
result.

## Highlights

- **Three steps: Add, Progress, Library.** Drop many books, drag them into order, press Start. Books
  translate one after another; pause and resume any time, and the queue survives a restart.
- **Fiction gets a glossary first.** Characters, places and terms are collected before translating and
  locked, so names stay the same through a whole series. A writing style is recommended from the book's
  own text; you review names and style in one screen before the long run starts.
- **Three engines, one queue.** The app finds which of Claude, Codex and Antigravity are installed and
  signed in. The first is used and the others take over when it hits a quota or fails.
- **Metadata you can trust.** The metadata of each translated EPUB is read from the file and shown for
  checking. Change a field, or find the book online by its ISBN first, then by title, on Open Library and
  Google Books; covers are compared side by side before anything is written.
- **Made to be used.** Light, dark or automatic theme; English or Indonesian menus; 18 target languages;
  large-cover or card library; a menu-bar item with progress; a clean window that adapts to small sizes.

## Install

Download `NNAI-Translator-1.0.0.dmg`, open it and drag the app to Applications. On first launch the app
asks to install its Python libraries once (needs the internet and Python 3.10 or newer). You also need at
least one of the `claude`, `codex` or `agy` tools signed in. `NNAI-Translator-1.0.0.zip` holds the same app
and is what the in-app updater downloads.

## Under the hood

- The translation engine is built into the app; only its Python libraries are installed on first launch,
  into `~/Library/Application Support/NNAI Translator`.
- New engine commands: `--detect` (which engines work), `--inspect` (what a book is), `--set-metadata`
  (change one field of a finished book), `--style`, `--redo`, `--refresh-metadata`.
- Boilerplate pages (licence headers, donation appeals, download-site credits) are removed instead of being
  translated, name variants the model invents are repaired, and every translated page is audited against
  its source.
- Opus models are never used; Claude runs at Sonnet at most.

## Known limits

- Signed ad hoc, not notarised: on another Mac, right-click the app and choose Open once.
- Python 3.10 or newer must be installed; the app does not bundle a Python.
- Indonesian is the best-tuned target language; the other 17 work but have had less testing.
- Google Books lookup needs your own free API key (Settings). Amazon has no public catalogue API, so its
  button only opens the Amazon search page.
- Antigravity uses its quota quickly; it is skipped while its quota is exhausted.
- Multi-volume splitting was tested on a synthetic EPUB, not yet on a real ten-volume novel.
- The in-app updater is tested for version logic and release parsing, not yet against a real release.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.

Built on [TBL: Translate Books with LLMs](https://github.com/hydropix/TranslateBooksWithLLMs) by hydropix.
