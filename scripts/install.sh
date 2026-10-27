#!/bin/bash
# Installs the latest Valse into /Applications (or ~/Applications when /Applications is not writable), then opens it.
# Meant to be piped from the web (SE-015, docs/RELEASING.md):
#   curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash
# A file downloaded with curl carries no quarantine flag, so macOS opens Valse without the "can't verify" prompt;
# afterwards Valse updates itself.
set -euo pipefail
URL="https://github.com/lulupointu/valse/releases/latest/download/Valse.zip"
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
if pgrep -xq Valse; then echo "Valse is running: quit it, then run this again."; exit 1; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading Valse…"
curl -fL --progress-bar "$URL" -o "$TMP/Valse.zip"
ditto -x -k "$TMP/Valse.zip" "$TMP/x"
[[ -d "$TMP/x/Valse.app" ]] || { echo "The download is not a Valse archive."; exit 1; }
rm -rf "$DEST/Valse.app"
ditto "$TMP/x/Valse.app" "$DEST/Valse.app"
xattr -dr com.apple.quarantine "$DEST/Valse.app" 2>/dev/null || true
echo "Installed $DEST/Valse.app"
open "$DEST/Valse.app"
