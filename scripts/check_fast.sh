#!/bin/bash
# STAGE 1 of the gate — fast incremental check of THIS working tree (committed + uncommitted changes), for feature agents.
# Stage 2 (scripts/check_clean.sh --ui: fresh clean checkout, every unit test, every UI script) runs once per batch.
#
#   1. disk check (≥ 5 GB free), quarantine file validation
#   2. one incremental build (tests + app), then AT THE SAME TIME (like check_clean, same tests, same retries):
#      - scripts/test.sh: l10n check, selector tests, the unit tests (failed tests retried once alone)
#      - scripts/uitest.sh --jobs K on the UI scripts relevant to the diff vs the base + uncommitted changes
#        (scripts/ui_select.py: small smoke set + scripts derived from the changed lines — driver actions, state-dump
#        keys, l10n keys, the test IDs / l10n keys reached from the changed Swift declarations — + ui_map.txt rules);
#        K = VALSE_UI_JOBS or 4, capped like check_clean (lib.sh ui_jobs_cap); heavy (ML) scripts one at a time
# One test slot is held for the whole run (scripts/slots.sh).
# Diff base (default auto): the nearest of main / the local batch-* branches HEAD is based on (most recent merge-base;
# a batch that already contains HEAD doesn't count); the base used is printed.
#
# Usage: scripts/check_fast.sh [--base <ref>|auto] [--unit-filter <regex>] [--no-unit] [--no-ui] [--all-ui] [--list]
#                              [--ui-jobs K] [--serial]
#   --base <ref>          diff base (default auto, see above; e.g. main, batch-3, HEAD~1)
#   --unit-filter <re>    only these unit tests (swift test --filter); default: all
#   --no-unit / --no-ui   skip a stage
#   --all-ui              every UI script (still incremental, no clean checkout)
#   --list                print the selected UI scripts and why, then exit
#   --ui-jobs K           UI apps at once (default VALSE_UI_JOBS or 4, capped; 1 = one at a time)
#   --serial              the old schedule: unit tests, THEN the UI scripts one at a time (slower, same tests)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BASE=auto; UNIT=1; UIRUN=1; ALLUI=0; LIST=0; UFILTER=(); UI_JOBS="${VALSE_UI_JOBS:-4}"; SERIAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2;;
    --unit-filter) UFILTER=(--filter "$2"); shift 2;;
    --no-unit) UNIT=0; shift;;
    --no-ui) UIRUN=0; shift;;
    --all-ui) ALLUI=1; shift;;
    --list) LIST=1; shift;;
    --ui-jobs) UI_JOBS="$2"; shift 2;;
    --serial) SERIAL=1; UI_JOBS=1; shift;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
[[ "$UI_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--ui-jobs needs a positive integer"; exit 2; }
mkdir -p build
SEL="$(python3 scripts/ui_select.py --base "$BASE" --explain 2>build/check_fast-selection.txt)"
BASE_NOTE="$(sed -n 's/^diff base: //p' build/check_fast-selection.txt | head -1)"; BASE_REF="${BASE_NOTE%% *}"
if [[ $LIST == 1 ]]; then cat build/check_fast-selection.txt; exit 0; fi

source scripts/lib.sh
require_free_disk || exit 1
source scripts/slots.sh; slots_acquire
START=$(date +%s)
mins() { echo "$(( ($(date +%s) - $1 + 30) / 60 )) min"; }
FAIL=0
python3 scripts/testlib.py check-quarantine || FAIL=1
echo "▶ fast check of $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD) vs ${BASE_NOTE:-$BASE} ($(git diff --name-only "${BASE_REF:-main}"...HEAD | wc -l | tr -d ' ') committed + $(git status --porcelain | wc -l | tr -d ' ') uncommitted changed files)"

if [[ $UIRUN == 1 ]]; then
  if [[ $ALLUI == 1 ]]; then SCRIPTS=(--all); N="$(ls app/Tests/UIScripts/*.json | wc -l | tr -d ' ')"
  else SCRIPTS=(); while IFS= read -r s; do [[ -n "$s" ]] && SCRIPTS+=("$s"); done <<< "$SEL"; N=${#SCRIPTS[@]}; fi
  REQ_JOBS=$UI_JOBS; ui_jobs_cap "$REQ_JOBS"
  (( UI_JOBS > N && N > 0 )) && UI_JOBS=$N
  echo "▶ $N UI script(s) selected ($(tail -1 build/check_fast-selection.txt | sed 's/ selected.*//'); why: build/check_fast-selection.txt), $UI_JOBS at once${UI_JOBS_CAP_NOTE:+ (--ui-jobs $REQ_JOBS $UI_JOBS_CAP_NOTE)}"
fi
# longest scripts first: this checkout's last check_fast timings, else the last batch gate's (main checkout)
ORDER="$ROOT/build/check_fast-ui-durations.tsv"; [[ -f "$ORDER" ]] || ORDER="$(main_checkout)/build/ui-durations.tsv"

# ---- phases (like check_clean.sh): run_<phase> starts it, report_<phase> prints its verdict ----
run_unit() { local rc=0; scripts/test.sh ${UFILTER[@]+"${UFILTER[@]}"} > build/check_fast-unit.log 2>&1 || rc=$?; date +%s > build/.check_fast-unit.end; return $rc; }
report_unit() { # rc duration
  if [[ $1 == 0 ]]; then
    echo "✔ unit tests ($(grep -oE 'Test run with [0-9]+ tests' build/test.log | head -1); $(tail -1 build/check_fast-unit.log)) — $2"
  else
    echo "✘ unit tests failed ($2):"; grep -E "^(✘|⚠|TESTS|BUILD|no test summary|ui_select)|error:|HUNG" build/check_fast-unit.log | head -30 | sed 's/^/  /'
    FAIL=1
  fi
  grep -E "^⚠ (flaky|quarantined)" build/check_fast-unit.log | sed 's/^/    /' || true
}
run_ui() { # [--no-build]
  local rc=0 ord=()
  [[ -f "$ORDER" ]] && ord=(--order "$ORDER")
  scripts/uitest.sh "$@" ${SCRIPTS[@]+"${SCRIPTS[@]}"} --jobs "$UI_JOBS" ${ord[@]+"${ord[@]}"} --out "$ROOT/build/uitest" > build/check_fast-ui.log 2>&1 || rc=$?
  # this checkout's timings (merged into the previous ones: a subset run keeps the others)
  if [[ -f build/uitest/durations.tsv ]]; then
    { cat build/uitest/durations.tsv; [[ -f build/check_fast-ui-durations.tsv ]] && cat build/check_fast-ui-durations.tsv; } |
      awk -F'\t' '!seen[$1]++' > build/.check_fast-durations.tmp && mv build/.check_fast-durations.tmp build/check_fast-ui-durations.tsv
  fi
  return $rc
}
report_ui() { # rc duration
  if [[ $1 == 0 ]]; then
    echo "✔ $(grep -E '^UI tests:' build/check_fast-ui.log | tail -1) — $2"
  else
    echo "✘ $(grep -E '^UI tests:|BUILD FAILED|no binary' build/check_fast-ui.log | tail -1) — $2"
    grep -E "^✘|^  failed:" build/check_fast-ui.log | head -30 | sed 's/^/  /' || true
    FAIL=1
  fi
  grep -E "^  (flaky|quarantined|⚠ slow expect|⚠ click warning)" build/check_fast-ui.log || true
}

if [[ $UNIT == 1 && $UIRUN == 1 && $SERIAL == 0 ]]; then
  # one build first (tests + app: the UI apps then run with --no-build while test.sh's own build is a no-op), then the
  # unit suite and the UI scripts at the same time (both load-robust, docs/TESTING.md); each keeps its own retries
  if ! run_watched build/check_fast-build.log bash -c 'swift build --build-tests && swift build --product Valse'; then
    echo "✘ build failed:"; grep -E "error:|HUNG" build/check_fast-build.log | sort -u | head -30 | sed 's/^/  /'
    echo "FAST CHECK FAILED ($(mins "$START"); log: build/check_fast-build.log)"; exit 1
  fi
  echo "✔ build ($(mins "$START"))"
  T0=$(date +%s)
  run_unit & UNIT_PID=$!
  run_ui --no-build & UI_PID=$!
  on_exit "kill_tree $UNIT_PID >/dev/null 2>&1; kill_tree $UI_PID >/dev/null 2>&1"
  UI_RC=0; wait "$UI_PID" || UI_RC=$?; UI_T="$(mins "$T0")"
  UNIT_RC=0; wait "$UNIT_PID" || UNIT_RC=$?
  UNIT_T="$(( ($(cat build/.check_fast-unit.end 2>/dev/null || date +%s) - T0 + 30) / 60 )) min"
  report_unit "$UNIT_RC" "$UNIT_T"
  report_ui "$UI_RC" "$UI_T"
else
  if [[ $UNIT == 1 ]]; then T0=$(date +%s); RC=0; run_unit || RC=$?; report_unit "$RC" "$(mins "$T0")"; fi
  if [[ $UIRUN == 1 ]]; then T0=$(date +%s); RC=0; run_ui || RC=$?; report_ui "$RC" "$(mins "$T0")"; fi
fi

ELAPSED="$(mins "$START")"
if [[ $FAIL == 0 ]]; then
  echo "FAST CHECK OK ($ELAPSED) — feature agents: commit and report ready (the orchestrator runs check_clean.sh --ui per batch)"
else
  echo "FAST CHECK FAILED ($ELAPSED; logs: build/check_fast-{unit,ui}.log, build/test.log, build/uitest/<script>/)"; exit 1
fi
