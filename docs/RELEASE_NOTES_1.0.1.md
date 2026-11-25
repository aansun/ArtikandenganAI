# NNAI Translator 1.0.1

A fix release. **Please update from 1.0.0:** in 1.0.0 the first book you translated in the installed app
failed with `No module named 'translate'`.

## Fixed

- **The first translation failed in the installed app.** The translation engine inside the app was missing a
  file that is only needed once a book is actually translated, and the setup check did not notice. It is
  included now, and the setup check imports everything a translation needs. If a book stopped with that
  error in 1.0.0, open it again and press **Try again**; the glossary and style already made are reused.
- **The window could stay empty at launch.** On first launch the app looked in your library folder on the
  main thread. When that folder is in Documents, macOS asks for permission and waits for the answer, so no
  window appeared until you answered. The app now opens at once and reads the folder in the background.
- **Packaging can no longer ship an incomplete engine.** The build runs the engine's self-check from a clean
  copy of the bundled files and stops if anything is missing.

## Install

Download `NNAI-Translator-1.0.1.dmg`, open it and drag the app to Applications (replace the old copy). Your
settings, library and the Python libraries installed on first launch are kept. `NNAI-Translator-1.0.1.zip`
holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
