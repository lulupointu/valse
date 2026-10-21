#!/bin/bash
# Perf harness: timeline scroll/zoom with 500 clips + memory peak (UI driver, offscreen) and the 4K perf smoke tests
# (playback / export / proxy, needs bench/media from bench/make_media.sh). JSON output + regression thresholds.
#
# Usage: scripts/perf.sh [--air] [--no-smoke] [--no-build] [--out results.json] [--thresholds bench/perf_thresholds.json]
#   --air        MacBook Air approximation: runs under `taskpolicy -c background` (efficiency cores only, throttled
#                I/O — pessimistic vs a real M1 Air's 4P+4E) with MONTAGE_SIMULATE_RAM_GB=8 (8 GB memory policies:
#                720p preview, forced proxies, smaller caches). Compared against the "air" thresholds.
#   --no-smoke   skip the 4K perf smoke tests (they are skipped anyway when bench/media is missing)
# Writes build/perf/results.json: {"mode", "machine", "metrics": {...}, "violations": [...]}. Exit 1 on any violation.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
MODE=default; SMOKE=1; BUILD=1; OUT="$ROOT/build/perf/results.json"; TH="$ROOT/bench/perf_thresholds.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --air) MODE=air; shift;;
    --no-smoke) SMOKE=0; shift;;
    --no-build) BUILD=0; shift;;
    --out) OUT="$2"; shift 2;;
    --thresholds) TH="$2"; shift 2;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
WRAP=(); ENVS=()
if [[ $MODE == air ]]; then WRAP=(taskpolicy -c background); ENVS=(MONTAGE_SIMULATE_RAM_GB=8); fi
DIR="$ROOT/build/perf/$MODE"; rm -rf "$DIR"; mkdir -p "$DIR"
# exclusive: takes every test slot so other teams' builds/tests don't disturb the timings (scripts/slots.sh)
source scripts/slots.sh; slots_acquire_all

[[ $BUILD == 1 ]] && swift build -c release --product Montage >&2
BIN="$(swift build -c release --show-bin-path)/Montage"

echo "▶ timeline 500 clips ($MODE)" >&2
set +e
env ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} "$BIN" --uitest "$ROOT/app/Tests/PerfScripts/timeline_500.json" --uitest-out "$DIR/ui" >&2
UICODE=$?
echo "▶ asset panel 1,000 items ($MODE)" >&2
env ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} "$BIN" --uitest "$ROOT/app/Tests/PerfScripts/assets_1000.json" --uitest-out "$DIR/assets" >&2
ACODE=$?
[[ $UICODE == 0 ]] && UICODE=$ACODE
set -e

: > "$DIR/smoke.jsonl"
# In a git worktree, reuse the main checkout's bench media (gitignored, ~1 GB) instead of regenerating it.
if [[ ! -e bench/media ]]; then
  MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
  [[ -f "$MAIN/bench/media/.done" && "$MAIN" != "$ROOT" ]] && ln -s "$MAIN/bench/media" bench/media
fi
if [[ $SMOKE == 1 && -f bench/media/.done ]]; then
  echo "▶ 4K perf smoke + audit ($MODE)" >&2
  swift build -c release --build-tests --scratch-path .build/perf -Xswiftc -enable-testing >&2  # incremental; needed even with --no-build
  set +e
  # typical 1080p project memory: own process (its metric is the lifetime peak footprint)
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter 'PerfMemoryTests' 2>&1 \
    | tee "$DIR/memory.log" | grep -E '^\{"stack"' >> "$DIR/smoke.jsonl"
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter 'PerfSmokeTests|PerfAuditTests|canvasBuildScalesTo600Clips|fiftyAnimatedCaptionsRenderFast|playbackDeliversFramesInRealTime|everyEffectFitsTheRealTimeBudget|manyCaptionsSyncFast|enhanceQualityRunsInRealTimeBudget' 2>&1 \
    | tee "$DIR/smoke.log" | grep -E '^\{"stack"' >> "$DIR/smoke.jsonl"
  # wall-clock budgets of unit tests are asserted here only (TimingBudget: MONTAGE_PERF=1); a failed one is a violation
  grep -qE '^✘ Test .*(canvasBuildScalesTo600Clips|fiftyAnimatedCaptionsRenderFast|playbackDeliversFramesInRealTime|everyEffectFitsTheRealTimeBudget|manyCaptionsSyncFast|enhanceQualityRunsInRealTimeBudget)' "$DIR/smoke.log" \
    && echo '{"stack":"montage","metric":"unit_timing_budget_failures","value":1,"unit":"count"}' >> "$DIR/smoke.jsonl"
  set -e
elif [[ $SMOKE == 1 ]]; then
  echo "  (4K perf smoke skipped: run bench/make_media.sh first)" >&2
fi

python3 - "$MODE" "$DIR/ui/report.json" "$DIR/smoke.jsonl" "$TH" "$OUT" "$UICODE" <<'PY'
import json, sys, os, platform, subprocess
mode, report, smoke, th, out, uicode = sys.argv[1:]
metrics = {}
try:
    metrics.update(json.load(open(report)).get("metrics", {}))
except Exception as e:
    print(f"no UI perf report ({e})", file=sys.stderr)
try:   # asset-panel perf (W13); its memory metrics are prefixed so they don't replace the timeline run's
    for k, v in json.load(open(os.path.join(os.path.dirname(os.path.dirname(report)), "assets", "report.json"))).get("metrics", {}).items():
        metrics[("assets_" + k) if k.startswith("memory") else k] = v
except Exception as e:
    print(f"no asset perf report ({e})", file=sys.stderr)
for line in open(smoke):
    try:
        d = json.loads(line); metrics[d["metric"]] = d["value"]
    except Exception:
        pass
metrics = {k: v for k, v in metrics.items() if not k.startswith("snapshot_")}
limits = json.load(open(th)).get(mode, {})
violations = []
for k, lim in limits.items():
    if k not in metrics: continue
    v = metrics[k]
    if "max" in lim and v > lim["max"]: violations.append(f"{k} = {v:.2f} > max {lim['max']}")
    if "min" in lim and v < lim["min"]: violations.append(f"{k} = {v:.2f} < min {lim['min']}")
if uicode != "0": violations.append(f"timeline perf script failed (exit {uicode})")
if metrics.get("unit_timing_budget_failures"): violations.append("a unit-test wall-clock budget failed (TimingBudget; see smoke.log)")
chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
res = {"mode": mode, "machine": {"chip": chip, "os": platform.mac_ver()[0]}, "metrics": metrics, "violations": violations}
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(res, open(out, "w"), indent=2, sort_keys=True)
for k in sorted(metrics):
    lim = limits.get(k, {})
    bound = (f"≤ {lim['max']}" if "max" in lim else "") + (f" ≥ {lim['min']}" if "min" in lim else "")
    print(f"  {k:36s} {metrics[k]:10.2f}  {bound}")
print(f"results: {out}")
if violations:
    print("PERF REGRESSION:\n  " + "\n  ".join(violations)); sys.exit(1)
print("PERF OK")
PY
