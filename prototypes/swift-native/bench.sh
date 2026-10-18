#!/bin/bash
# Swift-native prototype benchmark: builds (release), runs P1–P6, prints JSON metric lines and
# writes them to results.jsonl. Non-interactive; every step has a hard timeout (watchdog in-app).
set -uo pipefail
export LC_ALL=C LANG=C  # decimal points, not commas (French locale)
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
MEDIA="$(cd ../../bench/media && pwd)"
APP="$HERE/build/Montage.app"
BIN="$APP/Contents/MacOS/Montage"
RES="$HERE/results.jsonl"
OUT="$HERE/out"; mkdir -p "$OUT"
WHISPER_MODEL="$HERE/models/ggml-large-v3-turbo-q5_0.bin"
: > "$RES"
# BENCH_SMOKE=1 → tiny sizes, only to check the script end-to-end (numbers are NOT benchmark results)
if [ "${BENCH_SMOKE:-0}" = 1 ]; then PS=3; SK=5; EX=1; TL=2; SF=20; else PS=20; SK=50; EX=10; TL=5; SF=300; fi

cleanup() { pkill -f "$BIN" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

emit() { local l="{\"stack\":\"swift-native\",\"metric\":\"$1\",\"value\":$2,\"unit\":\"$3\"}"; echo "$l"; echo "$l" >> "$RES"; }
run() { # run <mode> [args...] : forward JSON lines, keep logs
  local m="$1"; shift
  "$BIN" "$m" --media "$MEDIA" "$@" 2>>"$OUT/bench.log" | grep '^{"stack"' | tee -a "$RES"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -ne 0 ] && echo "[bench] mode $m exited $rc (see out/bench.log)" >&2
  return 0
}

echo "[bench] building (release)…" >&2
T0=$(python3 -c 'import time;print(time.time())')
./bundle.sh 2>>"$OUT/bench.log" || { echo "build failed" >&2; exit 1; }
T1=$(python3 -c 'import time;print(time.time())')
emit build_seconds "$(python3 -c "print(round($T1-$T0,2))")" s
emit app_size_mb "$(du -sk "$APP" | awk '{printf "%.2f", $1/1024}')" MB

echo "[bench] cold start (3 runs, median)…" >&2
CS=()
for i in 1 2 3; do
  v=$("$BIN" coldstart --timeout 30 2>>"$OUT/bench.log" | grep '"cold_start_ms"' | sed 's/.*"value":\([0-9.]*\).*/\1/')
  [ -n "$v" ] && CS+=("$v")
  sleep 0.5
done
if [ ${#CS[@]} -gt 0 ]; then emit cold_start_ms "$(printf '%s\n' "${CS[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')" ms; fi

# [bench harness] BENCH_PREVIEW_ONLY=1 (+ optional BENCH_WRAP e.g. "taskpolicy -b", PREVIEW_PREFIX) = preview-only run
# for the constrained-CPU approximation; metrics renamed preview_* -> ${PREVIEW_PREFIX}_*.
if [ "${BENCH_PREVIEW_ONLY:-0}" = 1 ]; then
  P="${PREVIEW_PREFIX:-preview}"
  ${BENCH_WRAP:-} "$BIN" preview --media "$MEDIA" --seconds $PS --timeout 90 2>>"$OUT/bench.log" | grep '"metric":"preview_' \
    | sed "s/\"metric\":\"preview_/\"metric\":\"${P}_/" | tee -a "$RES"
  exit 0
fi
echo "[bench] P1 preview (20 s)…" >&2;     run preview --seconds $PS --timeout 90
# [bench harness] 8-layer stress test (a..d twice), metrics renamed preview_* -> preview8_*
echo "[bench] P1b preview 8 layers (20 s)…" >&2
MONTAGE_LAYERS=8 "$BIN" preview --media "$MEDIA" --seconds $PS --timeout 90 2>>"$OUT/bench.log" | grep '"metric":"preview_' \
  | sed 's/"metric":"preview_/"metric":"preview8_/' | tee -a "$RES"
echo "[bench] P2 scrub (50 seeks)…" >&2;   run scrub --seeks $SK --timeout 240
echo "[bench] P3 export (10 s)…" >&2;      run export --seconds $EX --out "$OUT/export.mp4" --timeout 240
if [ -f "$OUT/export.mp4" ]; then
  FR=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames,codec_name,width,height -of csv=p=0 "$OUT/export.mp4")
  echo "[bench] export check (codec,w,h,frames): $FR" >&2
fi
echo "[bench] P4 timeline (5 s)…" >&2;     run timeline --seconds $TL --timeout 60 --snapshot "$OUT/timeline.png"
echo "[bench] P5a segmentation…" >&2;      run seg --frames $SF --timeout 240
echo "[bench] P5b speech-to-text…" >&2;    run stt --whisper-model "$WHISPER_MODEL" --timeout 300
echo "[bench] P6 audio stretch…" >&2;      run audio --timeout 60
echo "[bench] done → $RES" >&2
