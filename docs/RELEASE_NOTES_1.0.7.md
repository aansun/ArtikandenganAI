# NNAI Translator 1.0.7

**Important fix: chapters could be missing from a translation.** Please update.

## Fixed

- **Chapters are no longer thrown away with the licence text.** Before translating, the app removes pages that
  are not part of the book. In every earlier version, a page carrying a Project Gutenberg start or end line
  was removed **whole**, even when it also held chapters. A novel cut into a few large files could lose most
  of its text and still be shown as completed (one 96,000-word novel lost 16 of its 23 chapters). Now only
  what lies before the start line or after the end line is cut. A page is left out only when it holds no
  story, and a page that cannot be cut for certain is translated whole.

## Is one of your books affected?

Books from Project Gutenberg, or made from its files, may be. Compare the number of chapters of the
translation with the original.

Updating alone does not repair a book that was already translated: the app reuses the shortened working copy
of that book. To translate it again in full:

1. Quit the app.
2. Move the book's folder out of your library folder (keep it as a backup). Its original file is in the
   `source` folder inside it.
3. Open the app and add that original file again.

The whole book is translated again, including the list of names.

## Install

Download `NNAI-Translator-1.0.7.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.7.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
