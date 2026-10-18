#!/usr/bin/env bash
# Stack benchmark for the Rust engine + Tauri 2 UI prototype (see docs/STACK_BENCH.md).
# Non-interactive. Builds (release, incremental) then runs P1–P6 and prints one JSON line per
# metric to stdout; the same lines are written to results.jsonl.
#   SMOKE=1 ./bench.sh   -> short smoke run (3 s preview, 10 seeks, 1 s export, 20 seg frames)
set -uo pipefail
export LC_ALL=C LANG=C   # '.' decimal separator in awk/printf whatever the user locale
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ROOT="$(cd ../.. && pwd)"
export MONTAGE_MEDIA="$ROOT/bench/media"
export MONTAGE_MODELS="$HERE/models"
export MONTAGE_STT_REF="$ROOT/bench/speech_fr.txt"
export MONTAGE_COREML_CACHE="$HERE/out/coreml-cache"
OUT="$HERE/results.jsonl"
LOG="$HERE/out/bench.log"
mkdir -p out
: > "$OUT"
: > "$LOG"

SMOKE="${SMOKE:-0}"
if [ "$SMOKE" = "1" ]; then
  PREVIEW_S=3; SEEKS=10; EXPORT_S=1; SEG_FRAMES=20
else
  PREVIEW_S="${PREVIEW_S:-20}"; SEEKS=50; EXPORT_S=10; SEG_FRAMES=300
fi

log() { echo "[bench] $*" >&2; echo "[bench] $*" >> "$LOG"; }
emit() { # metric value unit
  local line="{\"stack\":\"tauri-rust\",\"metric\":\"$1\",\"value\":$2,\"unit\":\"$3\"}"
  echo "$line"; echo "$line" >> "$OUT"
}
collect() { # filter metric lines from a command's stdout
  grep '^{"stack":"tauri-rust"' | while IFS= read -r l; do echo "$l"; echo "$l" >> "$OUT"; done
}

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  pkill -f "MontageProto.app/Contents/MacOS/montage-proto" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# run_timeout <seconds> <cmd...> : runs cmd, kills it after <seconds>
run_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  PIDS+=("$pid")
  # watchdog must not inherit our stdout (it would keep the downstream pipe open)
  ( sleep "$secs" & sp=$!; trap 'kill $sp 2>/dev/null; exit 0' TERM; wait $sp; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# ---------------------------------------------------------------- build (incremental)
log "building (release)…"
command -v rustup >/dev/null || { log "rustup missing"; exit 1; }
rustup toolchain list | grep -q '^1.99.1' || rustup toolchain install 1.99.1 --profile minimal >> "$LOG" 2>&1
if [ ! -x .venv/bin/cmake ]; then
  python3 -m venv .venv >> "$LOG" 2>&1 && .venv/bin/pip install -q cmake onnx onnxruntime onnxsim >> "$LOG" 2>&1
fi
export PATH="$HERE/.venv/bin:$PATH"
mkdir -p models
[ -s models/rvm_mobilenetv3_fp32.onnx ] || curl -sL -o models/rvm_mobilenetv3_fp32.onnx \
  https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx
[ -s models/ggml-large-v3-turbo-q5_0.bin ] || curl -sL -o models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
[ -s models/rvm_1080p_static.onnx ] || .venv/bin/python tools/models/fix_rvm.py \
  models/rvm_mobilenetv3_fp32.onnx models/rvm_1080p_static.onnx 1920 1080 0.25 >> "$LOG" 2>&1
( cd app && { [ -d node_modules ] || npm install --no-fund --no-audit; } && npm run build && npx tauri build --bundles app ) >> "$LOG" 2>&1 \
  || { log "app build failed (see out/bench.log)"; exit 1; }
cargo build --release -p ai --bin montage-cli -p procstat >> "$LOG" 2>&1 || { log "cli build failed"; exit 1; }
APPDIR="$HERE/target/release/bundle/macos/MontageProto.app"
APP="$APPDIR/Contents/MacOS/montage-proto"
CLI="$HERE/target/release/montage-cli"
PROCSTAT="$HERE/target/release/procstat"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# ---------------------------------------------------------------- app size
emit app_size_mb "$(du -sk "$APPDIR" | awk '{printf "%.1f", $1/1024}')" MB

# ---------------------------------------------------------------- cold start (median of 3)
log "cold start…"
CS=()
for i in 1 2 3; do
  v=$(MONTAGE_BENCH=cold MONTAGE_T0_MS=$(now_ms) run_timeout 60 "$APP" 2>>"$LOG" | grep cold_start_ms | sed -E 's/.*"value":([0-9.]+).*/\1/')
  [ -n "$v" ] && CS+=("$v")
  sleep 1
done
if [ "${#CS[@]}" -gt 0 ]; then
  emit cold_start_ms "$(printf '%s\n' "${CS[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')" ms
fi

# ---------------------------------------------------------------- P1 preview + CPU/RSS
# [bench harness] factored into a function so the same measurement runs for the 8-layer stress test
# (MONTAGE_LAYERS=8, metrics renamed preview_* -> preview8_*). BENCH_PREVIEW_ONLY=1 stops after preview.
preview_run() { # <metric prefix> <layers>
  local P="$1" L="$2"
  log "preview $P (${PREVIEW_S}s, $L layers)…"
  rm -f out/marker
  ps -axo pid= > out/before_pids.txt
  MONTAGE_LAYERS="$L" MONTAGE_BENCH=preview MONTAGE_DURATION="$PREVIEW_S" MONTAGE_MARKER="$HERE/out/marker" ${BENCH_WRAP:-} "$APP" > out/preview.out 2>>"$LOG" &
  APID=$!; PIDS+=("$APID")
  for _ in $(seq 1 300); do [ -f out/marker ] && break; sleep 0.1; done
  # with BENCH_WRAP (taskpolicy) $! is the app itself since taskpolicy execs
  STAT=$("$PROCSTAT" "$APID" "$(echo "$PREVIEW_S - 0.5" | bc)" 250 out/before_pids.txt)
  log "procstat: $STAT"
  ( sleep $((PREVIEW_S + 30)) & sp=$!; trap 'kill $sp 2>/dev/null; exit 0' TERM; wait $sp; kill "$APID" 2>/dev/null ) >/dev/null 2>&1 & W=$!
  wait "$APID" 2>/dev/null; kill "$W" 2>/dev/null
  sed "s/\"metric\":\"preview_/\"metric\":\"${P}_/" out/preview.out | collect
  emit "${P}_cpu_pct" "$(echo "$STAT" | awk '{print $1}')" "%"
  emit "${P}_rss_mb" "$(echo "$STAT" | awk '{print $2}')" MB
  emit "${P}_rss_peak_mb" "$(echo "$STAT" | awk '{print $3}')" MB
}
preview_run "${PREVIEW_PREFIX:-preview}" 4
[ "${BENCH_PREVIEW_ONLY:-0}" = 1 ] && { log "preview only -> $OUT"; exit 0; }
preview_run preview8 8

# ---------------------------------------------------------------- P2 scrub
log "scrub ($SEEKS seeks)…"
MONTAGE_BENCH=scrub MONTAGE_SEEKS="$SEEKS" run_timeout 120 "$APP" 2>>"$LOG" | collect

# ---------------------------------------------------------------- P4 timeline
log "timeline…"
MONTAGE_BENCH=timeline run_timeout 60 "$APP" 2>>"$LOG" | collect

# ---------------------------------------------------------------- P6 audio time-stretch
log "audio 1.5x…"
MONTAGE_BENCH=audio MONTAGE_DURATION=3 run_timeout 60 "$APP" 2>>"$LOG" | collect

# ---------------------------------------------------------------- P3 export
log "export (${EXPORT_S}s)…"
run_timeout 300 "$CLI" export "$EXPORT_S" "$HERE/out/export.mp4" 2>>"$LOG" | collect
command -v ffprobe >/dev/null && log "export check: $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames -of csv=p=0 out/export.mp4)"

# ---------------------------------------------------------------- P5a segmentation
log "segmentation ($SEG_FRAMES frames)…"
run_timeout 300 "$CLI" seg "$SEG_FRAMES" coreml 2>>"$LOG" | collect

# ---------------------------------------------------------------- P5b speech to text
log "speech-to-text…"
run_timeout 300 "$CLI" stt 2>>"$LOG" | collect

log "done -> $OUT"
