#!/bin/bash
# Qt 6 (QML/Qt Quick) + C++ + FFmpeg prototype — benchmark P1..P6 (non-interactive, < 10 min).
# Prints one JSON line per metric on stdout and writes them to results.jsonl.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MEDIA="$ROOT/bench/media"
OUT="$HERE/results.jsonl"
TMP="$(mktemp -d -t montage-qt)"
LOG="$HERE/bench.log"
APP="$HERE/deploy/Montage.app"
BIN="$APP/Contents/MacOS/Montage"
# SMOKE=1 runs a tiny version of every step (used during development only)
if [ "${SMOKE:-0}" = 1 ]; then PS=2; SEEKS=5; TLS=1; EXS=1; EXF=30; SEGF=20; AUS=2
else PS=20; SEEKS=50; TLS=5; EXS=10; EXF=300; SEGF=300; AUS=5; fi
mkdir -p "$HERE/screenshots"
: > "$OUT"; : > "$LOG"

log() { echo "[bench] $*" >&2; echo "[bench] $*" >> "$LOG"; }
cleanup() { pkill -f "$APP/Contents/MacOS/Montage" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- build (release, incremental)
export PATH="/opt/homebrew/bin:$PATH"
if [ ! -f "$HERE/build/build.ninja" ]; then
  cmake -S "$HERE" -B "$HERE/build" -G Ninja -DCMAKE_MAKE_PROGRAM=/opt/homebrew/bin/ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew -Wno-dev >> "$LOG" 2>&1 || { log "configure failed"; exit 1; }
fi
T0=$(date +%s)
cmake --build "$HERE/build" >> "$LOG" 2>&1 || { log "build failed (see bench.log)"; exit 1; }
log "build ok ($(( $(date +%s) - T0 ))s incremental)"

# ---------------------------------------------------------------- deploy (self-contained .app; slow, so only when stale)
if [ ! -x "$BIN" ] || [ "$HERE/build/Montage.app/Contents/MacOS/Montage" -nt "$BIN" ]; then
  log "deploying app bundle with macdeployqt (takes a few minutes)"
  rm -rf "$HERE/deploy"; mkdir -p "$HERE/deploy"
  cp -R "$HERE/build/Montage.app" "$HERE/deploy/"
  macdeployqt "$APP" -qmldir="$HERE/qml" -no-strip >> "$LOG" 2>&1
  mkdir -p "$APP/Contents/Frameworks/ggml" && cp /opt/homebrew/opt/ggml/libexec/*.so "$APP/Contents/Frameworks/ggml/"
fi

# ---------------------------------------------------------------- models (downloaded once)
mkdir -p "$HERE/models"
WHISPER="$HERE/models/ggml-large-v3-turbo-q5_0.bin"
SEGM="$HERE/models/modnet.onnx"
[ -f "$WHISPER" ] || curl -sSL -o "$WHISPER" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
[ -f "$SEGM" ] || curl -sSL -o "$SEGM" https://huggingface.co/Xenova/modnet/resolve/main/onnx/model.onnx

run() { # timeout_s args...
  local t=$1; shift
  log "run: $*"
  timeout "$t" "$BIN" --media "$MEDIA" "$@" 2>>"$LOG" | tee -a "$OUT" | grep '^{'
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || log "  exit code $rc"
  pkill -f "$APP/Contents/MacOS/Montage" 2>/dev/null
  sleep 1
}
metric() { local l="{\"stack\":\"qt-cpp\",\"metric\":\"$1\",\"value\":$2,\"unit\":\"$3\"}"; echo "$l"; echo "$l" >> "$OUT"; }

# [bench harness] BENCH_PREVIEW_ONLY=1 (+ optional BENCH_WRAP, PREVIEW_PREFIX) = preview-only run, used for the
# constrained-CPU approximation. Metrics are renamed preview_* -> ${PREVIEW_PREFIX}_*.
if [ "${BENCH_PREVIEW_ONLY:-0}" = 1 ]; then
  P="${PREVIEW_PREFIX:-preview}"
  log "run: preview-only ($P) ${BENCH_WRAP:-}"
  timeout 180 ${BENCH_WRAP:-} "$BIN" --media "$MEDIA" --mode preview --seconds "$PS" --seeks 0 2>>"$LOG" \
    | grep '"metric":"preview_' | sed "s/\"metric\":\"preview_/\"metric\":\"${P}_/" | tee -a "$OUT"
  pkill -f "$APP/Contents/MacOS/Montage" 2>/dev/null
  exit 0
fi
# P1 + P2 + cold start (one process: first composited frame, N s playback, then 50 random seeks)
run 180 --mode preview --seconds "$PS" --seeks "$SEEKS" --screenshot "$HERE/screenshots/preview.png"
# [bench harness] 8-layer stress test: same preview with a..d twice; metrics renamed preview_* -> preview8_*
log "run: preview8 (MONTAGE_LAYERS=8)"
MONTAGE_LAYERS=8 timeout 180 "$BIN" --media "$MEDIA" --mode preview --seconds "$PS" --seeks 0 2>>"$LOG" \
  | grep '"metric":"preview_' | sed 's/"metric":"preview_/"metric":"preview8_/' | tee -a "$OUT"
pkill -f "$APP/Contents/MacOS/Montage" 2>/dev/null; sleep 1
# P4 timeline (500 clips / 6 tracks, 5 s programmatic scroll+zoom)
run 60 --mode timeline --seconds "$TLS" --screenshot "$HERE/screenshots/timeline.png"
# P3 export 10 s 1080p30 H.264 (VideoToolbox), then verify with ffprobe
run 180 --mode export --seconds "$EXS" --out "$TMP/export.mp4"
FR=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames,codec_name,width,height -of csv=p=0 "$TMP/export.mp4" 2>/dev/null)
log "export ffprobe: $FR"
case "$FR" in h264,1920,1080,"$EXF") metric export_valid 1 bool ;; *) metric export_valid 0 bool ;; esac
# P5a segmentation (MODNet 512x288, ONNX Runtime CoreML EP) over 300 frames of h264_1080
run 300 --mode seg --frames "$SEGF" --model "$SEGM"
# P5b French STT with word timestamps (whisper.cpp large-v3-turbo q5_0, Metal)
STT_MEDIA="$MEDIA"
if [ "${SMOKE:-0}" = 1 ]; then STT_MEDIA="$TMP/m10"; mkdir -p "$STT_MEDIA"; ffmpeg -v error -y -i "$MEDIA/speech_fr.wav" -t 10 "$STT_MEDIA/speech_fr.wav"; fi
MEDIA_SAVE="$MEDIA"; MEDIA="$STT_MEDIA"
run 300 --mode stt --model "$WHISPER" --ref "$ROOT/bench/speech_fr.txt" --out "$HERE/screenshots/stt_words.json"
MEDIA="$MEDIA_SAVE"
# P6 audio: clip at 1.5x, pitch preserved (Rubber Band R3) while video plays, clocked by audio
run 60 --mode audio --seconds "$AUS" --rate 1.5

# app size (deployed bundle, models excluded)
SIZE=$(du -sk "$APP" | LC_ALL=C awk '{printf "%.1f", $1/1024}')
metric app_size_mb "$SIZE" MB
log "done -> $OUT"
