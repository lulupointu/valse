#!/usr/bin/env python3
"""Aggregate bench/results/<stack>-r<N>.jsonl (+ -bg.jsonl, footprint.jsonl) into a median/spread table.
Usage: python3 -I bench/aggregate.py [results_dir]  -> prints a markdown table and writes summary.json"""
import json, sys, os, glob, statistics
from collections import defaultdict

RES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
STACKS = ["swift-native", "electron-web", "tauri-rust", "qt-cpp"]
vals = defaultdict(lambda: defaultdict(list))  # metric -> stack -> [values]

def load(path, stack):
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            line = line.replace('"value":242,8', '"value":242.8')
            try: d = json.loads(line)
            except json.JSONDecodeError: continue
        m, v = d.get("metric"), d.get("value")
        if isinstance(v, bool): v = 1.0 if v else 0.0
        if not isinstance(v, (int, float)): continue
        vals[m][stack].append(float(v))
        # electron puts peak RSS in an extra field
        if m and m.endswith("_rss_mb") and "peak" in d:
            vals[m.replace("_rss_mb", "_rss_peak_mb")][stack].append(float(d["peak"]))

for s in STACKS:
    for f in sorted(glob.glob(os.path.join(RES, f"{s}-r*.jsonl"))) + sorted(glob.glob(os.path.join(RES, f"{s}-bg*.jsonl"))) + sorted(glob.glob(os.path.join(RES, f"{s}-util*.jsonl"))):
        load(f, s)
fp = os.path.join(RES, "footprint.jsonl")
if os.path.exists(fp):
    for line in open(fp):
        d = json.loads(line); vals[d["metric"]][d["stack"]].append(float(d["value"]))

summary = {}
def fmt(xs):
    if not xs: return "—"
    med = statistics.median(xs)
    f = (lambda x: f"{x:.0f}") if abs(med) >= 100 else (lambda x: f"{x:.1f}") if abs(med) >= 1 else (lambda x: f"{x:.3f}")
    if len(xs) > 1 and max(xs) != min(xs):
        return f"{f(med)} ({f(min(xs))}–{f(max(xs))})"
    return f(med)

print("| metric | " + " | ".join(STACKS) + " |")
print("|---|" + "---|" * len(STACKS))
for m in sorted(vals):
    row = []
    for s in STACKS:
        xs = vals[m].get(s, [])
        row.append(fmt(xs))
        if xs: summary.setdefault(m, {})[s] = {"median": statistics.median(xs), "min": min(xs), "max": max(xs), "n": len(xs)}
    print(f"| {m} | " + " | ".join(row) + " |")
json.dump(summary, open(os.path.join(RES, "summary.json"), "w"), indent=1)
