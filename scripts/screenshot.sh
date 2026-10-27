#!/bin/bash
# Launches Valse in the BACKGROUND (never steals focus, never sends input), captures its window to a PNG, quits it.
# Usage: scripts/screenshot.sh [-o out.png] [--open project.valse] [--demo] [--lang en|fr] [--size 1687x983] [--wait 4] [--offscreen] [--player-state spec] [--home-demo N] [--ui-state spec]
#   Default output: build/screenshots/valse-<lang|default>.png
#   --offscreen (recommended): the app renders itself (`--snapshot`) in a window placed far off every screen (never
#   visible, never activated), writes the PNG and exits; needs no permission. Without it, the window opens BEHIND other
#   apps and is captured with `screencapture -l <windowID>` (needs Screen Recording permission; falls back to offscreen).
#   Every app run has a hard deadline: on timeout its stacks go to build/screenshots/hang-sample.txt, the app is killed
#   and the script exits 1 (never leaves a Valse process behind).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh   # kill_tree, on_exit; exports VALSE_MUTE_AUDIO=1 (silent app)
export VALSE_MUTE_AUDIO=1
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
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
# VALSE_SCREENSHOT_BIN: another Valse executable (e.g. the `swift build` product, scripts/screenshot_selftest.sh)
BIN="${VALSE_SCREENSHOT_BIN:-build/Valse.app/Contents/MacOS/Valse}"
[[ -x "$BIN" ]] || scripts/build_app.sh >/dev/null
mkdir -p build/screenshots
OUT="${OUT:-build/screenshots/valse-$LANGTAG.png}"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
SAMPLE="$PWD/build/screenshots/hang-sample.txt"
APP_LOG="$(mktemp -t valse-shot)"
on_exit "rm -f '$APP_LOG'"
PID=""
# a Valse still running when this script exits (error, Ctrl-C) is killed with its children
on_exit '[[ -n "$PID" ]] && kill_tree "$PID"'

# start_app <args…>: launches the app in the background (stdin closed, output → $APP_LOG), sets PID
start_app() {
  "$BIN" "$@" < /dev/null >> "$APP_LOG" 2>&1 &
  PID=$!
}

# wait_app <seconds>: waits for $PID to exit; returns its exit code, or 124 after sampling + killing it at the deadline
wait_app() {
  local limit="$1" start code
  start=$(date +%s)
  while kill -0 "$PID" 2>/dev/null; do
    if (( $(date +%s) - start >= limit )); then
      sample "$PID" 3 -file "$SAMPLE" >/dev/null 2>&1 || true
      kill_tree "$PID"; wait "$PID" 2>/dev/null || true; PID=""
      echo "screenshot.sh: TIMEOUT: Valse did not finish within ${limit}s; killed it (stacks: $SAMPLE)" >&2
      return 124
    fi
    sleep 0.5
  done
  set +e; wait "$PID"; code=$?; set -e
  PID=""
  return $code
}

# offscreen: the app renders its offscreen window to $OUT and exits by itself (its own hard deadline = --quit-after)
offscreen_snapshot() {
  local quit=$((WAIT + 20)) code=0
  rm -f "$OUT"
  start_app --background --offscreen "${APPARGS[@]+"${APPARGS[@]}"}" --snapshot "$OUT" --quit-after "$quit"
  wait_app $((quit + 15)) || code=$?
  if [[ $code == 0 && -s "$OUT" ]]; then echo "$OUT"; return 0; fi
  echo "screenshot.sh: offscreen snapshot failed (app exit $code); app log tail:" >&2
  tail -8 "$APP_LOG" >&2 || true
  return 1
}

if [[ $OFFSCREEN == 1 ]]; then
  offscreen_snapshot && exit 0 || exit 1
fi

# Direct exec (not `open`): the process is not activated, so it can't steal focus from other apps.
WID_FILE="$(mktemp -t valse-wid)"
on_exit "rm -f '$WID_FILE'"
start_app --background --window-id-file "$WID_FILE" --quit-after $((WAIT + 30)) "${APPARGS[@]+"${APPARGS[@]}"}"
for _ in $(seq 1 50); do [[ -s "$WID_FILE" ]] && break; sleep 0.2; done
sleep "$WAIT"
WID="$(cat "$WID_FILE" 2>/dev/null || true)"
if [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT" 2>/dev/null && [[ -s "$OUT" ]]; then
  kill_tree "$PID"; wait "$PID" 2>/dev/null || true; PID=""
  echo "$OUT"
else
  kill_tree "$PID"; wait "$PID" 2>/dev/null || true; PID=""
  echo "screencapture unavailable, using offscreen snapshot" >&2
  offscreen_snapshot || { echo "screenshot failed"; exit 1; }
fi
