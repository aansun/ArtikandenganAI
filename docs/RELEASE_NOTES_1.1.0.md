# NNAI Translator 1.1.0

Send your books to a Kindle, and choose the model of each engine.

## New: Send to Kindle

- Send a finished book to your Kindle by e-mail from its page in the library.
- Set it up once under **Settings > Send to Kindle**: your Kindle address, your sender address, the mail
  server (Gmail, iCloud, Yahoo or another) and an **app password**, which is kept in the Keychain. Add the
  sender address to the approved list in your Amazon account. **Test connection** signs in and sends nothing.
- Title, author, language and cover are shown and checked first. A file without a title, an author or a
  language, damaged, or over 50 MB is not sent.
- A book that was sent is marked and not sent twice. When its file changes, it shows as changed and can be
  sent again.
- "Sent" means your mail server accepted the message. Sending was tested with a stand-in mail server.
- Personal Outlook.com addresses do not work: Microsoft no longer accepts a password for them.

## New: your own model, and an easier order

- Under each engine in Settings you can pick another of its models. The recommended one stays marked; other
  choices are not checked for translation quality. A chosen model that does not answer makes its engine
  inactive instead of being replaced silently. It applies from the next start or resume of a book.
- Two arrows move an engine up or down, at once.

## Also

- The language of a book can be edited under Metadata.

## Install

Download `NNAI-Translator-1.1.0.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.1.0.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
