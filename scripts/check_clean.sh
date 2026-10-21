#!/bin/bash
# Clean-checkout gate: run before reporting "ready to merge" (docs/AGENT_GUIDE.md).
# 1. Fails if any file under app/ or scripts/ is git-ignored. Such files build locally but are never committed
#    (e.g. a `models/` rule silently hid app/Sources/MontageAI/Models on case-insensitive macOS).
# 2. Builds and tests a fresh detached worktree of HEAD in a temp dir, so only committed files count.
#    Uncommitted changes are NOT part of the check: commit first.
# This is STAGE 2 of the gate (run once, just before "ready to merge"); while iterating use scripts/check_fast.sh.
# Fails fast when < 5 GB are free (MONTAGE_MIN_FREE_GB). Failed tests are retried once alone (test.sh / uitest.sh);
# quarantined ones (app/Tests/quarantine.txt) are reported but don't fail. The temp worktree, its build and every UI
# temp dir are deleted on exit, even on failure or Ctrl-C. On success writes build/check_clean.ok (commit, date, mode)
# for scripts/merge_agent.sh.
#
# Usage: scripts/check_clean.sh [--build-only] [--ui] [--keep]
#   --build-only  build (incl. tests) but don't run scripts/test.sh
#   --ui          also run every UI test script (scripts/uitest.sh --all) and the perf gate (scripts/perf.sh --no-smoke,
#                 exclusive slot) in the clean tree
#   --keep        keep the temp worktree (its path is printed)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TEST=1; UI=0; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) TEST=0; shift;;
    --ui) UI=1; shift;;
    --keep) KEEP=1; shift;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done

source scripts/lib.sh
# fail fast on a full disk (a clean build + UI exports need several GB)
require_free_disk || exit 1
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh); nested test.sh/uitest.sh reuse it
source scripts/slots.sh; slots_acquire
START=$(date +%s)

FAIL=0
IGNORED="$(git ls-files -o -i --exclude-standard -- app scripts)"
if [[ -n "$IGNORED" ]]; then
  echo "✘ git-ignored files under app/ or scripts/ (they will never be committed; fix .gitignore or move them):"
  echo "$IGNORED" | sed 's/^/    /'
  FAIL=1
fi
UNTRACKED="$(git ls-files -o --exclude-standard -- app scripts docs Package.swift)"
if [[ -n "$UNTRACKED" ]]; then
  echo "⚠︎ untracked files (not in HEAD, so not in the clean build — commit them if they matter):"
  echo "$UNTRACKED" | sed 's/^/    /'
fi
if ! git diff --quiet HEAD -- app scripts Package.swift; then
  echo "⚠︎ uncommitted changes under app/ scripts/ Package.swift are not part of this check"
fi

TMP="$(mktemp -d -t montage-clean)"
WT="$TMP/wt"
cleanup() {
  if [[ $KEEP == 1 ]]; then echo "kept clean worktree: $WT"; return; fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  git worktree prune >/dev/null 2>&1 || true
}
on_exit cleanup
git worktree add --detach --quiet "$WT" HEAD
echo "▶ clean worktree of $(git rev-parse --short HEAD) at $WT"
# Reuse the bench media (gitignored, large) if present; perf smoke tests stay opt-in anyway.
[[ -e "$ROOT/bench/media" ]] && ln -s "$(cd "$ROOT/bench/media" && pwd -P)" "$WT/bench/media" 2>/dev/null || true

cd "$WT"
mkdir -p "$ROOT/build"
python3 scripts/testlib.py check-quarantine || FAIL=1
if ! run_watched "$TMP/build.log" swift build --build-tests; then
  echo "✘ clean build failed:"; grep -E "error:|HUNG" "$TMP/build.log" | sort -u | head -30
  cp "$TMP/build.log" "$ROOT/build/check_clean-build.log" 2>/dev/null || true
  exit 1
fi
echo "✔ clean build ($(( ($(date +%s) - START) / 60 )) min)"
if [[ $TEST == 1 ]]; then
  if scripts/test.sh >"$TMP/test.log" 2>&1; then
    echo "✔ clean tests ($(grep -oE 'Test run with [0-9]+ tests' build/test.log | head -1); $(tail -1 "$TMP/test.log"))"
  else
    echo "✘ clean tests failed:"; grep -E "✘|error:|HUNG" build/test.log | head -30
    grep -E "^(✘|⚠|TESTS|no test summary|BUILD)" "$TMP/test.log" | sed 's/^/  /' || true
    cp build/test.log "$ROOT/build/check_clean-test.log" 2>/dev/null || true
    cp build/test-retry.log "$ROOT/build/check_clean-test-retry.log" 2>/dev/null || true
    FAIL=1
  fi
  grep -E "^⚠ (flaky|quarantined)" "$TMP/test.log" | sed 's/^/    /' || true
fi
if [[ $UI == 1 ]]; then
  if scripts/uitest.sh --all --out "$TMP/uitest" >"$TMP/ui.log" 2>&1; then echo "✔ clean UI tests ($(grep -E '^UI tests:' "$TMP/ui.log" | tail -1))"
  else echo "✘ clean UI tests failed:"; grep -E "^✘|failed:|^UI tests:|BUILD FAILED" "$TMP/ui.log" | head -30; FAIL=1
    cp "$TMP/ui.log" "$ROOT/build/check_clean-ui.log" 2>/dev/null || true
    # keep the failed scripts' reports / PNGs (the temp tree is deleted on exit)
    rm -rf "$ROOT/build/check_clean-uitest"; mkdir -p "$ROOT/build/check_clean-uitest"
    for n in $(grep -E "^  failed: " "$TMP/ui.log" | awk '{print $2}'); do
      cp -R "$TMP/uitest/$n" "$TMP/uitest/$n.attempt1" "$ROOT/build/check_clean-uitest/" 2>/dev/null || true
    done
    echo "  failed scripts' output: $ROOT/build/check_clean-uitest/"
  fi
  grep -E "^⏭|skipped:|flaky|quarantined \(" "$TMP/ui.log" | sed 's/^/    /' || true
fi
if [[ $UI == 1 ]]; then
  # perf gate (DX-C): wall-clock budgets (unit timing tests, timeline 500 / asset 1000 UI perf) vs bench/perf_thresholds.json,
  # measured with EVERY slot (exclusive, so other teams' runs don't disturb it): release ours, perf.sh queues for all.
  slots_release; unset MONTAGE_SLOT_HELD
  PERF_UNVERIFIED=""
  if scripts/perf.sh --no-smoke --out "$TMP/perf.json" >"$TMP/perf.log" 2>&1; then echo "✔ clean perf gate (scripts/perf.sh --no-smoke)"
  else echo "✘ clean perf gate failed:"; python3 -c 'import json,sys; [print("    " + v) for v in json.load(open(sys.argv[1])).get("violations", [])]' "$TMP/perf.json" 2>/dev/null || tail -5 "$TMP/perf.log"
    cp "$TMP/perf.log" "$ROOT/build/check_clean-perf.log" 2>/dev/null || true; FAIL=1
  fi
  PERF_UNVERIFIED="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("unreliable", [])))' "$TMP/perf.json" 2>/dev/null || echo 0)"
  [[ "$PERF_UNVERIFIED" == 0 ]] && PERF_UNVERIFIED=""
  if [[ -n "$PERF_UNVERIFIED" ]]; then
    echo "⚠ perf: $PERF_UNVERIFIED metrics unverified due to load (wall-clock / GPU-time; see build/check_clean-perf.log)"
    cp "$TMP/perf.log" "$ROOT/build/check_clean-perf.log" 2>/dev/null || true
  fi
fi
ELAPSED="$(( ($(date +%s) - START) / 60 )) min"
if [[ $FAIL == 0 ]]; then
  # gate stamp read by scripts/merge_agent.sh: <commit> <UTC date> <ui|unit|build-only>
  MODE=build-only; [[ $TEST == 1 ]] && MODE=unit; [[ $TEST == 1 && $UI == 1 ]] && MODE=ui; [[ $TEST == 0 && $UI == 1 ]] && MODE=ui-only
  # 4th field (ui mode): perf metrics left unverified by the load rule (merge_agent.sh reads fields 1-3)
  echo "$(git rev-parse HEAD) $(date -u +%Y-%m-%dT%H:%M:%SZ) $MODE${PERF_UNVERIFIED:+ perf-unverified=$PERF_UNVERIFIED}" > "$ROOT/build/check_clean.ok"
  echo "CLEAN CHECKOUT OK ($ELAPSED)"
else
  rm -f "$ROOT/build/check_clean.ok"; echo "CLEAN CHECKOUT FAILED ($ELAPSED)"; exit 1
fi
