#!/bin/bash
# Builds build/Montage.app (release by default; `--debug` for a debug build). Ad-hoc signed.
# Usage: scripts/build_app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug
swift build -c "$CONFIG" --product Montage >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=build/Montage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Montage" "$APP/Contents/MacOS/Montage"
cp app/Bundle/Info.plist "$APP/Contents/Info.plist"
cp app/Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R app/Bundle/en.lproj app/Bundle/fr.lproj "$APP/Contents/Resources/"
# SwiftPM resource bundles (localized strings of every module) → Contents/Resources (found by ResourceBundleLocator)
for b in "$BIN"/Montage_*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed" >&2
echo "$APP"
