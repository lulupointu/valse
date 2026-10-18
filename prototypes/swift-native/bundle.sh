#!/bin/bash
# Builds (release) and assembles build/Montage.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release >&2
APP=build/Montage.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Montage "$APP/Contents/MacOS/Montage"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/fr.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
