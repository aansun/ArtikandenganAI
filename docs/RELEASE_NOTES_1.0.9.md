# NNAI Translator 1.0.9

**Important fix: words of a finished translation could be replaced by mistake.** Please update.

## Fixed

- **The app no longer rewrites a translation to "repair" names.** After translating, earlier versions looked
  for words that resembled a name of the glossary and replaced them throughout the book, ignoring capital
  letters. An ordinary word of the translation could be caught: one Indonesian novel had every "toko" (shop)
  turned into "Tokyo", about 240 places. A closing quotation mark after a name could also be removed.
  Doubtful spellings are now only listed in the quality report, for you to judge. The text is never changed.
- **"You have the latest version" no longer goes stale.** The app looks for updates again while it runs and
  when you open Settings, and shows your version number.

## Is one of your books affected?

Open the book's folder in your library and read `qa_report.md`. A line starting with **"Name variants
repaired:"** (for example `Toko -> Tokyo`) means words were replaced in that translation. Search the
translated book for the word on the right side to see where.

Updating does not repair a book that was already changed, and the earlier text was not kept. You can correct
the words in an e-book editor, or translate the book again (remove its folder from the library, keeping a copy,
and add the original file again).

## Install

Download `NNAI-Translator-1.0.9.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.9.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
