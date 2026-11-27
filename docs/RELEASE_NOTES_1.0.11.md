# NNAI Translator 1.0.11

A privacy fix in the app package. Translating works the same as in 1.0.10.

## Fixed

- **The package no longer names the Mac it was built on.** Earlier packages carried the builder's macOS user
  name inside folder paths, in the app's settings file and in debug information. Release builds now leave the
  path out, the debug information is stripped, and packaging stops if a personal-data check finds anything.
- The `.zip` no longer carries extra macOS file attributes.

The download files of earlier releases have been removed. Their release notes stay.

## Install

Download `NNAI-Translator-1.0.11.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.0.11.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
