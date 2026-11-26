# NNAI Translator 1.0.5

Fixes a queue that appeared empty after updating, and lets you trade polish for speed.

## Fixed

- **The queue is no longer lost after an update.** Version 1.0.4 could not read a queue saved by 1.0.3 or
  earlier, so the Progress and Add screens came up empty. The books and their translations were never touched.
  1.0.5 reads such a queue again. If you added no book while on 1.0.4, your old queue comes back by itself; if
  you did, 1.0.4 saved a new queue over it and the old list cannot be restored from it. A queue file that
  cannot be read is now copied aside (`.app-queue.unreadable.json`) before anything can overwrite it.
- Leftover `[partial]` files from a stopped polish pass are removed once the book is finished.

## New in Settings

- **Polish novels** (on by default). Turn it off to translate each book once: it finishes much sooner, with
  stiffer wording. A book stopped while it was being polished, then resumed with this off, keeps its finished
  translation and is done right away.
- **Requests at once** (1 to 3, default 1). More requests translate faster and use your usage limit faster.
  Chapters are still taken one after another, so the gain depends on how long the chapters are. The polish
  pass always sends one request at a time. EPUB passages are translated independently either way; plain-text
  files lose the link to the passage before.

Both apply when a book starts or resumes: to change them for the book that is running, pause, change them and
resume.

## Good to know

- **Correction to the 1.0.4 notes:** a stopped polish pass of an EPUB does **not** continue where it left off.
  It starts again from the beginning. The translation itself is kept and is not repeated.

## Install

Download `NNAI-Translator-1.0.5.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.5.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
