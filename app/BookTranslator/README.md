# NNAI Translator for Mac

A SwiftUI app around `translate_book.py`. It has no translation logic of its own: it drives the
engine as a background process and reads the files the engine writes (see "For the Mac app" in
`docs/BOOK_AGENT.md`).

The UI follows the design canvas (a stage bar with the three numbered steps at the top, the gear
opens Settings). Three steps:

1. **Add**: drop many EPUB/TXT books (or whole folders of volumes) on the left card. The engine
   reads each one (`--inspect`: title, author, volumes, fiction or not, estimated time; the type chip
   can be flipped). Press Add or drag a book to the right card; the top book is translated first,
   and the order can be changed by dragging or with the arrows. **Start translating** moves the
   ready books into the Progress queue. Finished books leave this screen.
2. **Progress**: one book runs, the rest wait. A fiction book is prepared first (`--prepare-only`:
   names locked, style recommended from the content) and waits for **Review**; the other books do
   not wait for it. Pause keeps the progress (checkpoints), and the queue survives a restart.
3. **Library**: the finished books, grouped by type or author and sorted as you like. Selecting a
   book shows its volumes, the quality audit, and the **metadata read from the EPUB itself** for
   checking. **Change** next to a field edits it in every volume (`--set-metadata`), and "Mark
   metadata as correct" clears the Check flag on the card; **Find online** looks the book up the way
   Calibre does: by the ISBN already in the EPUB first (an exact edition), else by title and
   author, on Open Library (no key) and Google Books (your own free API key, kept in the Keychain; set it in
   Settings) and lets you tick the fields to take (author, publisher, date, subjects, ISBN, cover,
   description), filling only empty fields by default. Amazon has no public catalogue API, so its
   button only opens the Amazon search page; "Translate again" runs `--redo`.

Settings: app language (English or Indonesian, switched live), version and updates, the engines
found by `--detect` (first active = main, others = backup), quality (`--profile`), library and
engine folders, notifications. The menu-bar icon shows the running book and can pause it.

## Build and run

```bash
brew install xcodegen          # once
cd app/BookTranslator
xcodegen generate
xcodebuild -project BookTranslator.xcodeproj -scheme BookTranslator -destination 'platform=macOS' build
```

Build outside iCloud Drive (for example `-derivedDataPath ~/Library/Caches/BookTranslator-dd`) if
the project lives in an iCloud-synced folder. The app is not sandboxed, because it starts the
engine and the `claude`, `codex` and `agy` CLIs.

The engine folder is baked in at build time (`BTBackendRoot` in `project.yml`, the repository
root) and can be changed in Settings. The Python used is `<engine folder>/.venv/bin/python3`, else
`/usr/bin/python3`. The app adds the usual install locations (Homebrew, `~/.local/bin`, your login
shell's PATH) so the engine finds the CLIs even though a Mac app does not inherit a shell PATH.

**First launch:** if the engine folder is inside Documents, Desktop or iCloud Drive, macOS asks once
whether NNAI Translator may access it. Until that prompt is answered the engine cannot start, so the
Settings screen shows no engines. Allow it, or keep the engine folder elsewhere.

## Package and install

```bash
app/BookTranslator/Tools/package.sh            # universal Release build (arm64 + x86_64)
ARCHS=arm64 app/BookTranslator/Tools/package.sh # faster, Apple silicon only
```

This writes `dist/NNAI-Translator-<version>.dmg` (open it and drag NNAI Translator to Applications) and
`dist/NNAI-Translator-<version>.zip` (the file the in-app updater downloads). `dist/` is git-ignored.

- **The engine is inside the app.** Its source (about 5 MB) is copied into `Contents/Resources/engine` by a
  build phase. Its Python libraries are not: on first launch the app asks to install them once (it finds a
  Python 3.10 or newer, makes a virtual environment in `~/Library/Application Support/NNAI Translator` and
  runs `pip install -r requirements.txt`; this needs the internet and takes a few minutes). A new app version
  with different requirements rebuilds the environment by itself, and Settings has Repair.
- **Python is the one prerequisite.** If no Python 3.10+ is installed (`brew install python@3.13`), the setup
  screen says so. Bundling a Python runtime inside the app would remove this step but add about 100 MB.
- **Library folder.** A fresh install keeps books in `~/Documents/NNAI Translator`; an existing library (for
  example the repository's `books/`) is kept. Change it in Settings.
- **Developer folder.** Settings can still point the app at a repository checkout (its `.venv` is used) instead
  of the built-in engine, and switch back with "Use the built-in engine".
- **Signing.** The app is signed ad hoc, which is enough on the Mac that built it. If the DMG or zip is
  copied to another Mac (download, AirDrop), macOS quarantines it: right-click the app and choose Open
  once, or run `xattr -dr com.apple.quarantine "/Applications/NNAI Translator.app"`. A build that opens
  without that step needs an Apple Developer ID and notarisation, which this project does not have.
- **First launch.** If the library folder is in Documents, Desktop or iCloud Drive, macOS asks once whether
  the app may use it; allow it.

## Updates

Settings checks the latest GitHub release (`BTUpdateFeed`): the tag is the version and the `.zip`
asset holds the app. With "Update automatically" on, a newer version is installed only when no
translation is running; otherwise the screen says it waits for the queue to empty. The install
downloads the zip, unpacks it, and a small script swaps the app bundle after the app quits and
reopens it. This path is covered by unit tests for the version logic and the release parsing; the
download-and-swap itself has not been run against a real release yet, and a private repository
needs a public feed URL instead.

## Tests

```bash
xcodebuild -project BookTranslator.xcodeproj -scheme BookTranslator -destination 'platform=macOS' test
```

`SnapshotTests` render the screens to PNG when `BT_SNAPSHOT_DIR` is set, and `IntegrationTests`
drive the real engine and CLIs end to end when `BT_INTEGRATION=<epub>` and `BT_ROOT=<engine
folder>` are set (with `TEST_RUNNER_` prefixes under `xcodebuild`). Both are skipped otherwise.

The pictures in the main README come from sample data: run `SnapshotTests/testReadmeScreens` with
`TEST_RUNNER_BT_README_DIR=<folder>`, then
`python3 -I Tools/frame_screenshots.py <folder> ../../docs/images/nnai` (needs Pillow).
