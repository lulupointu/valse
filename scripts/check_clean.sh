#!/bin/bash
# Clean-checkout batch gate: the orchestrator runs it ONCE per batch HEAD (docs/AGENT_GUIDE.md); feature agents don't.
# 1. Fails if any file under app/ or scripts/ is git-ignored. Such files build locally but are never committed
#    (e.g. a `models/` rule silently hid app/Sources/ValseAI/Models on case-insensitive macOS).
# 2. Builds and tests a detached worktree that is exactly HEAD (no untracked / ignored file), so only committed files
#    count. Default: a persistent clean worktree reset to HEAD keeps its .build (incremental build); --cold = a fresh
#    temp worktree and a cold build. Uncommitted changes are NOT part of the check: commit first.
# 3. With --ui, the full unit suite (scripts/test.sh, its usual parallel run) and every UI script (scripts/uitest.sh
#    --all, sharded over --ui-jobs apps) run AT THE SAME TIME: same tests, same retries, ~3x shorter. The gate holds
#    one test slot; UI apps are capped at min(cores × 2/5, RAM GB / 4) (4 on a 10-core 16 GB Mac).
# STAGE 2 of the gate. Feature agents run targeted tests + scripts/check_fast.sh; the orchestrator runs `--ui` per batch.
# Fails fast when < 5 GB are free (VALSE_MIN_FREE_GB). Failed tests are retried once: a unit test alone after the
# suite (test.sh), a UI script right after its failure (uitest.sh) — in the default schedule other UI apps and the unit
# suite may still be running then; --serial retries with nothing else of the gate running.
# Quarantined ones (app/Tests/quarantine.txt) are reported but don't fail. The temp worktree, its build and every UI
# temp dir are deleted on exit, even on failure or Ctrl-C. On success writes build/check_clean.ok (commit, date, mode)
# for scripts/merge_agent.sh.
# Warm cache: cold anyway when the package graph / toolchain changed, after VALSE_WARM_MAX_GATES (20) gates or
# VALSE_WARM_MAX_HOURS (24) h; the reason is printed ("cold: …").
#
# Usage: scripts/check_clean.sh [--build-only] [--ui] [--keep] [--cold] [--serial] [--ui-jobs K]
#   --build-only  build (incl. tests) but don't run scripts/test.sh
#   --ui          also run every UI test script (scripts/uitest.sh --all) and the perf gate (scripts/perf.sh --no-smoke,
#                 exclusive slot, after the unit + UI phases and after this gate released its own slot) in the clean tree
#   --keep        keep the temp worktree (its path is printed; --cold only, the warm one is always kept)
#   --cold        fresh temp worktree + cold build instead of the warm clean worktree
#   --serial      the pre-2026-10-21 schedule: unit tests, THEN the UI scripts one app at a time (slower, same tests)
#   --ui-jobs K   UI apps at once (default VALSE_UI_JOBS or 4, capped as above; 1 = one at a time)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TEST=1; UI=0; KEEP=0; SERIAL=0; UI_JOBS="${VALSE_UI_JOBS:-4}"; COLD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cold) COLD=1; shift;;
    --build-only) TEST=0; shift;;
    --ui) UI=1; shift;;
    --keep) KEEP=1; shift;;
    --serial) SERIAL=1; UI_JOBS=1; shift;;
    --ui-jobs) UI_JOBS="$2"; shift 2;;
    -h|--help) sed -n '2,27p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
[[ "$UI_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--ui-jobs needs a positive integer"; exit 2; }
COLD_WHY=""; USES=0

source scripts/lib.sh
# one slot = "a gate"; the extra UI apps are bounded by the machine instead (lib.sh ui_jobs_cap)
REQ_JOBS=$UI_JOBS; ui_jobs_cap "$REQ_JOBS"
[[ -n "$UI_JOBS_CAP_NOTE" ]] && echo "  (--ui-jobs $REQ_JOBS $UI_JOBS_CAP_NOTE)"
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

TMP="$(mktemp -d -t valse-clean)"
WT="$TMP/wt"
SHA="$(git rev-parse HEAD)"
# Warm mode: a persistent clean worktree per repository (<main checkout>/build/check_clean-cache/wt<N>, one lock each)
# is reset to exactly HEAD — `checkout --force` + `clean -ffdx` (every untracked AND ignored file goes) except its
# .build — then verified pristine; SwiftPM's resource bundles are deleted (it never removes a resource deleted from the
# sources). Unchanged files keep their mtimes, so only what changed since the last gate recompiles.
CACHE_LOCK=""
# Cache locks: a kernel lock (flock) on <lock>.flock, held by a small helper process for the whole gate. The kernel
# releases it when the helper exits (gate done, killed or crashed: the helper exits as soon as its gate is gone), so
# there is no stale lock to reclaim and no reclaim race. A lock DIRECTORY <lock> with a live PID (a pre-flock gate)
# counts as busy.
LOCK_PY='
import fcntl, os, sys, time
f = open(sys.argv[1], "a")
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    print("busy", flush=True); sys.exit(1)
f.truncate(0); f.write(sys.argv[2] + "\n"); f.flush()
print("ok", flush=True); sys.stdout.close()
parent = os.getppid()
while os.getppid() == parent:
    time.sleep(1)
'
LOCK_HOLDER=""
lock_take() { # lock path → 0 if acquired (the helper's PID in LOCK_HOLDER)
  local L="$1" fifo line=""
  if [[ -d "$L" ]] && kill -0 "$(cat "$L/pid" 2>/dev/null || echo 0)" 2>/dev/null; then return 1; fi
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/valse-lockfifo.XXXXXX")"; mkfifo "$fifo"
  python3 -c "$LOCK_PY" "$L.flock" "$$" > "$fifo" 2>/dev/null &
  LOCK_HOLDER=$!
  read -r line < "$fifo" || true; rm -f "$fifo"
  [[ "$line" == ok ]] && return 0
  wait "$LOCK_HOLDER" 2>/dev/null || true; LOCK_HOLDER=""; return 1
}
lock_release() {
  if [[ -n "$LOCK_HOLDER" ]]; then kill "$LOCK_HOLDER" 2>/dev/null; wait "$LOCK_HOLDER" 2>/dev/null; LOCK_HOLDER=""; fi
  return 0
}
if [[ $COLD == 0 ]]; then
  CACHE="$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)/build/check_clean-cache"; mkdir -p "$CACHE"
  for n in 0 1; do
    if lock_take "$CACHE/lock.$n"; then CACHE_LOCK="$CACHE/lock.$n"; WT="$CACHE/wt$n"; break; fi
  done
  [[ -n "$CACHE_LOCK" ]] || { echo "⚠︎ both warm clean worktrees are in use: cold build in a temp worktree"; COLD=1; }
fi
cleanup() {
  if [[ -n "$CACHE_LOCK" ]]; then rm -rf "$TMP"; lock_release "$CACHE_LOCK"; return; fi   # the warm worktree is kept
  if [[ $KEEP == 1 ]]; then echo "kept clean worktree: $WT"; return; fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  git worktree prune >/dev/null 2>&1 || true
}
on_exit cleanup
pristine() { # the worktree is exactly HEAD: no modified, untracked or ignored path except .build/
  [[ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" == "$SHA" ]] &&
    [[ -z "$(git -C "$WT" status --porcelain --ignored=matching --untracked-files=all | grep -v '^!! \.build/')" ]]
}
if [[ -n "$CACHE_LOCK" ]]; then
  if ! { git -C "$WT" checkout --quiet --detach --force "$SHA" && git -C "$WT" clean -ffdxq -e /.build && pristine; } >/dev/null 2>&1; then
    echo "  (warm worktree missing or not resettable to HEAD: recreating it, cold build)"
    [[ -d "$WT" ]] && { git -C "$WT" status --porcelain --ignored=matching --untracked-files=all 2>&1 | grep -v '^!! \.build/' | head -5 | sed 's/^/    /' || true; }
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; git worktree prune
    git worktree add --detach --quiet "$WT" "$SHA"
  fi
  pristine || { echo "✘ the clean worktree $WT is not exactly HEAD"; git -C "$WT" status --short --ignored | head; exit 1; }
  # Leftover build products can hide a broken HEAD: a removed target / dependency keeps its .swiftmodule, so a stale
  # `import A` still compiles. The warm .build is reused only while the package graph (manifest, resolved pins, target
  # folders) and the toolchain are unchanged, and for at most VALSE_WARM_MAX_GATES gates / VALSE_WARM_MAX_HOURS h.
  GATE_KEY="$( { git -C "$WT" show "$SHA:Package.swift"; git -C "$WT" show "$SHA:Package.resolved" 2>/dev/null || true
    git -C "$WT" ls-tree -d --name-only "$SHA" app/Sources/ app/Tests/; swift --version 2>&1; } | shasum -a 256 | cut -c1-64)"
  META="$WT/.build/.gate-meta"; OLD_KEY=""; BORN=0; USES=0
  if [[ -f "$META" ]]; then read -r OLD_KEY BORN USES < "$META" || true; fi
  NOW=$(date +%s); COLD_WHY=""
  if [[ ! -d "$WT/.build" ]]; then COLD_WHY="no warm build yet"
  elif [[ "$OLD_KEY" != "$GATE_KEY" ]]; then COLD_WHY="package graph or toolchain changed (Package.swift / Package.resolved / target folders / swift --version)"
  elif (( NOW - ${BORN:-0} > ${VALSE_WARM_MAX_HOURS:-24} * 3600 )); then COLD_WHY="warm build older than ${VALSE_WARM_MAX_HOURS:-24} h"
  elif (( ${USES:-0} >= ${VALSE_WARM_MAX_GATES:-20} )); then COLD_WHY="warm build served ${USES} gates (max ${VALSE_WARM_MAX_GATES:-20})"
  fi
  if [[ -n "$COLD_WHY" ]]; then echo "  cold: $COLD_WHY"; rm -rf "$WT/.build"; BORN=$NOW; USES=0; fi
  mkdir -p "$WT/.build"; echo "$GATE_KEY $BORN $(( ${USES:-0} + 1 ))" > "$META"
  rm -rf "$WT"/.build/*/debug/*.bundle "$WT"/.build/*/release/*.bundle
else
  git worktree add --detach --quiet "$WT" HEAD
fi
echo "▶ clean worktree of ${SHA:0:7} at $WT$([[ -n "$CACHE_LOCK" && -z "$COLD_WHY" ]] && echo " (warm .build, gate $(( USES + 1 )))")"
# Reuse the bench media (gitignored, large) if present; perf smoke tests stay opt-in anyway.
[[ -e "$ROOT/bench/media" ]] && ln -s "$(cd "$ROOT/bench/media" && pwd -P)" "$WT/bench/media" 2>/dev/null || true
# UI scripts start longest-first using the previous gate's timings (only the order; every script still runs). Kept in
# the MAIN checkout's build/ (batch worktrees come and go; check_fast.sh orders its scripts with it too).
DURATIONS="$(main_checkout)/build/ui-durations.tsv"; mkdir -p "$(dirname "$DURATIONS")"
[[ -f "$DURATIONS" || ! -f "$ROOT/build/check_clean-ui-durations.tsv" ]] || cp "$ROOT/build/check_clean-ui-durations.tsv" "$DURATIONS"

cd "$WT"
mkdir -p "$ROOT/build"
python3 scripts/testlib.py check-quarantine || FAIL=1
# the app binary too (`--build-tests` alone may not link executables): the UI apps then run with --no-build while
# test.sh's own (no-op) build runs
if ! run_watched "$TMP/build.log" bash -c 'swift build --build-tests && swift build --product Valse'; then
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
  # keep the failed AND flaky scripts' reports / PNGs / diffs (the temp tree is deleted on exit): a flake's first
  # attempt is the only evidence to root-cause it from
  rm -rf "$ROOT/build/check_clean-uitest"
  local kept="" n
  for n in $(grep -E "^  (failed|flaky \(passed on retry\)): " "$TMP/ui.log" | sed -E 's/^  (failed|flaky \(passed on retry\)): //' | awk '{print $1}'); do
    mkdir -p "$ROOT/build/check_clean-uitest"
    cp -R "$TMP/uitest/$n" "$TMP/uitest/$n.attempt1" "$ROOT/build/check_clean-uitest/" 2>/dev/null || true
    kept=1
  done
  if [[ $1 == 0 ]]; then echo "✔ clean UI tests ($(grep -E '^UI tests:' "$TMP/ui.log" | tail -1); $2, $UI_JOBS at once)"
  else echo "✘ clean UI tests failed ($2):"; grep -E "^✘|failed:|^UI tests:|BUILD FAILED|no binary" "$TMP/ui.log" | head -30; FAIL=1
  fi
  if [[ $1 != 0 || -n "$kept" ]]; then cp "$TMP/ui.log" "$ROOT/build/check_clean-ui.log" 2>/dev/null || true; fi
  if [[ -n "$kept" ]]; then echo "  failed / flaky scripts' output: $ROOT/build/check_clean-uitest/"; fi
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
PERF_UNVERIFIED=""
if [[ $UI == 1 ]]; then
  # after BOTH phases above have exited (they reuse this gate's slot): perf.sh needs every slot, so ours goes first
  # perf gate (DX-C): wall-clock budgets (unit timing tests, timeline 500 / asset 1000 UI perf) vs bench/perf_thresholds.json,
  # measured with EVERY slot (exclusive, so other teams' runs don't disturb it): release ours, perf.sh queues for all.
  # (the warm-worktree flock helper holds no slot: slots are mkdir dirs owned by this PID, gone after slots_release)
  slots_release; unset VALSE_SLOT_HELD
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
ELAPSED="$(mins "$START")"
if [[ $FAIL == 0 ]]; then
  # gate stamp read by scripts/merge_agent.sh: <commit> <UTC date> <ui|unit|build-only>
  MODE=build-only; [[ $TEST == 1 ]] && MODE=unit; [[ $TEST == 1 && $UI == 1 ]] && MODE=ui; [[ $TEST == 0 && $UI == 1 ]] && MODE=ui-only
  # 4th field (ui mode): perf metrics left unverified by the load rule (merge_agent.sh reads fields 1-3)
  echo "$SHA $(date -u +%Y-%m-%dT%H:%M:%SZ) $MODE${PERF_UNVERIFIED:+ perf-unverified=$PERF_UNVERIFIED}" > "$ROOT/build/check_clean.ok"
  echo "CLEAN CHECKOUT OK ($ELAPSED)"
else
  rm -f "$ROOT/build/check_clean.ok"; echo "CLEAN CHECKOUT FAILED ($ELAPSED)"; exit 1
fi
