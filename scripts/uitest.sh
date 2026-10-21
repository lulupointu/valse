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
#   --jobs <K>            run K apps at once (default 1, or MONTAGE_UI_JOBS); each worker has its own TMPDIR, every app its
#                         own settings domain / pasteboard / sandbox (MontageCore AppDefaults), so scripts can't interact
#   --order <tsv>         a previous <out>/durations.tsv: start the longest scripts first (better --jobs balance)
# Exit code: 0 if every script passed, was SKIPPED (unmet precondition, e.g. a missing AI model: app exit code 3), passed
#            on its retry ("flaky") or is quarantined (app/Tests/quarantine.txt: reported, not gating);
#            1 if any other script failed or timed out twice.
# The apps run with a private TMPDIR (sandboxes, exports, project copies) that is deleted on exit, even on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG=debug; BUILD=1; TIMEOUT=120; OUT="$ROOT/build/uitest"; EXTRA=(); SCRIPTS=(); RETRY=1
JOBS="${MONTAGE_UI_JOBS:-1}"; ORDER=""
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
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) SCRIPTS+=("$1"); shift;;
  esac
done
[[ ${#SCRIPTS[@]} -gt 0 ]] || { sed -n '2,22p' "$0"; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs needs a positive integer"; exit 2; }
source scripts/lib.sh
# machine-wide: at most N heavy runs at once across all checkouts (scripts/slots.sh)
source scripts/slots.sh; slots_acquire
mkdir -p "$OUT"; rm -f "$OUT/durations.tsv"
if [[ $BUILD == 1 ]]; then
  if ! run_watched "$OUT/build.log" swift build -c "$CONFIG" --product Montage; then
    grep -E "error:|HUNG" "$OUT/build.log" | sort -u | head -30 >&2 || true
    tail -5 "$OUT/build.log" >&2; echo "BUILD FAILED (see $OUT/build.log)"; exit 1
  fi
fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Montage"
[[ -x "$BIN" ]] || { echo "no binary at $BIN (drop --no-build)"; exit 2; }
use_private_tmpdir uitest
RESULTS="$TMPDIR/results.tsv"; : > "$RESULTS"
PREFS="$HOME/Library/Preferences"
# UI-test apps' private settings domains (MontageCore AppDefaults: [com.]montage.uitest.<name>.<pid>.plist): removed
# after each app, and swept for dead PIDs here and on exit (cfprefsd may flush a file just after the app exited)
sweep_prefs() {
  local f p
  for f in "$PREFS"/*montage.uitest.*.[0-9]*.plist; do
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
  # the app's private per-process settings domains (MontageCore AppDefaults: montage.uitest.*.<pid>)
  rm -f "$PREFS"/*montage.uitest.*."$pid".plist 2>/dev/null || true
  [[ -f "$OUT/$name/.timeout" ]] && code=124
  return $code
}

# run_script <script> → appends "<kind>\t<name>\t<detail>" to $RESULTS (kind: pass skip flaky quar fail)
run_script() {
  local s="$1" ABS NAME T0 CODE CODE2 L w REASON TWICE
  if [[ ! -f "$s" ]]; then echo "no such script: $s"; printf "fail\t%s\t%s\n" "$s" "$s" >> "$RESULTS"; return 0; fi
  ABS="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
  NAME="$(basename "$s" .json)"
  T0=$(date +%s)
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
    if [[ $CODE2 == 0 ]]; then printf "flaky\t%s\t%s\n" "$NAME" "$NAME (attempt 1: exit $CODE → $OUT/$NAME.attempt1)" >> "$RESULTS"; CODE=0
      printf "%s\t%s\t%s\n" "$NAME" "$CODE" "$(( $(date +%s) - T0 ))" >> "$OUT/durations.tsv"
      return 0
    else CODE=$CODE2; fi
  fi
  printf "%s\t%s\t%s\n" "$NAME" "$CODE" "$(( $(date +%s) - T0 ))" >> "$OUT/durations.tsv"   # name, exit, seconds
  if [[ $CODE == 0 ]]; then printf "pass\t%s\t-\n" "$NAME" >> "$RESULTS"
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
  BASE_TMP="$TMPDIR"; Q="$BASE_TMP/queue"; mkdir -p "$Q/todo" "$Q/taken"
  i=0; for s in "${SCRIPTS[@]}"; do printf "%s\n" "$s" > "$Q/todo/$(printf %05d $i)"; i=$((i + 1)); done
  worker() {
    trap - EXIT INT TERM HUP
    local w="$1" f
    export TMPDIR="${BASE_TMP}w$w/"; mkdir -p "$TMPDIR"
    for f in $(ls "$Q/todo"); do
      mv "$Q/todo/$f" "$Q/taken/$f.$w" 2>/dev/null || continue
      run_script "$(cat "$Q/taken/$f.$w")"
    done
  }
  WORKERS=""
  on_exit 'for p in $WORKERS; do kill_tree $p >/dev/null 2>&1; done'
  for ((k = 0; k < JOBS; k++)); do worker "$k" & WORKERS="$WORKERS $!"; done
  for p in $WORKERS; do wait "$p" || true; done
  WORKERS=""
  # every queued script must have produced exactly one result (a worker killed mid-script would lose one)
  if [[ "$(wc -l < "$RESULTS" | tr -d ' ')" != "${#SCRIPTS[@]}" ]]; then
    echo "✘ UI workers produced $(wc -l < "$RESULTS" | tr -d ' ') results for ${#SCRIPTS[@]} scripts"
    printf "fail\t-\tUI worker results missing\n" >> "$RESULTS"
  fi
else
  for s in "${SCRIPTS[@]}"; do run_script "$s"; done
fi

count() { awk -F'\t' -v k="$1" '$1 == k' "$RESULTS" | wc -l | tr -d ' '; }
detail() { awk -F'\t' -v k="$1" '$1 == k { print "  " p $3 }' p="$2" "$RESULTS"; }
FAIL=$(count fail)
echo "UI tests: $(( $(count pass) + $(count flaky) )) passed, $FAIL failed, $(count skip) skipped, $(count flaky) flaky (passed on retry), $(count quar) quarantined failures"
detail skip "skipped: "
detail flaky "flaky (passed on retry): "
detail quar "quarantined (failed, not gating): "
detail fail "failed: "
if [[ $FAIL != 0 ]]; then exit 1; fi
exit 0
