# NNAI Translator 1.0.10

Every translation now ends with a check of the result.

## New: stage 4, Final check

After the translation and the polish, each volume is compared with its original. It takes seconds, asks no
model (no quota used) and **changes nothing**. It looks for:

- a damaged file;
- pages or paragraphs that did not arrive, including pages of your original file dropped by the cleaning;
- passages far shorter than the original, or left untranslated;
- dialogue marks that differ between chapters, and links or footnotes that stopped working;
- doubtful names, and names far more frequent than in the original (a sign of wrong replacements);
- missing book details.

Where you see it:

- **Progress** shows the four stages, and a card for the book that just finished with the verdict.
- A book's page in the library lists the findings, with **Check again**. Use it on books translated earlier.
- Library books that need a look are marked.

The check looks at completeness and structure. It does not judge whether the translation is right in meaning
or reads well. Some details of the findings are shown in English.

## Fixed

- **Footnotes headed "Transcriber's Notes" are no longer removed** when the text links to them. Earlier versions
  could drop such a page and leave the footnote marks of the chapters dead.

## Install

Download `NNAI-Translator-1.0.10.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.10.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
