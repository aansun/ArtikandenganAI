# books/

The library of the book translator agent. Full guide: [docs/BOOK_AGENT.md](../docs/BOOK_AGENT.md).

**New book in three steps** (run from the repository root):

1. Copy the book (EPUB, TXT, or a folder with one file per volume) into `inbox/`.
2. `python translate_book.py --prepare-only` writes the glossary, style guide and two sample
   passages; read and edit them (recommended for fiction).
3. `python translate_book.py` translates everything in `inbox/`. Results: `INDEX.md`, or
   `<book>/translation/`.

Each book gets its own folder:

```
<book>/
  source/         the original upload (moved here from inbox/)
  volumes/        the working copy, cleaned of boilerplate pages and split per volume
  translation/    the translated volumes
  glossary.json   names, places, terms (edit it)
  style.md        the style guide (edit it)
  calibration.md  two translated sample passages
  qa_report.md    what the quality audit flagged
  book.json       full metadata: titles, languages, genre, models, per-volume status
```

To translate again after editing the glossary or the style guide, add `--redo` (the old
translation is kept in `previous/`).

Book files are not committed to git (only this README and `inbox/.gitkeep` are).
