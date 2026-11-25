# NNAI Translator 1.0.2

A fix release for the queue.

## Fixed

- **The queue now carries on after a restart.** If the app was quit or killed while books were translating,
  the queue used to sit on "Waiting for its turn" with no way to start it, and the engine of the old run could
  keep working unseen. Now the queue resumes by itself when the app opens (unless you had paused it; your pause
  is remembered), engines left behind by a killed app are stopped first (their checkpoints keep the progress),
  and quitting the app stops its engine.
- **A way to start a waiting queue.** When books are queued and nothing is running, the Progress screen says so
  and offers **Start the queue**.
- **Each book's own cover is shown everywhere.** The Add and Progress screens, the review sheet and the menu
  bar showed a generated placeholder; they now show the cover from the book's EPUB. A cover only changes if
  you apply a new one from the online lookup.

## Install

Download `NNAI-Translator-1.0.2.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one. Your settings,
library and the Python libraries installed on first launch are kept. `NNAI-Translator-1.0.2.zip` holds the same
app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
