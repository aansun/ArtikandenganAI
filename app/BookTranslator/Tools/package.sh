#!/bin/zsh
# Builds the Release app and packs it as a .dmg (drag to Applications) and a .zip (what the in-app
# updater downloads). Output goes to <repo>/dist. No Apple developer account is needed: the app is
# signed ad hoc, which is enough to run on the Mac that built it (see README for other Macs).
#
#   Tools/package.sh              # universal (arm64 + x86_64) Release build
#   ARCHS=arm64 Tools/package.sh  # faster, Apple silicon only
set -euo pipefail

cd "${0:A:h}/.."                       # app/BookTranslator
ROOT="${PWD:h:h}"                      # repository root
OUT="${OUT:-$ROOT/dist}"
# Keep build products out of iCloud Drive (codesign fails on its extended attributes).
DD="${DERIVED_DATA:-$HOME/Library/Caches/BookTranslator-release}"
ARCHS="${ARCHS:-arm64 x86_64}"

command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
[[ -f "$ROOT/translate_book.py" ]] || { echo "the engine (translate_book.py) was not found in $ROOT" >&2; exit 1; }

xcodegen generate >/dev/null
xcodebuild -project BookTranslator.xcodeproj -scheme BookTranslator -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO build | tail -3

BUILT="$DD/Build/Products/Release/NNAI Translator.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT/Contents/Info.plist")
NAME="NNAI Translator"

# The engine inside the app must be complete: run its self-check from a clean copy of the bundled files, with
# the repository's own Python environment, so a missing file fails the packaging instead of the user's first book.
CHECK="$(mktemp -d)"
cp -R "$BUILT/Contents/Resources/engine" "$CHECK/engine"
( cd "$CHECK" && PYTHONDONTWRITEBYTECODE=1 "$ROOT/.venv/bin/python3" "$CHECK/engine/translate_book.py" --selfcheck ) \
  || { echo "the engine bundled in the app is incomplete" >&2; rm -rf "$CHECK"; exit 1; }
rm -rf "$CHECK"

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUILT" "$STAGE/$NAME.app"
xattr -cr "$STAGE/$NAME.app"
codesign --force --deep --sign - "$STAGE/$NAME.app"
codesign --verify --deep --strict "$STAGE/$NAME.app"

ZIP="$OUT/NNAI-Translator-$VERSION.zip"
DMG="$OUT/NNAI-Translator-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$NAME.app" "$ZIP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Version $VERSION ($BUILD), architectures: $(lipo -archs "$STAGE/$NAME.app/Contents/MacOS/$NAME")"
echo "Engine inside the app: $(du -sh "$STAGE/$NAME.app/Contents/Resources/engine" | cut -f1) (its Python libraries are installed on first launch)"
echo "$DMG"
echo "$ZIP"
