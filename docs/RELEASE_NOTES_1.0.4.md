# NNAI Translator 1.0.4

A small release that makes the progress easier to read.

## Changed

- **The polish pass is no longer shown as "Translating".** After the translation reaches 100%, a fiction book
  goes through a polish pass that counts its own chunks again from 0. The Progress card used to keep saying
  "Translating", so it looked as if the book had started over. It now says **"Polishing volume N: the
  translation is done"** during that pass. Nothing about the work itself changed: the translation is kept,
  and a stopped polish pass continues where it left off.

## Good to know

- A pause you choose is remembered across restarts and updates. After an update the app opens still paused;
  press **Resume** on the Progress screen and the book carries on from its saved progress.
- An update installs only when nothing is running.

## Install

Download `NNAI-Translator-1.0.4.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.4.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
