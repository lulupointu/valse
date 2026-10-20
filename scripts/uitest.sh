#!/bin/bash
# Runs UI test scripts (JSON DSL, docs/TESTING.md) inside the real app, in an OFFSCREEN window that is never activated:
# no Screen Recording / Accessibility permission needed, the real mouse/keyboard/screen are never touched.
#
# Usage: scripts/uitest.sh [options] <script.json>...     (or --all = every app/Tests/UIScripts/*.json)
#   --all                 run every script in app/Tests/UIScripts
#   --update-baselines    rewrite screenshot baselines (app/Tests/Baselines) instead of comparing
#   --release             use a release build (default: debug build, faster to compile)
#   --no-build            don't rebuild
#   --timeout <s>         per-script timeout (default 120); a timed-out app is `sample`d (<out>/<name>/hang-sample.txt)
#   --out <dir>           output root (default build/uitest); each script writes <out>/<name>/{report.json,final.json,*.png}
#   --no-retry            don't retry failed scripts (default: a failed script is re-run ONCE; the first attempt is kept
#                         in <out>/<name>.attempt1)
# Exit code: 0 if every script passed, was SKIPPED (unmet precondition, e.g. a missing AI model: app exit code 3), passed
#            on its retry ("flaky") or is quarantined (app/Tests/quarantine.txt: reported, not gating);
#            1 if any other script failed or timed out twice.
# The apps run with a private TMPDIR (sandboxes, exports, project copies) that is deleted on exit, even on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG=debug; BUILD=1; TIMEOUT=120; OUT="$ROOT/build/uitest"; EXTRA=(); SCRIPTS=(); RETRY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) for f in app/Tests/UIScripts/*.json; do SCRIPTS+=("$f"); done; shift;;
    --update-baselines) EXTRA+=(--update-baselines); RETRY=0; shift;;
    --release) CONFIG=release; shift;;
    --no-build) BUILD=0; shift;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-retry) RETRY=0; shift;;
    -h|--help) sed -n '2,19p' "$0"; exit 0;;
    *) SCRIPTS+=("$1"); shift;;
  esac
done
[[ ${#SCRIPTS[@]} -gt 0 ]] || { sed -n '2,19p' "$0"; exit 2; }
source scripts/lib.sh
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh)
source scripts/slots.sh; slots_acquire
mkdir -p "$OUT"
if [[ $BUILD == 1 ]]; then
  if ! run_watched "$OUT/build.log" swift build -c "$CONFIG" --product Montage; then
    grep -E "error:|HUNG" "$OUT/build.log" | sort -u | head -30 >&2 || true
    tail -5 "$OUT/build.log" >&2; echo "BUILD FAILED (see $OUT/build.log)"; exit 1
  fi
fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Montage"
[[ -x "$BIN" ]] || { echo "no binary at $BIN (drop --no-build)"; exit 2; }
use_private_tmpdir uitest

# run_one <abs script> <name> → exit code of the app (124 = timeout)
run_one() {
  local abs="$1" name="$2" pid watch code
  rm -rf "$OUT/$name"; mkdir -p "$OUT/$name"
  "$BIN" --uitest "$abs" --uitest-out "$OUT/$name" --baselines "$ROOT/app/Tests/Baselines" ${EXTRA[@]+"${EXTRA[@]}"} < /dev/null &
  pid=$!
  (
    trap - EXIT INT TERM HUP
    sleep "$TIMEOUT"
    kill -0 $pid 2>/dev/null || exit 0
    sample $pid 3 -file "$OUT/$name/hang-sample.txt" >/dev/null 2>&1 || true
    touch "$OUT/$name/.timeout"
    kill_tree $pid
    echo "✘ $name: TIMEOUT (HUNG) after ${TIMEOUT}s — stacks: $OUT/$name/hang-sample.txt"
  ) &
  watch=$!
  set +e; wait $pid; code=$?; set -e
  kill $watch 2>/dev/null || true; wait $watch 2>/dev/null || true
  [[ -f "$OUT/$name/.timeout" ]] && code=124
  return $code
}

PASS=0; FAIL=0; SKIP=0; FAILED=(); SKIPPED=(); FLAKY=(); QUAR=()
for s in "${SCRIPTS[@]}"; do
  [[ -f "$s" ]] || { echo "no such script: $s"; FAIL=$((FAIL + 1)); FAILED+=("$s"); continue; }
  ABS="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
  NAME="$(basename "$s" .json)"
  CODE=0; run_one "$ABS" "$NAME" || CODE=$?
  if [[ $CODE != 0 && $CODE != 3 && $RETRY == 1 ]]; then
    echo "↻ $NAME failed (exit $CODE) — retrying once"
    # let a load spike from other checkouts pass first (≤ MONTAGE_RETRY_WAIT s, default 60): the retry must still pass
    for ((w = 0; w < ${MONTAGE_RETRY_WAIT:-60}; w += 5)); do
      L="$(sysctl -n vm.loadavg | awk '{ printf "%d", $2 }')"
      (( L < $(sysctl -n hw.ncpu) )) && break
      sleep 5
    done
    rm -rf "$OUT/$NAME.attempt1"; mv "$OUT/$NAME" "$OUT/$NAME.attempt1"
    CODE2=0; run_one "$ABS" "$NAME" || CODE2=$?
    if [[ $CODE2 == 0 ]]; then FLAKY+=("$NAME (attempt 1: exit $CODE → $OUT/$NAME.attempt1)"); CODE=0
    else CODE=$CODE2; fi
  fi
  if [[ $CODE == 0 ]]; then PASS=$((PASS + 1))
  elif [[ $CODE == 3 ]]; then SKIP=$((SKIP + 1)); SKIPPED+=("$NAME")
  elif REASON="$(python3 scripts/testlib.py quarantined ui "$NAME")"; then
    QUAR+=("$NAME (exit $CODE) — $REASON → $OUT/$NAME")
  else
    TWICE=""; if [[ $RETRY == 1 ]]; then TWICE=", failed twice"; fi
    FAIL=$((FAIL + 1)); FAILED+=("$NAME (exit $CODE$TWICE) → $OUT/$NAME")
  fi
done
echo "UI tests: $PASS passed, $FAIL failed, $SKIP skipped, ${#FLAKY[@]} flaky (passed on retry), ${#QUAR[@]} quarantined failures"
for f in ${SKIPPED[@]+"${SKIPPED[@]}"}; do echo "  skipped: $f"; done
for f in ${FLAKY[@]+"${FLAKY[@]}"}; do echo "  flaky (passed on retry): $f"; done
for f in ${QUAR[@]+"${QUAR[@]}"}; do echo "  quarantined (failed, not gating): $f"; done
for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  failed: $f"; done
if [[ $FAIL != 0 ]]; then exit 1; fi
exit 0
