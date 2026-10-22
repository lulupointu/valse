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

# Load rule (DX-C, OB-PERF): wall-clock, GPU-time and thread-CPU metrics GATE only when the 1-min load average stays <= the core count across
# the measurement (sampled before / after each part, max taken; MONTAGE_PERF_CORES overrides the core count). Taking
# every slot does not stop load from outside the slot system (VMs, other builds). Above it, the measurement is retried
# once after waiting <= 5 min for the load to drop; if still loaded, those metrics are reported "UNRELIABLE" and don't
# gate. Memory and gross GPU-time bounds always gate.
CORES="${MONTAGE_PERF_CORES:-$(sysctl -n hw.ncpu)}"
export MONTAGE_PERF_CORES="$CORES"   # TimingBudget uses the same core count for its load rule
LOADMAX=0
sample_load() { local l; l="$(sysctl -n vm.loadavg | awk '{ printf "%.2f", $2 }' | tr ',' '.')"; LOADMAX="$(awk -v a="$LOADMAX" -v b="$l" 'BEGIN { print (b > a ? b : a) }')"; }
loaded() { awk -v l="$LOADMAX" -v c="$CORES" 'BEGIN { exit !(l > c) }'; }

: > "$DIR/smoke.jsonl"
# In a git worktree, reuse the main checkout's bench media (gitignored, ~1 GB) instead of regenerating it.
if [[ ! -e bench/media ]]; then
  MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
  [[ -f "$MAIN/bench/media/.done" && "$MAIN" != "$ROOT" ]] && ln -s "$MAIN/bench/media" bench/media
fi
UNIT_TIMING='canvasBuildScalesTo600Clips|fiftyAnimatedCaptionsRenderFast|playbackDeliversFramesInRealTime|everyEffectFitsTheRealTimeBudget|manyCaptionsSyncFast|enhanceQualityRunsInRealTimeBudget|planIsFastEnoughForTheSlider|applyManyCutsIsQuick|thirtyMinutesIsFastAndCancellable'
swift build -c release --build-tests --scratch-path .build/perf -Xswiftc -enable-testing >&2  # incremental; needed even with --no-build

measure() {
  LOADMAX=0; : > "$DIR/smoke.jsonl"
  set +e
  sample_load
  # untimed warm-up launch: launch_ms measures app launch, not the first launch after a build (cold disk cache)
  printf '{"project": "empty", "steps": []}\n' > "$DIR/warmup.json"
  env ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} "$BIN" --uitest "$DIR/warmup.json" --uitest-out "$DIR/warmup" >/dev/null 2>&1
  echo "▶ timeline 500 clips ($MODE)" >&2
  env ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} "$BIN" --uitest "$ROOT/app/Tests/PerfScripts/timeline_500.json" --uitest-out "$DIR/ui" >&2
  UICODE=$?
  echo "▶ asset panel 1,000 items ($MODE)" >&2
  env ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} "$BIN" --uitest "$ROOT/app/Tests/PerfScripts/assets_1000.json" --uitest-out "$DIR/assets" >&2
  ACODE=$?
  [[ $UICODE == 0 ]] && UICODE=$ACODE
  sample_load
  # Wall-clock budgets of unit tests (TimingBudget: asserted with MONTAGE_PERF=1, skipped by the same load rule) —
  # ALWAYS run, also with --no-smoke and without bench/media: check_clean.sh --ui gates on them.
  echo "▶ unit-test timing budgets ($MODE)" >&2
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter "$UNIT_TIMING" 2>&1 \
    | tee "$DIR/unit-timing.log" | grep -E '^\{"stack"' >> "$DIR/smoke.jsonl"
  if grep -qE '^✘ Test ' "$DIR/unit-timing.log" || ! grep -qE 'Test run with [0-9]+ tests' "$DIR/unit-timing.log"; then
    echo '{"stack":"montage","metric":"unit_timing_budget_failures","value":1,"unit":"count"}' >> "$DIR/smoke.jsonl"   # failed / crashed
  fi
  sample_load
  set -e
}

measure
if loaded; then
  echo "⚠ machine loaded during the measurement (1-min load $LOADMAX > $CORES cores): waiting <= 5 min, then measuring again" >&2
  for ((w = 0; w < ${MONTAGE_PERF_LOAD_WAIT:-300}; w += 10)); do   # MONTAGE_PERF_LOAD_WAIT: seconds (self-check: 0)
    L="$(sysctl -n vm.loadavg | awk '{ print $2 }' | tr ',' '.')"
    awk -v l="$L" -v c="$CORES" 'BEGIN { exit !(l <= c) }' && break
    sleep 10
  done
  measure
fi
if [[ $SMOKE == 1 && -f bench/media/.done ]]; then
  echo "▶ 4K perf smoke + audit ($MODE)" >&2
  set +e
  # typical 1080p project memory: own process (its metric is the lifetime peak footprint)
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter 'PerfMemoryTests' 2>&1 \
    | tee "$DIR/memory.log" | grep -E '^\{"stack"' >> "$DIR/smoke.jsonl"
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter 'PerfSmokeTests|PerfAuditTests' 2>&1 \
    | tee "$DIR/smoke.log" | grep -E '^\{"stack"' >> "$DIR/smoke.jsonl"
  sample_load
  set -e
elif [[ $SMOKE == 1 ]]; then
  echo "  (4K perf smoke skipped: run bench/make_media.sh first)" >&2
fi
LOADED=0; loaded && LOADED=1
# timing checks the unit tests skipped themselves (TimingBudget load rule)
SKIPPED_TIMING="$(grep -c "timing check .* skipped" "$DIR/unit-timing.log" 2>/dev/null || true)"

python3 - "$MODE" "$DIR/ui/report.json" "$DIR/smoke.jsonl" "$TH" "$OUT" "$UICODE" "$LOADED" "$LOADMAX" "$CORES" "${SKIPPED_TIMING:-0}" <<'PY'
import json, sys, os, platform, subprocess
mode, report, smoke, th, out, uicode, loaded, loadmax, cores, skipped_timing = sys.argv[1:]
loaded = loaded == "1"
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
violations, unreliable = [], []
def load_ruled(k):
    # memory metrics are load-robust: they always gate; wall-clock, GPU-time and thread-CPU ones follow the load rule
    # (see the top of this script). Thread-CPU inflates 3-4x above load = cores (OB-PERF 2026-10-22: main 0.8 → 3.5 ms)
    return not ("memory" in k or k.endswith("_mb"))
for k, lim in limits.items():
    if k not in metrics: continue
    v = metrics[k]
    bad = []
    if "max" in lim and v > lim["max"]: bad.append(f"{k} = {v:.2f} > max {lim['max']}")
    if "min" in lim and v < lim["min"]: bad.append(f"{k} = {v:.2f} < min {lim['min']}")
    if loaded and load_ruled(k):
        unreliable.append(f"{k} = {v:.2f} UNRELIABLE (load {loadmax} > cores {cores})" + (f" — would violate: {bad[0]}" if bad else ""))
    else:
        violations.extend(bad)
for i in range(int(skipped_timing or 0)):
    unreliable.append(f"unit-test wall-clock timing check skipped by the load rule (load {loadmax} > cores {cores}; see unit-timing.log)")
if uicode != "0": violations.append(f"timeline perf script failed (exit {uicode})")
if metrics.get("unit_timing_budget_failures"): violations.append("a unit-test wall-clock budget failed or did not run (TimingBudget; see unit-timing.log)")
chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
res = {"mode": mode, "machine": {"chip": chip, "os": platform.mac_ver()[0]}, "metrics": metrics, "violations": violations,
       "unreliable": unreliable, "load": {"max_1min": float(loadmax), "cores": int(cores), "loaded": loaded}}
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(res, open(out, "w"), indent=2, sort_keys=True)
for k in sorted(metrics):
    lim = limits.get(k, {})
    bound = (f"≤ {lim['max']}" if "max" in lim else "") + (f" ≥ {lim['min']}" if "min" in lim else "")
    print(f"  {k:36s} {metrics[k]:10.2f}  {bound}")
print(f"results: {out}")
for u in unreliable: print("UNRELIABLE: " + u)
if unreliable: print(f"perf: {len(unreliable)} metrics unverified due to load")
if violations:
    print("PERF REGRESSION:\n  " + "\n  ".join(violations)); sys.exit(1)
print("PERF OK")
PY
