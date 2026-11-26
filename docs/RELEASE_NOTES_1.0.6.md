# NNAI Translator 1.0.6

A translation log you control, and models chosen by the app.

## New: translation log (on by default)

The app now keeps a small log of how translations go: which engine and model answered, how long it took,
sizes, and quality signals such as retried or untranslated passages and check flags. It will be used to
improve the model recommendations.

- **It stays on your Mac** (`_activity-log` in your library folder). Nothing is sent anywhere.
- **No book text, title, author, file name, folder path or error message** is recorded.
- Switch it off in **Settings > Keep a translation log**.
- Sharing is optional: **Settings > Copy summary**, read it, then paste it into a
  [translation log report](https://github.com/aansun/NNAI-Translator/issues/new?template=translation-log.yml).
- What is recorded: [Translation log](https://github.com/aansun/NNAI-Translator/blob/main/docs/TRANSLATION_LOG.md).

The quality numbers are automatic signals. They do not judge how well the prose reads.

## Changed

- **The app chooses the models.** An engine can be used only when a model on the app's list answers.
- **Codex now translates with `gpt-6-luna` (high reasoning)**, whatever model your Codex settings name. If your
  account does not offer it, Codex shows as not active.
- The engine check asks the model that translates novels, so an engine shown as active can really do the work.
- Settings shows each engine's model.

## OpenCode: not usable yet

OpenCode now appears in the engine list, marked **"No recommended model: cannot be used"**. It stays that way
until its models have been checked for translation quality.

## Install

Download `NNAI-Translator-1.0.6.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.6.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
