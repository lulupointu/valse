#!/usr/bin/env python3
"""Summarise docs/FEATURES.md status per area. Usage: feature_status.py [--list partial|blocked|todo] [--area PREFIX]"""
import re, sys, collections, pathlib
rows = []; area = None
for line in (pathlib.Path(__file__).resolve().parent.parent / "docs/FEATURES.md").read_text().splitlines():
    if line.startswith("## "): area = line[3:].strip()
    m = re.match(r"\|\s*([A-Z]{2,4}-\d{3})\s*\|", line)
    if m:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        status = cells[-1]; key = status.split()[0].strip("*:,(").lower() if status else "todo"
        rows.append((area, cells[0], cells[1], cells[4] if len(cells) > 4 else "", key, status))
args = sys.argv[1:]
want = args[args.index("--list") + 1] if "--list" in args else None
pref = args[args.index("--area") + 1] if "--area" in args else None
if want:
    for a, i, n, p, k, s in rows:
        if k.startswith(want) and (not pref or i.startswith(pref)): print(f"{i}  [{p}]  {n} — {s[:160]}")
    sys.exit()
by = collections.OrderedDict()
for a, i, n, p, k, s in rows: by.setdefault(a, collections.Counter())[k] += 1
tot = collections.Counter()
print(f"{'area':45} {'done':>5} {'part':>5} {'block':>5} {'todo':>5}")
for a, c in by.items():
    tot.update(c); other = sum(v for k, v in c.items() if k not in ("done", "partial", "blocked"))
    print(f"{a[:45]:45} {c['done']:5} {c['partial']:5} {c['blocked']:5} {other:5}")
other = sum(v for k, v in tot.items() if k not in ("done", "partial", "blocked"))
print(f"{'TOTAL (' + str(len(rows)) + ')':45} {tot['done']:5} {tot['partial']:5} {tot['blocked']:5} {other:5}")
