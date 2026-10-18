#!/bin/bash
# Runs UI test scripts (JSON DSL, docs/TESTING.md) inside the real app, in an OFFSCREEN window that is never activated:
# no Screen Recording / Accessibility permission needed, the real mouse/keyboard/screen are never touched.
#
# Usage: scripts/uitest.sh [options] <script.json>...     (or --all = every app/Tests/UIScripts/*.json)
#   --all                 run every script in app/Tests/UIScripts
#   --update-baselines    rewrite screenshot baselines (app/Tests/Baselines) instead of comparing
#   --release             use a release build (default: debug build, faster to compile)
#   --no-build            don't rebuild
#   --timeout <s>         per-script timeout (default 120)
#   --out <dir>           output root (default build/uitest); each script writes <out>/<name>/{report.json,final.json,*.png}
# Exit code: 0 if every script passed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG=debug; BUILD=1; TIMEOUT=120; OUT="$ROOT/build/uitest"; EXTRA=(); SCRIPTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) for f in app/Tests/UIScripts/*.json; do SCRIPTS+=("$f"); done; shift;;
    --update-baselines) EXTRA+=(--update-baselines); shift;;
    --release) CONFIG=release; shift;;
    --no-build) BUILD=0; shift;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) SCRIPTS+=("$1"); shift;;
  esac
done
[[ ${#SCRIPTS[@]} -gt 0 ]] || { sed -n '2,13p' "$0"; exit 2; }
if [[ $BUILD == 1 ]]; then swift build -c "$CONFIG" --product Montage >&2; fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Montage"
[[ -x "$BIN" ]] || { echo "no binary at $BIN (drop --no-build)"; exit 2; }

PASS=0; FAIL=0; FAILED=()
for s in "${SCRIPTS[@]}"; do
  [[ -f "$s" ]] || { echo "no such script: $s"; FAIL=$((FAIL + 1)); FAILED+=("$s"); continue; }
  ABS="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
  NAME="$(basename "$s" .json)"
  "$BIN" --uitest "$ABS" --uitest-out "$OUT/$NAME" --baselines "$ROOT/app/Tests/Baselines" ${EXTRA[@]+"${EXTRA[@]}"} &
  PID=$!
  ( sleep "$TIMEOUT"; kill -9 $PID 2>/dev/null && echo "✘ $NAME: TIMEOUT after ${TIMEOUT}s" ) &
  WATCH=$!
  set +e; wait $PID; CODE=$?; set -e
  kill $WATCH 2>/dev/null || true; wait $WATCH 2>/dev/null || true
  if [[ $CODE == 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED+=("$NAME → $OUT/$NAME"); fi
done
echo "UI tests: $PASS passed, $FAIL failed"
for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  failed: $f"; done
[[ $FAIL == 0 ]]
