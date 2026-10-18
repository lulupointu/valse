#!/bin/bash
# Orchestrator for the stack benchmark (docs/STACK_BENCH.md): runs each prototype's full bench.sh
# sequentially, 2 rounds in opposite orders, 60 s cooldown between runs, then a preview-only run under
# `taskpolicy -b` (background QoS = efficiency cores only; a rough CPU-starved approximation of a
# MacBook Air, NOT a substitute for measuring on one).
# Raw JSON lines -> bench/results/<stack>-r<N>.jsonl ; constrained -> <stack>-bg.jsonl ; logs -> *.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/bench/results"; mkdir -p "$RES"
COOLDOWN="${COOLDOWN:-60}"
STATE="$RES/system_state.log"

state() { # label
  { echo "=== $1 $(date '+%F %T')"; uptime; pmset -g batt | tail -1; pmset -g therm | grep -v '^Note' ;
    top -l 2 -o cpu -n 6 -stats pid,command,cpu,mem 2>/dev/null | tail -7; } >> "$STATE" 2>&1
}
bench_cmd() { # stack -> command
  case "$1" in
    swift-native) echo "./bench.sh" ;;
    electron-web) echo "./bench.sh" ;;
    tauri-rust)   echo "./bench.sh" ;;
    qt-cpp)       echo "./bench.sh" ;;
  esac
}
run_one() { # stack outfile [env...]
  local s=$1 out=$2; shift 2
  state "$s -> $(basename "$out")"
  echo "[orchestrator] $(date '+%T') $s -> $(basename "$out")" >&2
  ( cd "$ROOT/prototypes/$s" && env "$@" $(bench_cmd "$s") ) > "$out" 2> "${out%.jsonl}.log"
  echo "[orchestrator] $(date '+%T') $s done ($(grep -c '"metric"' "$out") metrics)" >&2
  sleep "$COOLDOWN"
}

PHASE="${1:-all}"
if [ "$PHASE" = all ] || [ "$PHASE" = rounds ]; then
  for s in swift-native electron-web tauri-rust qt-cpp; do run_one "$s" "$RES/$s-r1.jsonl" X=1; done
  for s in qt-cpp tauri-rust electron-web swift-native; do run_one "$s" "$RES/$s-r2.jsonl" X=1; done
fi
if [ "$PHASE" = all ] || [ "$PHASE" = bg ]; then
  for s in swift-native electron-web tauri-rust qt-cpp; do
    run_one "$s" "$RES/$s-bg.jsonl" BENCH_PREVIEW_ONLY=1 BENCH_WRAP="taskpolicy -b" PREVIEW_PREFIX=preview_bg
  done
fi
# Second, milder constrained variant: QoS clamp "utility" (taskpolicy -c utility). -b (DARWIN_BG) also demotes
# GPU/IO priority, which starves render loops; utility is closer to "CPU-limited" without starving the GPU queue.
if [ "$PHASE" = util ]; then
  for s in swift-native electron-web tauri-rust qt-cpp; do
    run_one "$s" "$RES/$s-util.jsonl" BENCH_PREVIEW_ONLY=1 BENCH_WRAP="taskpolicy -c utility" PREVIEW_PREFIX=preview_util
  done
fi
state "end"
echo "[orchestrator] all done" >&2
