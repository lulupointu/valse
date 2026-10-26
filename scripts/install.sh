#!/bin/bash
# Installs the latest Montage into /Applications (or ~/Applications when /Applications is not writable), then opens it.
# Meant to be piped from the web (SE-015, docs/RELEASING.md):
#   curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash
# A file downloaded with curl carries no quarantine flag, so macOS opens Montage without the "can't verify" prompt;
# afterwards Montage updates itself.
set -euo pipefail
URL="https://github.com/lulupointu/valse/releases/latest/download/Montage.zip"
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
if pgrep -xq Montage; then echo "Montage is running: quit it, then run this again."; exit 1; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading Montage…"
curl -fL --progress-bar "$URL" -o "$TMP/Montage.zip"
ditto -x -k "$TMP/Montage.zip" "$TMP/x"
[[ -d "$TMP/x/Montage.app" ]] || { echo "The download is not a Montage archive."; exit 1; }
rm -rf "$DEST/Montage.app"
ditto "$TMP/x/Montage.app" "$DEST/Montage.app"
xattr -dr com.apple.quarantine "$DEST/Montage.app" 2>/dev/null || true
echo "Installed $DEST/Montage.app"
open "$DEST/Montage.app"
