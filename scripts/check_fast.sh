#!/bin/bash
# STAGE 1 of the gate — fast incremental check of THIS working tree (committed + uncommitted changes), for iterating.
# Stage 2 (scripts/check_clean.sh --ui: fresh clean checkout, every unit test, every UI script) runs once before merge.
#
#   1. disk check (≥ 5 GB free), quarantine file validation
#   2. scripts/test.sh: l10n check, incremental build, the unit tests (failed tests retried once alone)
#   3. scripts/uitest.sh on the UI scripts relevant to `git diff main...HEAD` + uncommitted changes
#      (scripts/ui_select.py: smoke set + app/Tests/ui_map.txt + test IDs / l10n keys found in changed Swift files)
# One test slot is held for the whole run (scripts/slots.sh).
#
# Usage: scripts/check_fast.sh [--base <ref>] [--unit-filter <regex>] [--no-unit] [--no-ui] [--all-ui] [--list]
#   --base <ref>          diff base (default main)
#   --unit-filter <re>    only these unit tests (swift test --filter); default: all
#   --no-unit / --no-ui   skip a stage
#   --all-ui              every UI script (still incremental, no clean checkout)
#   --list                print the selected UI scripts and why, then exit
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BASE=main; UNIT=1; UIRUN=1; ALLUI=0; LIST=0; UFILTER=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2;;
    --unit-filter) UFILTER=(--filter "$2"); shift 2;;
    --no-unit) UNIT=0; shift;;
    --no-ui) UIRUN=0; shift;;
    --all-ui) ALLUI=1; shift;;
    --list) LIST=1; shift;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
mkdir -p build
SEL="$(python3 scripts/ui_select.py --base "$BASE" --explain 2>build/check_fast-selection.txt)"
if [[ $LIST == 1 ]]; then cat build/check_fast-selection.txt; exit 0; fi

source scripts/lib.sh
require_free_disk || exit 1
source scripts/slots.sh; slots_acquire
START=$(date +%s)
FAIL=0
python3 scripts/testlib.py check-quarantine || FAIL=1
echo "▶ fast check of $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD) vs $BASE ($(git diff --name-only "$BASE"...HEAD | wc -l | tr -d ' ') committed + $(git status --porcelain | wc -l | tr -d ' ') uncommitted changed files)"

if [[ $UNIT == 1 ]]; then
  if scripts/test.sh ${UFILTER[@]+"${UFILTER[@]}"} > build/check_fast-unit.log 2>&1; then
    echo "✔ unit tests ($(grep -oE 'Test run with [0-9]+ tests' build/test.log | head -1); $(tail -1 build/check_fast-unit.log)) — $(( ($(date +%s) - START) / 60 )) min"
  else
    echo "✘ unit tests failed:"; grep -E "^(✘|⚠|TESTS|BUILD|no test summary)|error:|HUNG" build/check_fast-unit.log | head -30 | sed 's/^/  /'
    FAIL=1
  fi
  grep -E "^⚠ (flaky|quarantined)" build/check_fast-unit.log | sed 's/^/    /' || true
fi

if [[ $UIRUN == 1 ]]; then
  if [[ $ALLUI == 1 ]]; then SCRIPTS=(--all); N="$(ls app/Tests/UIScripts/*.json | wc -l | tr -d ' ')"
  else SCRIPTS=(); while IFS= read -r s; do [[ -n "$s" ]] && SCRIPTS+=("$s"); done <<< "$SEL"; N=${#SCRIPTS[@]}; fi
  echo "▶ $N UI script(s) selected ($(tail -1 build/check_fast-selection.txt | sed 's/ selected.*//'); why: build/check_fast-selection.txt)"
  T0=$(date +%s)
  if scripts/uitest.sh "${SCRIPTS[@]}" --out "$ROOT/build/uitest" > build/check_fast-ui.log 2>&1; then
    echo "✔ $(grep -E '^UI tests:' build/check_fast-ui.log | tail -1) — $(( ($(date +%s) - T0) / 60 )) min"
  else
    echo "✘ $(grep -E '^UI tests:|BUILD FAILED' build/check_fast-ui.log | tail -1)"
    grep -E "^✘|^  failed:" build/check_fast-ui.log | head -30 | sed 's/^/  /' || true
    FAIL=1
  fi
  grep -E "^  (flaky|quarantined)" build/check_fast-ui.log || true
fi

ELAPSED="$(( ($(date +%s) - START) / 60 )) min"
if [[ $FAIL == 0 ]]; then
  echo "FAST CHECK OK ($ELAPSED) — before reporting ready to merge: commit, rebase on main, scripts/check_clean.sh --ui"
else
  echo "FAST CHECK FAILED ($ELAPSED; logs: build/check_fast-{unit,ui}.log, build/test.log, build/uitest/<script>/)"; exit 1
fi
