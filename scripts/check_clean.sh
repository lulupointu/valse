#!/bin/bash
# Clean-checkout batch gate: the orchestrator runs it ONCE per batch HEAD (docs/AGENT_GUIDE.md); feature agents don't.
# 1. Fails if any file under app/ or scripts/ is git-ignored. Such files build locally but are never committed
#    (e.g. a `models/` rule silently hid app/Sources/MontageAI/Models on case-insensitive macOS).
# 2. Builds and tests a detached worktree that is exactly HEAD (no untracked / ignored file), so only committed files
#    count. Default: a persistent clean worktree reset to HEAD keeps its .build (incremental build); --cold = a fresh
#    temp worktree and a cold build. Uncommitted changes are NOT part of the check: commit first.
# 3. With --ui, the full unit suite (scripts/test.sh, its usual parallel run) and every UI script (scripts/uitest.sh
#    --all, sharded over --ui-jobs apps) run AT THE SAME TIME: same tests, same retries, ~2x shorter.
# STAGE 2 of the gate. Feature agents run targeted tests + scripts/check_fast.sh; the orchestrator runs `--ui` per batch.
# Fails fast when < 5 GB are free (MONTAGE_MIN_FREE_GB). Failed tests are retried once alone (test.sh / uitest.sh);
# quarantined ones (app/Tests/quarantine.txt) are reported but don't fail. The temp worktree, its build and every UI
# temp dir are deleted on exit, even on failure or Ctrl-C. On success writes build/check_clean.ok (commit, date, mode)
# for scripts/merge_agent.sh.
#
# Usage: scripts/check_clean.sh [--build-only] [--ui] [--keep] [--cold] [--serial] [--ui-jobs K]
#   --build-only  build (incl. tests) but don't run scripts/test.sh
#   --ui          also run every UI test script (scripts/uitest.sh --all) in the clean tree
#   --keep        keep the temp worktree (its path is printed; --cold only, the warm one is always kept)
#   --cold        fresh temp worktree + cold build instead of the warm clean worktree
#   --serial      the pre-2026-10-21 schedule: unit tests, THEN the UI scripts one app at a time (slower, same tests)
#   --ui-jobs K   UI apps at once (default MONTAGE_UI_JOBS or 4; 1 = one at a time)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TEST=1; UI=0; KEEP=0; SERIAL=0; UI_JOBS="${MONTAGE_UI_JOBS:-4}"; COLD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cold) COLD=1; shift;;
    --build-only) TEST=0; shift;;
    --ui) UI=1; shift;;
    --keep) KEEP=1; shift;;
    --serial) SERIAL=1; UI_JOBS=1; shift;;
    --ui-jobs) UI_JOBS="$2"; shift 2;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done

source scripts/lib.sh
# fail fast on a full disk (a clean build + UI exports need several GB)
require_free_disk || exit 1
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh); nested test.sh/uitest.sh reuse it
source scripts/slots.sh; slots_acquire
START=$(date +%s)
mins() { echo "$(( ($(date +%s) - $1 + 30) / 60 )) min"; }

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
SHA="$(git rev-parse HEAD)"
# Warm mode: a persistent clean worktree per repository (<main checkout>/build/check_clean-cache/wt<N>, one lock each)
# is reset to exactly HEAD — `checkout --force` + `clean -ffdx` (every untracked AND ignored file goes) except its
# .build — then verified pristine; SwiftPM's resource bundles are deleted (it never removes a resource deleted from the
# sources). Unchanged files keep their mtimes, so only what changed since the last gate recompiles.
CACHE_LOCK=""
if [[ $COLD == 0 ]]; then
  CACHE="$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)/build/check_clean-cache"; mkdir -p "$CACHE"
  for n in 0 1; do
    L="$CACHE/lock.$n"
    if [[ -d "$L" ]] && ! kill -0 "$(cat "$L/pid" 2>/dev/null || echo 0)" 2>/dev/null; then rm -rf "$L"; fi  # dead holder
    if mkdir "$L" 2>/dev/null; then echo $$ > "$L/pid"; CACHE_LOCK="$L"; WT="$CACHE/wt$n"; break; fi
  done
  [[ -n "$CACHE_LOCK" ]] || { echo "⚠︎ both warm clean worktrees are in use: cold build in a temp worktree"; COLD=1; }
fi
cleanup() {
  if [[ -n "$CACHE_LOCK" ]]; then rm -rf "$TMP" "$CACHE_LOCK"; return; fi   # the warm worktree is the cache: kept
  if [[ $KEEP == 1 ]]; then echo "kept clean worktree: $WT"; return; fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  git worktree prune >/dev/null 2>&1 || true
}
on_exit cleanup
pristine() { # the worktree is exactly HEAD: no modified, untracked or ignored path except .build/
  [[ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" == "$SHA" ]] &&
    [[ -z "$(git -C "$WT" status --porcelain --ignored --untracked-files=all | grep -vxF '!! .build/')" ]]
}
if [[ -n "$CACHE_LOCK" ]]; then
  if ! { git -C "$WT" checkout --quiet --detach --force "$SHA" && git -C "$WT" clean -ffdxq -e /.build && pristine; } >/dev/null 2>&1; then
    echo "  (warm worktree missing or unusable: recreating it, cold build)"
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; git worktree prune
    git worktree add --detach --quiet "$WT" "$SHA"
  fi
  pristine || { echo "✘ the clean worktree $WT is not exactly HEAD"; git -C "$WT" status --short --ignored | head; exit 1; }
  rm -rf "$WT"/.build/*/debug/*.bundle "$WT"/.build/*/release/*.bundle
else
  git worktree add --detach --quiet "$WT" HEAD
fi
echo "▶ clean worktree of $(git rev-parse --short HEAD) at $WT$([[ -n "$CACHE_LOCK" ]] && echo " (warm .build)")"
# Reuse the bench media (gitignored, large) if present; perf smoke tests stay opt-in anyway.
[[ -e "$ROOT/bench/media" ]] && ln -s "$(cd "$ROOT/bench/media" && pwd -P)" "$WT/bench/media" 2>/dev/null || true
# UI scripts start longest-first using the previous gate's timings (only the order; every script still runs)
DURATIONS="$ROOT/build/check_clean-ui-durations.tsv"

cd "$WT"
mkdir -p "$ROOT/build"
python3 scripts/testlib.py check-quarantine || FAIL=1
# the app binary too (`--build-tests` alone may not link executables): the UI apps then run with --no-build while
# test.sh's own (no-op) build runs
if ! run_watched "$TMP/build.log" bash -c 'swift build --build-tests && swift build --product Montage'; then
  echo "✘ clean build failed:"; grep -E "error:|HUNG" "$TMP/build.log" | sort -u | head -30
  cp "$TMP/build.log" "$ROOT/build/check_clean-build.log" 2>/dev/null || true
  exit 1
fi
echo "✔ clean build ($(mins "$START"))"

# ---- phases: each is started by run_<phase>, its verdict printed by report_<phase> ----
run_unit() { local rc=0; scripts/test.sh >"$TMP/test.log" 2>&1 || rc=$?; date +%s > "$TMP/unit.end"; return $rc; }
report_unit() { # rc
  if [[ $1 == 0 ]]; then
    echo "✔ clean tests ($(grep -oE 'Test run with [0-9]+ tests' build/test.log | head -1); $(tail -1 "$TMP/test.log"); $2)"
  else
    echo "✘ clean tests failed ($2):"; grep -E "✘|error:|HUNG" build/test.log | head -30
    grep -E "^(✘|⚠|TESTS|no test summary|BUILD)" "$TMP/test.log" | sed 's/^/  /' || true
    cp build/test.log "$ROOT/build/check_clean-test.log" 2>/dev/null || true
    cp build/test-retry.log "$ROOT/build/check_clean-test-retry.log" 2>/dev/null || true
    FAIL=1
  fi
  grep -E "^⚠ (flaky|quarantined)" "$TMP/test.log" | sed 's/^/    /' || true
}
run_ui() {
  scripts/uitest.sh --all --no-build --jobs "$UI_JOBS" --order "$DURATIONS" --out "$TMP/uitest" >"$TMP/ui.log" 2>&1
}
report_ui() { # rc
  if [[ $1 == 0 ]]; then echo "✔ clean UI tests ($(grep -E '^UI tests:' "$TMP/ui.log" | tail -1); $2, $UI_JOBS at once)"
  else echo "✘ clean UI tests failed ($2):"; grep -E "^✘|failed:|^UI tests:|BUILD FAILED|no binary" "$TMP/ui.log" | head -30; FAIL=1
    cp "$TMP/ui.log" "$ROOT/build/check_clean-ui.log" 2>/dev/null || true
    # keep the failed scripts' reports / PNGs (the temp tree is deleted on exit)
    rm -rf "$ROOT/build/check_clean-uitest"; mkdir -p "$ROOT/build/check_clean-uitest"
    for n in $(grep -E "^  failed: " "$TMP/ui.log" | awk '{print $2}'); do
      cp -R "$TMP/uitest/$n" "$TMP/uitest/$n.attempt1" "$ROOT/build/check_clean-uitest/" 2>/dev/null || true
    done
    echo "  failed scripts' output: $ROOT/build/check_clean-uitest/"
  fi
  grep -E "^⏭|skipped:|flaky|quarantined \(" "$TMP/ui.log" | sed 's/^/    /' || true
  cp "$TMP/uitest/durations.tsv" "$DURATIONS" 2>/dev/null || true
}

if [[ $TEST == 1 && $UI == 1 && $SERIAL == 0 ]]; then
  # unit suite and UI scripts at the same time (both are load-robust: docs/TESTING.md); each keeps its own retries
  T0=$(date +%s)
  run_unit & UNIT_PID=$!
  run_ui & UI_PID=$!
  on_exit "kill_tree $UNIT_PID >/dev/null 2>&1; kill_tree $UI_PID >/dev/null 2>&1"
  UI_RC=0; wait "$UI_PID" || UI_RC=$?; UI_T="$(mins "$T0")"
  UNIT_RC=0; wait "$UNIT_PID" || UNIT_RC=$?
  UNIT_T="$(( ($(cat "$TMP/unit.end" 2>/dev/null || date +%s) - T0 + 30) / 60 )) min"
  report_unit "$UNIT_RC" "$UNIT_T"
  report_ui "$UI_RC" "$UI_T"
else
  if [[ $TEST == 1 ]]; then T0=$(date +%s); RC=0; run_unit || RC=$?; report_unit "$RC" "$(mins "$T0")"; fi
  if [[ $UI == 1 ]]; then T0=$(date +%s); RC=0; run_ui || RC=$?; report_ui "$RC" "$(mins "$T0")"; fi
fi
ELAPSED="$(mins "$START")"
if [[ $FAIL == 0 ]]; then
  # gate stamp read by scripts/merge_agent.sh: <commit> <UTC date> <ui|unit|build-only>
  MODE=build-only; [[ $TEST == 1 ]] && MODE=unit; [[ $TEST == 1 && $UI == 1 ]] && MODE=ui; [[ $TEST == 0 && $UI == 1 ]] && MODE=ui-only
  echo "$(git rev-parse HEAD) $(date -u +%Y-%m-%dT%H:%M:%SZ) $MODE" > "$ROOT/build/check_clean.ok"
  echo "CLEAN CHECKOUT OK ($ELAPSED)"
else
  rm -f "$ROOT/build/check_clean.ok"; echo "CLEAN CHECKOUT FAILED ($ELAPSED)"; exit 1
fi
