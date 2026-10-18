#!/bin/bash
# Electron + web-tech prototype benchmark (P1–P6). Non-interactive. Usage: ./bench.sh [--smoke]
# Prints one JSON line per metric and writes them to results.jsonl.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
ROOT="$(cd ../.. && pwd)"; MEDIA="$ROOT/bench/media"; MODELS="$HERE/models"; OUT="$HERE/.bench-out"
SMOKE=0; [ "${1:-}" = "--smoke" ] && SMOKE=1
RESULTS="$HERE/results.jsonl"; [ $SMOKE = 1 ] && RESULTS="$HERE/results.smoke.jsonl"
: > "$RESULTS"; mkdir -p "$OUT"
log() { echo "[bench] $*" >&2; }
emit() { echo "$1" | tee -a "$RESULTS"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'; }

# Node >= 22.12 is required by electron's installer / build tooling.
for n in "$HOME"/.nvm/versions/node/v2[4-9]* "$HOME"/.nvm/versions/node/v22*; do [ -x "$n/bin/node" ] && export PATH="$n/bin:$PATH" && break; done
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a==22&&b>=12)?0:1)' || { log "need node >= 22.12"; exit 1; }

# ---- dependencies & models (one-time; the shipping app would bundle models) ----
[ -d node_modules/electron ] || npm ci --no-audit --no-fund >&2 || exit 1
[ -f node_modules/electron/path.txt ] || node node_modules/electron/install.js >&2
mkdir -p "$MODELS"
[ -f "$MODELS/rvm_mobilenetv3_fp32.onnx" ] || curl -sSL -o "$MODELS/rvm_mobilenetv3_fp32.onnx" https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx
[ -f "$MODELS/ggml-large-v3-turbo-q5_0.bin" ] || curl -sSL -o "$MODELS/ggml-large-v3-turbo-q5_0.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
WHISPER="$(command -v whisper-cli || true)"; [ -n "$WHISPER" ] || log "whisper-cli not found (brew install whisper-cpp); STT will fail"

# ---- release build + package ----
t0=$(now_ms)
node build.mjs >&2 || exit 1
npx @electron/packager . Montage --platform=darwin --arch=arm64 --out=out --overwrite --asar.unpackDir='node_modules/onnxruntime-node/bin' --prune=true \
  --ignore='^/(src|models|out|\.smoke|\.bench-out|bench\.sh|build\.mjs|tsconfig\.json|REPORT\.md|results.*\.jsonl)' \
  --ignore='/node_modules/onnxruntime-node/bin/napi-v[0-9]+/(linux|win32)' --ignore='/node_modules/onnxruntime-node/bin/napi-v[0-9]+/darwin/x64' --ignore='libonnxruntime\.[0-9]+\.[0-9]+\.[0-9]+\.dylib$' \
  --quiet >&2 || exit 1
log "build+package: $(( $(now_ms) - t0 )) ms"
APP="$HERE/out/Montage-darwin-arm64/Montage.app"; BIN="$APP/Contents/MacOS/Montage"
emit "{\"stack\":\"electron-web\",\"metric\":\"app_size_mb\",\"value\":$(( $(du -sk "$APP" | cut -f1) / 1024 )),\"unit\":\"MB\",\"note\":\"packaged .app (asar, arm64-only ORT), excludes models: RVM 14 MB + whisper large-v3-turbo q5_0 547 MB; excludes whisper.cpp sidecar (~5 MB)\"}"

cleanup() { pkill -f "$APP/Contents" 2>/dev/null; pkill -f "montage-seg" 2>/dev/null; true; }
trap cleanup EXIT
# run_phase <timeout_s> <bench> [args...] — app prints metric JSON on stdout
run_phase() {
  local to=$1; shift
  perl -e 'alarm shift; exec @ARGV' "$to" "$BIN" --media="$MEDIA" --models="$MODELS" --out="$OUT" --whisper="${WHISPER:-whisper-cli}" --timeout="$to" "$@" \
    2> >(grep -v -E '^\s*$|GetCapability|VerifyEachNode|Rerunning with verbose' | cut -c1-400 >&2) | grep '^{"stack"' | while read -r l; do emit "$l"; done
  cleanup; sleep 1
}

if [ $SMOKE = 1 ]; then PREV=3; SCRUB=10; EXP=1; SEGN=20; else PREV=20; SCRUB=50; EXP=10; SEGN=300; fi

# cold start: 3 launches, first one reported as cold, median in extra field
COLD=()
for i in 1 2 3; do
  l=$(perl -e 'alarm shift; exec @ARGV' 60 "$BIN" --bench=cold --t0="$(now_ms)" --media="$MEDIA" --models="$MODELS" --out="$OUT" 2>/dev/null | grep '^{"stack"')
  COLD+=("$(echo "$l" | sed -E 's/.*"value":([0-9.]+).*/\1/')"); cleanup; sleep 1
done
MED=$(printf '%s\n' "${COLD[@]}" | sort -n | sed -n 2p)
emit "{\"stack\":\"electron-web\",\"metric\":\"cold_start_ms\",\"value\":$MED,\"unit\":\"ms\",\"first_launch_after_build_ms\":${COLD[0]},\"runs\":\"${COLD[*]}\",\"note\":\"median of 3 launches; spawn -> React shell + 500-clip timeline painted\"}"

# [bench harness] run_phase_renamed <prefix> <timeout> args... : like run_phase, metrics preview_* -> <prefix>_*,
# optional BENCH_WRAP (e.g. "taskpolicy -b") prepended to the app command.
run_phase_renamed() {
  local P=$1 to=$2; shift 2
  perl -e 'alarm shift; exec @ARGV' "$to" ${BENCH_WRAP:-} "$BIN" --media="$MEDIA" --models="$MODELS" --out="$OUT" --timeout="$to" "$@" \
    2> >(grep -v -E '^\s*$|GetCapability|VerifyEachNode|Rerunning with verbose' | cut -c1-400 >&2) | grep '"metric":"preview_' \
    | sed "s/\"metric\":\"preview_/\"metric\":\"${P}_/" | while read -r l; do emit "$l"; done
  cleanup; sleep 1
}
if [ "${BENCH_PREVIEW_ONLY:-0}" = 1 ]; then
  run_phase_renamed "${PREVIEW_PREFIX:-preview}" 120 --bench=preview --seconds=$PREV
  log "preview only; results in $RESULTS"; exit 0
fi
run_phase 120 --bench=preview --seconds=$PREV
# [bench harness] 8-layer stress test (a..d twice)
run_phase_renamed preview8 120 --bench=preview --seconds=$PREV --layers=8
run_phase 120 --bench=scrub --count=$SCRUB
run_phase 120 --bench=export --seconds=$EXP
run_phase 60  --bench=timeline --seconds=5
run_phase 180 --bench=seg --frames=$SEGN --backend=node-cpu
run_phase 180 --bench=stt
run_phase 60  --bench=audio --seconds=3
log "done; results in $RESULTS"
