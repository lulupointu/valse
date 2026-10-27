#!/bin/bash
# Runs UI test scripts (JSON DSL, docs/TESTING.md) inside the real app, in an OFFSCREEN window that is never activated:
# no Screen Recording / Accessibility permission needed, the real mouse/keyboard/screen are never touched.
#
# Usage: scripts/uitest.sh [options] <script.json>...     (or --all = every app/Tests/UIScripts/*.json)
#   --all                 run every script in app/Tests/UIScripts
#   --update-baselines    rewrite screenshot baselines (app/Tests/Baselines) instead of comparing
#   --release             use a release build (default: debug build, faster to compile)
#   --no-build            don't rebuild
#   --timeout <s>         per-script HANG bound (default 120): an app whose driver made no progress (heartbeat) for <s>
#                         is `sample`d (<out>/<name>/hang-sample.txt) and killed; a slow but progressing script is not
#                         (total ceiling VALSE_UITEST_MAX_SECONDS, default 1800)
#   --out <dir>           output root (default build/uitest); each script writes <out>/<name>/{report.json,final.json,*.png}
#   --no-retry            don't retry failed scripts (default: a failed script is re-run ONCE; the first attempt is kept
#                         in <out>/<name>.attempt1)
#   --jobs <K>            run K apps at once (default 1, or VALSE_UI_JOBS); each worker has its own TMPDIR, every app its
#                         own settings domain / pasteboard / sandbox (ValseCore AppDefaults), so scripts can't interact
#   --order <tsv>         a previous <out>/durations.tsv: start the longest scripts first (better --jobs balance)
#   With --jobs, HEAVY scripts (`"requires": {"models": …}` = real ML inference, or `"heavy": true`) start first and
#   run mutually exclusive (at most one at a time; the other workers take light scripts meanwhile).
# Exit code: 0 if every script passed, was SKIPPED (unmet precondition, e.g. a missing AI model: app exit code 3), passed
#            on its retry ("flaky") or is quarantined (app/Tests/quarantine.txt: reported, not gating);
#            1 if any other script failed or timed out twice.
# The apps run with a private TMPDIR (sandboxes, exports, project copies) that is deleted on exit, even on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG=debug; BUILD=1; TIMEOUT=120; OUT="$ROOT/build/uitest"; EXTRA=(); SCRIPTS=(); RETRY=1
JOBS="${VALSE_UI_JOBS:-1}"; ORDER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) for f in app/Tests/UIScripts/*.json; do SCRIPTS+=("$f"); done; shift;;
    --update-baselines) EXTRA+=(--update-baselines); RETRY=0; shift;;
    --release) CONFIG=release; shift;;
    --no-build) BUILD=0; shift;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-retry) RETRY=0; shift;;
    --jobs) JOBS="$2"; shift 2;;
    --order) ORDER="$2"; shift 2;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) SCRIPTS+=("$1"); shift;;
  esac
done
[[ ${#SCRIPTS[@]} -gt 0 ]] || { sed -n '2,24p' "$0"; exit 2; }
MAX_SECONDS="${VALSE_UITEST_MAX_SECONDS:-1800}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs needs a positive integer"; exit 2; }
source scripts/lib.sh
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh)
source scripts/slots.sh; slots_acquire
mkdir -p "$OUT"; rm -f "$OUT/durations.tsv"
if [[ $BUILD == 1 ]]; then
  if ! run_watched "$OUT/build.log" swift build -c "$CONFIG" --product Valse; then
    grep -E "error:|HUNG" "$OUT/build.log" | sort -u | head -30 >&2 || true
    tail -5 "$OUT/build.log" >&2; echo "BUILD FAILED (see $OUT/build.log)"; exit 1
  fi
fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Valse"
[[ -x "$BIN" ]] || { echo "no binary at $BIN (drop --no-build)"; exit 2; }
use_private_tmpdir uitest
# demo media (ValseUI DemoProject) encoded once per run and shared by every app of it, all workers included (FLAKY-SYS-UI:
# per-launch encoding under load was the demo setup failure class); removed with the run's TMPDIR
export VALSE_UITEST_SHARED_MEDIA="${TMPDIR}shared-media"; mkdir -p "$VALSE_UITEST_SHARED_MEDIA"
RESULTS="$TMPDIR/results.tsv"; : > "$RESULTS"
WARNINGS="$TMPDIR/warnings.tsv"; : > "$WARNINGS"   # "<slowexp|clickw>\t<name>\t<detail>" (not gating)
PREFS="$HOME/Library/Preferences"
# UI-test apps' private settings domains (ValseCore AppDefaults: [com.]valse.uitest.<name>.<pid>.plist): removed
# after each app, and swept for dead PIDs here and on exit (cfprefsd may flush a file just after the app exited)
sweep_prefs() {
  local f p
  for f in "$PREFS"/*valse.uitest.*.[0-9]*.plist; do
    [[ -e "$f" ]] || continue
    p="${f%.plist}"; p="${p##*.}"
    kill -0 "$p" 2>/dev/null || rm -f "$f"
  done
}
sweep_prefs; on_exit sweep_prefs

# run_one <abs script> <name> → exit code of the app (124 = timeout)
run_one() {
  local abs="$1" name="$2" pid watch code
  rm -rf "$OUT/$name"; mkdir -p "$OUT/$name"
  "$BIN" --uitest "$abs" --uitest-out "$OUT/$name" --baselines "$ROOT/app/Tests/Baselines" ${EXTRA[@]+"${EXTRA[@]}"} < /dev/null &
  pid=$!
  # Hang detector, not a total limit: the driver touches <out>/<name>/.heartbeat when a step starts and while it polls
  # (each of its waits has its own progress-based bound), so a slow script on a loaded machine keeps running; an app
  # whose driver stopped beating for $TIMEOUT s (hung main thread, an await that never returns) is sampled and killed.
  # $MAX_SECONDS is only a sanity ceiling for a script that keeps progressing forever.
  (
    trap - EXIT INT TERM HUP
    why=""; hb="$OUT/$name/.heartbeat"; start=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
      sleep 2
      now=$(date +%s); last=$start
      if [[ -f "$hb" ]]; then last=$(stat -f %m "$hb" 2>/dev/null || echo "$start"); (( last < start )) && last=$start; fi
      if (( now - last >= TIMEOUT )); then why="no driver progress for ${TIMEOUT}s (after $(( now - start ))s)"; break; fi
      if (( now - start >= MAX_SECONDS )); then why="still running after ${MAX_SECONDS}s (VALSE_UITEST_MAX_SECONDS ceiling)"; break; fi
    done
    [[ -n "$why" ]] && kill -0 $pid 2>/dev/null || exit 0
    sample $pid 3 -file "$OUT/$name/hang-sample.txt" >/dev/null 2>&1 || true
    touch "$OUT/$name/.timeout"
    kill_tree $pid
    echo "✘ $name: TIMEOUT (HUNG): $why — stacks: $OUT/$name/hang-sample.txt"
  ) &
  watch=$!
  set +e; wait $pid; code=$?; set -e
  kill $watch 2>/dev/null || true; wait $watch 2>/dev/null || true
  # the app's private per-process settings domains (ValseCore AppDefaults: valse.uitest.*.<pid>)
  rm -f "$PREFS"/*valse.uitest.*."$pid".plist 2>/dev/null || true
  [[ -f "$OUT/$name/.timeout" ]] && code=124
  return $code
}

# is_heavy <script>: real ML inference (`"requires": {"models": …}`) or an explicit `"heavy": true`
is_heavy() { grep -qE '"heavy"[[:space:]]*:[[:space:]]*true|"models"[[:space:]]*:' "$1" 2>/dev/null; }
script_name() { local n="${1##*/}"; echo "${n%.json}"; }

# run_script <script> → appends "<kind>\t<name>\t<detail>" to $RESULTS (kind: pass skip flaky quar fail)
run_script() {
  local s="$1" ABS NAME T0 CODE CODE2 L w REASON TWICE W CW FLAKYMSG=""
  NAME="$(basename "$s" .json)"
  if [[ ! -f "$s" ]]; then echo "no such script: $s"; printf "fail\t%s\t%s\n" "$NAME" "$s" >> "$RESULTS"; return 0; fi
  ABS="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
  T0=$(date +%s)
  CODE=0; run_one "$ABS" "$NAME" || CODE=$?
  if [[ $CODE != 0 && $CODE != 3 && $RETRY == 1 ]]; then
    echo "↻ $NAME failed (exit $CODE) — retrying once"
    # let a load spike from other checkouts pass first (≤ VALSE_RETRY_WAIT s, default 60): the retry must still pass
    for ((w = 0; w < ${VALSE_RETRY_WAIT:-60}; w += 5)); do
      L="$(sysctl -n vm.loadavg | awk '{ printf "%d", $2 }')"
      (( L < $(sysctl -n hw.ncpu) )) && break
      sleep 5
    done
    rm -rf "$OUT/$NAME.attempt1"; mv "$OUT/$NAME" "$OUT/$NAME.attempt1"
    CODE2=0; run_one "$ABS" "$NAME" || CODE2=$?
    if [[ $CODE2 == 0 ]]; then FLAKYMSG="$NAME (attempt 1: exit $CODE → $OUT/$NAME.attempt1)"; CODE=0
    else CODE=$CODE2; fi
  fi
  printf "%s\t%s\t%s\n" "$NAME" "$CODE" "$(( $(date +%s) - T0 ))" >> "$OUT/durations.tsv"   # name, exit, seconds
  # an `expect` that waited > 2 s for its condition although the UI had settled = a slow reaction (latency regression)
  W="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])).get("metrics",{}); w=m.get("expect_wait_ms_max",0); print(int(w) if w>2000 and m.get("quiesce_timeouts",0)==0 else "")' "$OUT/$NAME/report.json" 2>/dev/null || true)"
  if [[ -n "$W" ]]; then printf "slowexp\t%s\t%s\n" "$NAME" "$NAME (an expect waited $W ms)" >> "$WARNINGS"; echo "⚠ slow expect: $NAME (an expect waited $W ms although the UI had settled)"; fi
  # an `id:` click whose element was not on screen at dispatch (nothing delivered, clicked again), was pressed where the
  # element had moved to since it was resolved, or was rebuilt between press and release (UITestDriver ClickProbe):
  # not gating, but the target moved / was rebuilt under the click
  CW="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])).get("metrics",{}); r=int(m.get("click_redeliveries",0)); t=int(m.get("click_retargets",0)); a=int(m.get("click_release_anomalies",0)); e=int(m.get("mouse_event_relocated",0)); b=int(m.get("load_barrier_timeouts",0)); print(f"{r} click redelivery(ies), {t} moved target(s), {a} release anomaly(ies), {e} relocated mouse event(s), {b} load barrier timeout(s)" if r or t or a or e or b else "")' "$OUT/$NAME/report.json" 2>/dev/null || true)"
  if [[ -n "$CW" ]]; then printf "clickw\t%s\t%s\n" "$NAME" "$NAME ($CW, see warnings in $OUT/$NAME/report.json)" >> "$WARNINGS"; echo "⚠ click warning: $NAME ($CW)"; fi
  if [[ $CODE == 0 && -n "$FLAKYMSG" ]]; then printf "flaky\t%s\t%s\n" "$NAME" "$FLAKYMSG" >> "$RESULTS"
  elif [[ $CODE == 0 ]]; then printf "pass\t%s\t-\n" "$NAME" >> "$RESULTS"
  elif [[ $CODE == 3 ]]; then printf "skip\t%s\t%s\n" "$NAME" "$NAME" >> "$RESULTS"
  elif REASON="$(python3 scripts/testlib.py quarantined ui "$NAME")"; then
    printf "quar\t%s\t%s\n" "$NAME" "$NAME (exit $CODE) — $REASON → $OUT/$NAME" >> "$RESULTS"
  else
    TWICE=""; if [[ $RETRY == 1 ]]; then TWICE=", failed twice"; fi
    printf "fail\t%s\t%s\n" "$NAME" "$NAME (exit $CODE$TWICE) → $OUT/$NAME" >> "$RESULTS"
  fi
  return 0
}

# --order: longest-first by a previous durations.tsv (scripts it doesn't know go first: they may be long)
if [[ -n "$ORDER" && -f "$ORDER" ]]; then
  ORDERED=()
  while IFS= read -r s; do ORDERED+=("$s"); done < <(
    for s in "${SCRIPTS[@]}"; do printf "%s\n" "$s"; done | awk -F'\t' -v tsv="$ORDER" '
      BEGIN { while ((getline l < tsv) > 0) { split(l, f, "\t"); secs[f[1]] = f[3] } }
      { n = $0; sub(/^.*\//, "", n); sub(/\.json$/, "", n); printf "%09d\t%s\n", (n in secs) ? secs[n] : 999999999, $0 }' |
      sort -t$'\t' -k1,1nr -s | cut -f2-)
  SCRIPTS=("${ORDERED[@]}")
fi

if (( JOBS > 1 && ${#SCRIPTS[@]} > 1 )); then
  # K workers claim scripts from a queue (mv is atomic: each script runs exactly once), each with its own TMPDIR
  # Heavy scripts (real ML inference: `"requires": {"models": …}`, or `"heavy": true`) each saturate the CPU for
  # minutes; several at once made each ~3x slower (ai_relight_model, ai_stems_inference, f3_isolate_music: ~300 s
  # together vs ~60-100 s alone). They go to their own queue, are claimed first and run one at a time (an mkdir lock);
  # while one runs, the other workers take light scripts.
  BASE_TMP="$TMPDIR"; Q="$BASE_TMP/queue"; mkdir -p "$Q/todo" "$Q/heavy" "$Q/taken"
  i=0; for s in "${SCRIPTS[@]}"; do
    d=todo; if is_heavy "$s"; then d=heavy; fi
    printf "%s\n" "$s" > "$Q/$d/$(printf %05d $i)"; i=$((i + 1))
  done
  # claim <queue dir> <worker> → prints the claimed entry name (mv is atomic: each script runs exactly once)
  claim() { local f; for f in $(ls "$1"); do if mv "$1/$f" "$Q/taken/$f.$2" 2>/dev/null; then echo "$f"; return 0; fi; done; return 1; }
  worker() {
    trap - EXIT INT TERM HUP
    local w="$1" f
    export TMPDIR="${BASE_TMP}w$w/"; mkdir -p "$TMPDIR"
    while :; do
      if [[ -n "$(ls "$Q/heavy")" ]] && mkdir "$Q/heavy.lock" 2>/dev/null; then
        if f="$(claim "$Q/heavy" "$w")"; then
          echo "⚙ heavy (one at a time): $(script_name "$(cat "$Q/taken/$f.$w")")"
          run_script "$(cat "$Q/taken/$f.$w")"; rmdir "$Q/heavy.lock"; continue
        fi
        rmdir "$Q/heavy.lock"
      fi
      if f="$(claim "$Q/todo" "$w")"; then run_script "$(cat "$Q/taken/$f.$w")"; continue; fi
      # only heavy scripts left and one is running on another worker: wait for its lock (or the end)
      if [[ -z "$(ls "$Q/heavy")" ]]; then break; fi
      sleep 1
    done
  }
  WORKERS=""
  on_exit 'for p in $WORKERS; do kill_tree $p >/dev/null 2>&1; done'
  for ((k = 0; k < JOBS; k++)); do worker "$k" & WORKERS="$WORKERS $!"; done
  for p in $WORKERS; do wait "$p" || true; done
  WORKERS=""
else
  for s in "${SCRIPTS[@]}"; do run_script "$s"; done
fi
# every scheduled script produced exactly one result: same sorted multiset of names (a worker killed mid-script
# loses one, a double claim duplicates one) — any difference fails the run
for s in "${SCRIPTS[@]}"; do script_name "$s"; done | sort > "$TMPDIR/scheduled.txt"
cut -f2 "$RESULTS" | sort > "$TMPDIR/reported.txt"
if ! RESDIFF="$(diff "$TMPDIR/scheduled.txt" "$TMPDIR/reported.txt")"; then
  echo "✘ UI results don't match the scheduled scripts (< missing, > unexpected / duplicate):"; echo "$RESDIFF" | grep '^[<>]' | sed 's/^/    /'
  printf "fail\t-\tUI results don't match the scheduled scripts\n" >> "$RESULTS"
fi

count() { awk -F'\t' -v k="$1" '$1 == k' "${2:-$RESULTS}" | wc -l | tr -d ' '; }
detail() { awk -F'\t' -v k="$1" '$1 == k { print "  " p $3 }' p="$2" "${3:-$RESULTS}"; }
FAIL=$(count fail)
NSLOW=$(count slowexp "$WARNINGS"); NCLICK=$(count clickw "$WARNINGS")
WARNS=""; if (( NSLOW + NCLICK > 0 )); then WARNS=", ⚠ $NSLOW slow expect, $NCLICK click warnings"; fi
echo "UI tests: $(( $(count pass) + $(count flaky) )) passed, $FAIL failed, $(count skip) skipped, $(count flaky) flaky (passed on retry), $(count quar) quarantined failures${WARNS}"
detail skip "skipped: "
detail flaky "flaky (passed on retry): "
detail quar "quarantined (failed, not gating): "
detail slowexp "⚠ slow expect (UI settled, condition late): " "$WARNINGS"
detail clickw "⚠ click warning (redelivered / moved target / release anomaly): " "$WARNINGS"
detail fail "failed: "
if [[ $FAIL != 0 ]]; then exit 1; fi
exit 0
