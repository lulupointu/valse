#!/bin/bash
# Launches Montage in the BACKGROUND (never steals focus, never sends input), captures its window to a PNG, quits it.
# Usage: scripts/screenshot.sh [-o out.png] [--open project.montage] [--demo] [--lang en|fr] [--size 1687x983] [--wait 4] [--offscreen] [--player-state spec] [--home-demo N] [--ui-state spec]
#   Default output: build/screenshots/montage-<lang|default>.png
#   Capture uses `screencapture -l <windowID>` (window capture, works for windows behind other apps; needs Screen Recording
#   permission for the terminal). With --offscreen, or when screencapture fails, the app renders itself offscreen
#   (`--snapshot`), which needs no permission.
set -euo pipefail
cd "$(dirname "$0")/.."
export MONTAGE_MUTE_AUDIO=1   # silent app (AudioOutput.isSilenced)
OUT=""; WAIT=4; OFFSCREEN=0; APPARGS=(); LANGTAG="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT="$2"; shift 2;;
    --open) APPARGS+=(--open "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2;;
    --demo) APPARGS+=(--demo); shift;;
    --lang) APPARGS+=(--lang "$2"); LANGTAG="$2"; shift 2;;
    --size) APPARGS+=(--size "$2"); shift 2;;
    --wait) WAIT="$2"; shift 2;;
    --offscreen) OFFSCREEN=1; shift;;
    --player-state) APPARGS+=(--player-state "$2"); shift 2;;
    --home-demo) APPARGS+=(--home-demo "$2"); shift 2;;
    --ui-state) APPARGS+=(--ui-state "$2"); shift 2;;
    -h|--help) sed -n '2,7p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
[[ -x build/Montage.app/Contents/MacOS/Montage ]] || scripts/build_app.sh >/dev/null
mkdir -p build/screenshots
OUT="${OUT:-build/screenshots/montage-$LANGTAG.png}"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
WID_FILE="$(mktemp -t montage-wid)"
BIN=build/Montage.app/Contents/MacOS/Montage

if [[ $OFFSCREEN == 1 ]]; then
  "$BIN" --background "${APPARGS[@]+"${APPARGS[@]}"}" --snapshot "$OUT" --quit-after $((WAIT + 20)) >/dev/null 2>&1 || true
  [[ -s "$OUT" ]] && { echo "$OUT"; exit 0; } || { echo "offscreen snapshot failed"; exit 1; }
fi

# Direct exec (not `open`): the process is not activated, so it can't steal focus from other apps.
"$BIN" --background --window-id-file "$WID_FILE" --quit-after $((WAIT + 30)) "${APPARGS[@]+"${APPARGS[@]}"}" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$WID_FILE"' EXIT
for _ in $(seq 1 50); do [[ -s "$WID_FILE" ]] && break; sleep 0.2; done
sleep "$WAIT"
WID="$(cat "$WID_FILE" 2>/dev/null || true)"
if [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT" 2>/dev/null && [[ -s "$OUT" ]]; then
  echo "$OUT"
else
  kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true
  echo "screencapture unavailable, using offscreen snapshot" >&2
  "$BIN" --background "${APPARGS[@]+"${APPARGS[@]}"}" --snapshot "$OUT" --quit-after $((WAIT + 20)) >/dev/null 2>&1 || true
  [[ -s "$OUT" ]] && echo "$OUT" || { echo "screenshot failed"; exit 1; }
fi
kill $PID 2>/dev/null || true
