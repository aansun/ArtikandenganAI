# NNAI Translator 1.0.12

Polish a book that is already translated, keep one voice when the engines take turns, and mend two
layout faults.

## New: polish only

- An EPUB that is already in your language can be **polished without being translated**: choose
  **Polish only** on the book. It is recognised and chosen for you when the book is in the target
  language.
- You pick the writing style; the book's own pronouns are kept. Your file is not changed: the result
  is a new file in the library, checked against your file.
- One EPUB at a time. Without the original, a wrong translation cannot be found.

## New: one voice for a book

- A book has a main engine. When another takes over, it is shown a short sample of how the book is
  written so far. This brings them closer; it cannot make them identical.
- **Settings > When a usage limit is reached**: *Switch tools* (as before) or *Wait*, where one tool
  writes the whole book and the app tries again every 20 minutes.
- The final check lists pages whose quotation marks or *kau*/*kamu* differ from the rest.

## Layout

- A fix for **paragraphs cut in the middle of a sentence** when a model loses the layout markers.
- Contents entries such as *Cover*, *Title Page* and *Copyright* are written in Indonesian.
- A book translated earlier can be mended with **Mend** on its page, without using any quota. The old
  file is kept.
- Adding a book warns you when the source file is damaged, scanned or badly broken.

## Other changes

- Translate or polish, and fiction or not, are drop-downs; the buttons on the first screen stand out.
- **Fixed:** an e-book with an empty cover page could end a polish pass as unfinished.
- **Fixed:** a usage limit during the preparation now stops and waits, instead of keeping a poorer
  glossary or style.

## Install

Download `NNAI-Translator-1.0.12.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.12.zip` holds the same app and is what the in-app updater downloads.

A book polished or checked with this version should not be translated again with an older one.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
