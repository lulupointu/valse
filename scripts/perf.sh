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
  env MONTAGE_PERF=1 ${ENVS[@]+"${ENVS[@]}"} ${WRAP[@]+"${WRAP[@]}"} swift test -c release --scratch-path .build/perf -Xswiftc -enable-testing --skip-build --filter 'PerfSmokeTests|PerfAuditTests|canvasBuildScalesTo600Clips|fiftyAnimatedCaptionsRenderFast' 2>&1 \
    | tee "$DIR/smoke.log" | grep -E '^\{"stack"' > "$DIR/smoke.jsonl"
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
