#!/bin/bash
# Runs the localization completeness check + all tests.
# Usage: scripts/test.sh [--perf] [--no-retry] [extra swift test args, e.g. --filter RenderTests]
#   --perf      also run the 4K perf smoke tests (needs bench/media, see bench/make_media.sh)
#   --no-retry  don't retry failed tests (default: every failed test is re-run ONCE, alone)
# A test that fails, then passes alone on the retry, is reported "flaky (passed on retry)" and does not fail the run.
# A test that fails twice fails the run unless it is listed in app/Tests/quarantine.txt (then it is reported only).
# Hang watchdog: no new output and ~0 % CPU for MONTAGE_HANG_MINUTES (default 10) → stacks (`sample`) appended to
# build/test.log, the run is killed and fails with "HUNG". Tests run with a private TMPDIR, removed on exit.
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,9p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
ARGS=(); RETRY=1
for a in "$@"; do
  case "$a" in
    --perf) export MONTAGE_PERF=1;;
    --no-retry) RETRY=0;;
    *) ARGS+=("$a");;
  esac
done
mkdir -p build  # gitignored: absent in a fresh checkout
source scripts/lib.sh
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh)
source scripts/slots.sh; slots_acquire
python3 scripts/l10n_check.py
if ! run_watched build/build.log swift build --build-tests; then
  grep -E "error:|HUNG" build/build.log | sort -u | head -30 >&2 || true
  tail -5 build/build.log >&2
  echo "BUILD FAILED (see build/build.log)"; exit 1
fi
use_private_tmpdir test

LOG=build/test.log; XML=build/test-xunit.xml; XST=build/test-xunit-swift-testing.xml
PAT="✘|✔ Test run|error:|metric|HUNG"
rm -f "$XST" build/test-retry.log
: > "$LOG"
tail -n +1 -f "$LOG" > >(grep --line-buffered -E "$PAT" || true) &
TAILP=$!
set +e
run_watched "$LOG" swift test --skip-build --xunit-output "$XML" ${ARGS[@]+"${ARGS[@]}"}
CODE=$?
set -e
sleep 1; kill "$TAILP" 2>/dev/null || true; wait "$TAILP" 2>/dev/null || true

if [[ $CODE == 124 ]]; then
  echo "TESTS HUNG (see build/test.log: process tree + sample stacks at the end)"; exit 1
fi
if ! grep -qE "Test run with [0-9]+ tests? " "$LOG"; then
  echo "no test summary found — the test process crashed or was killed (exit $CODE; see build/test.log)"
  grep -E "^◇ Test .* started" "$LOG" | tail -3 | sed 's/^/  last started: /' || true
  exit 1
fi
if grep -qE "Test run with [0-9]+ tests? .*passed" "$LOG" && ! grep -qE "✘|error:" "$LOG"; then
  echo "ALL GREEN"; exit 0
fi

# Failures: retry each failed test once, alone.
FAILED_LIST="$(python3 scripts/testlib.py unit-failures "$XST" 2>/dev/null || true)"
if [[ -z "$FAILED_LIST" ]]; then
  echo "TESTS FAILED (no failing test in the xUnit report to retry; see build/test.log)"; exit 1
fi
FLAKY=(); HARD=(); QUAR=()
while IFS=$'\t' read -r ID FILTER REASON; do
  [[ -z "$ID" ]] && continue
  if [[ $RETRY == 1 ]]; then
    echo "↻ retrying $ID alone…"
    RX="build/test-retry-xunit.xml"; rm -f "build/test-retry-xunit-swift-testing.xml"
    { echo "===== retry $ID ($FILTER)"; } >> build/test-retry.log
    set +e
    run_watched build/test-retry.one.log swift test --skip-build --xunit-output "$RX" --filter "$FILTER"
    RC=$?
    set -e
    cat build/test-retry.one.log >> build/test-retry.log
    if [[ $RC == 0 ]] && python3 scripts/testlib.py passed "build/test-retry-xunit-swift-testing.xml"; then
      FLAKY+=("$ID"); continue
    fi
  fi
  if [[ "$REASON" != "-" ]]; then QUAR+=("$ID — $REASON"); else HARD+=("$ID"); fi
done <<< "$FAILED_LIST"

for t in ${FLAKY[@]+"${FLAKY[@]}"}; do echo "⚠ flaky (passed on retry): $t"; done
for t in ${QUAR[@]+"${QUAR[@]}"}; do echo "⚠ quarantined (failed$([[ $RETRY == 1 ]] && echo " twice"), not gating): $t"; done
for t in ${HARD[@]+"${HARD[@]}"}; do echo "✘ failed$([[ $RETRY == 1 ]] && echo " twice (also alone)"): $t"; done
if [[ ${#HARD[@]} -gt 0 ]]; then
  echo "TESTS FAILED (${#HARD[@]} failed; see build/test.log, retries in build/test-retry.log)"; exit 1
fi
echo "ALL GREEN (${#FLAKY[@]} flaky passed on retry, ${#QUAR[@]} quarantined failures)"
