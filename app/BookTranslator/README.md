# Book Translator for Mac

A SwiftUI app around `translate_book.py`. It has no translation logic of its own: it drives the
engine as a background process and reads the files the engine writes (see "For the Mac app" in
`docs/BOOK_AGENT.md`).

Three steps, as the sidebar shows them:

1. **Add**: drop many EPUB/TXT books (or whole folders of volumes) on the left card. The engine
   reads each one (`--inspect`: title, author, volumes, fiction or not, estimated time). Press Add
   or drag a book to the right card; the top book is translated first, and the order can be changed
   by dragging. Finished books leave this screen.
2. **Progress**: one book runs, the rest wait. A fiction book is prepared first (`--prepare-only`:
   names locked, style recommended from the content) and waits for **Review**; the other books do
   not wait for it. Pause keeps the progress (checkpoints), and the queue survives a restart.
3. **Library**: the finished books, grouped by type or author and sorted as you like. Selecting a
   book shows its volumes, the quality audit, and the **metadata read from the EPUB itself** for
   checking; "Repair metadata" and "Translate again" run the engine's `--refresh-metadata` and
   `--redo`.

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
whether Book Translator may access it. Until that prompt is answered the engine cannot start, so the
Settings screen shows no engines. Allow it, or keep the engine folder elsewhere.

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
