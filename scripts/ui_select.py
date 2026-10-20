#!/usr/bin/env python3
"""Selects the UI scripts relevant to a change (stage 1 of the gate, scripts/check_fast.sh).

  ui_select.py [--base main] [--explain] [--files f1 f2 …]

Changed files = `git diff --name-only <base>...HEAD` + uncommitted (staged, unstaged, untracked) changes, or --files.
Selection = the smoke set + rules of app/Tests/ui_map.txt + scripts referencing a dotted string literal (test ID,
l10n key, command name) found in a changed Swift file + changed scripts / fixtures / baselines. Prints one script path
per line (app/Tests/UIScripts/<name>.json); --explain prints why each was picked to stderr.
"""
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "app", "Tests", "UIScripts")
MAP = os.path.join(ROOT, "app", "Tests", "ui_map.txt")
LITERAL = re.compile(r'"((?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z0-9_]*(?:\\\()?)')   # "inspector.tab.\(  /  "cmd.split"


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if l.strip()] if r.returncode == 0 else []


def changed_files(base):
    files = set(git("diff", "--name-only", f"{base}...HEAD"))
    files |= set(git("diff", "--name-only", "HEAD"))
    files |= set(git("ls-files", "--others", "--exclude-standard"))
    return sorted(files)


def load_map():
    smoke, rules = [], []
    for raw in open(MAP, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("smoke:"):
            smoke = line[len("smoke:"):].split()
            continue
        parts = line.split()
        rules.append((parts[0], parts[1:]))
    return smoke, rules


def scripts():
    out = {}
    for p in sorted(glob.glob(os.path.join(UI, "*.json"))):
        out[os.path.basename(p)[:-5]] = open(p, encoding="utf-8").read()
    return out


def script_tokens(text):
    toks = set()
    for m in re.finditer(r'"([^"\\]{3,})"', text):
        s = m.group(1)
        if s.startswith("id:"):
            s = s[3:]
        toks.add(s)
    return toks


def main(argv):
    base, explain, files = "main", False, None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--base":
            base = argv[i + 1]; i += 2; continue
        if a == "--explain":
            explain = True; i += 1; continue
        if a == "--files":
            files = argv[i + 1:]; break
        print(__doc__, file=sys.stderr); return 2
    files = changed_files(base) if files is None else files
    smoke, rules = load_map()
    all_scripts = scripts()
    names = sorted(all_scripts)
    why = {}

    def pick(name_globs, reason):
        for g in name_globs:
            for n in fnmatch.filter(names, g):
                why.setdefault(n, reason)

    pick(smoke, "smoke set")
    tokens = {n: script_tokens(t) for n, t in all_scripts.items()}
    for f in files:
        rel = f
        if rel.startswith("app/Tests/UIScripts/") and rel.endswith(".json") and "/fixtures/" not in rel:
            pick([os.path.basename(rel)[:-5]], f"changed script {rel}")
            continue
        if rel.startswith("app/Tests/UIScripts/fixtures/"):
            sub = rel[len("app/Tests/UIScripts/"):]
            top = "/".join(sub.split("/")[:2])          # fixtures/<file or package dir>
            pick([n for n, t in all_scripts.items() if top in t], f"uses changed fixture {top}")
            continue
        if rel.startswith("app/Tests/Baselines/") and rel.endswith(".png"):
            b = os.path.basename(rel)[:-4]
            pick([n for n, t in all_scripts.items() if f'"{b}"' in t], f"uses changed baseline {b}")
            continue
        for pat, targets in rules:
            if fnmatch.fnmatch(rel, pat):
                if "ALL" in targets:
                    pick(["*"], f"{rel} matches {pat} → ALL")
                if "BASELINES" in targets:
                    pick([n for n, t in all_scripts.items() if '"baseline"' in t], f"{rel} matches {pat} → BASELINES")
                pick([t for t in targets if t not in ("ALL", "BASELINES", "NONE")], f"{rel} matches {pat}")
        if rel.endswith(".swift") and rel.startswith("app/Sources/") and os.path.exists(os.path.join(ROOT, rel)):
            src = open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace").read()
            lits = set()
            for m in LITERAL.finditer(src):
                s = m.group(1)
                prefix = s.endswith("\\(")
                s = s[:-2] if prefix else s
                if len(s) < 6 or s.count(".") == 0 or s.endswith(".swift"):
                    continue
                lits.add((s, prefix))
            for n, toks in tokens.items():
                if n in why:
                    continue
                for s, prefix in lits:
                    hit = next((t for t in toks if (t.startswith(s) if prefix else t == s)), None)
                    if hit:
                        why[n] = f"references {hit!r} from {rel}"
                        break
    for n in sorted(why):
        print(os.path.join("app", "Tests", "UIScripts", n + ".json"))
        if explain:
            print(f"  {n:34s} {why[n]}", file=sys.stderr)
    if explain:
        print(f"{len(why)} of {len(names)} UI scripts selected for {len(files)} changed file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
