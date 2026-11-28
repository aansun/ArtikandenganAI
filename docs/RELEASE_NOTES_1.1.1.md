# NNAI Translator 1.1.1

Fixes for Send to Kindle.

## Fixed

- A sign-in that Gmail refuses no longer shows as "Connection unexpectedly closed". The app says the server
  refused the sign-in, with the reason the server gave. If you saw that message, make a new **app password**
  for the sender account, remove the stored one under **Settings > Send to Kindle**, save the new one and use
  **Test connection**.
- Hidden spaces in a Gmail app password copied from a web page are removed.
- A book whose title or author reads "Unknown", or whose author holds an e-mail address, is no longer sent.
  Fix it under Metadata first.
- The mail server is no longer told the computer's name.

Sending was tested with stand-in mail servers.

## Install

Download `NNAI-Translator-1.1.1.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.1.1.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
