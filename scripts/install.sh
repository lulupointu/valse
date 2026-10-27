#!/bin/bash
# Installs the latest Valse into /Applications (or ~/Applications when /Applications is not writable), then opens it.
# Meant to be piped from the web (SE-015, docs/RELEASING.md):
#   curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash
# A file downloaded with curl carries no quarantine flag, so macOS opens Valse without the "can't verify" prompt;
# afterwards Valse updates itself.
# The app was called Montage before 0.4: a running Montage or Valse is asked to quit first (its project is saved), and
# an old Montage.app in the same Applications folder is replaced by Valse.app (settings and projects are migrated by
# Valse at its first launch).
set -euo pipefail
URL="https://github.com/lulupointu/valse/releases/latest/download/Valse.zip"
LEGACY_ID=fr.montage.Montage   # bundle id of the app before the rename
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

running() { pgrep -xq Valse || pgrep -xq Montage; }
if running; then
  echo "Asking Valse to quit (your project is saved)…"
  osascript -e 'tell application id "fr.valse.Valse" to quit' >/dev/null 2>&1 || true
  osascript -e "tell application id \"$LEGACY_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do running || break; sleep 0.5; done
  if running; then echo "Valse is still running: quit it, then run this again."; exit 1; fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading Valse…"
curl -fL --progress-bar "$URL" -o "$TMP/Valse.zip"
ditto -x -k "$TMP/Valse.zip" "$TMP/x"
[[ -d "$TMP/x/Valse.app" ]] || { echo "The download is not a Valse archive."; exit 1; }
rm -rf "$DEST/Valse.app"
ditto "$TMP/x/Valse.app" "$DEST/Valse.app"
xattr -dr com.apple.quarantine "$DEST/Valse.app" 2>/dev/null || true
# the pre-rename app (or a not yet renamed bridge build) in the same folder: replaced by Valse.app
OLD="$DEST/Montage.app"
if [[ -d "$OLD" ]]; then
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$id" == "$LEGACY_ID" || "$id" == fr.valse.* ]]; then rm -rf "$OLD" && echo "Removed the old $OLD"; fi
fi
echo "Installed $DEST/Valse.app"
open "$DEST/Valse.app"
