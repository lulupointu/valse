#!/usr/bin/env python3
"""Localization completeness check (run by scripts/test.sh).

Fails (exit 1) if:
  - a key exists in an en.lproj table but not in the matching fr.lproj table (or vice versa),
  - a literal key used in Swift sources (tr("…"), Text(loc: "…"), *Key: "…") is missing from every en table.
Dynamic keys (string interpolation) are covered by Swift tests (registry/enum keys).
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "app", "Sources")

def load_strings(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"✘ cannot parse {path}: {out.stderr.strip()}")
        sys.exit(1)
    return json.loads(out.stdout)

def tables():
    en, fr = {}, {}
    problems = []
    for module in sorted(os.listdir(SRC)):
        res = os.path.join(SRC, module, "Resources")
        if not os.path.isdir(res):
            continue
        en_dir, fr_dir = os.path.join(res, "en.lproj"), os.path.join(res, "fr.lproj")
        for name in sorted(os.listdir(en_dir)) if os.path.isdir(en_dir) else []:
            if not name.endswith(".strings"):
                continue
            e = load_strings(os.path.join(en_dir, name))
            fpath = os.path.join(fr_dir, name)
            if not os.path.exists(fpath):
                problems.append(f"{module}/fr.lproj/{name} is missing")
                f = {}
            else:
                f = load_strings(fpath)
            for k in sorted(set(e) - set(f)):
                problems.append(f"{module}/{name}: missing fr translation for '{k}'")
            for k in sorted(set(f) - set(e)):
                problems.append(f"{module}/{name}: fr key '{k}' not in en")
            for k, v in f.items():
                if isinstance(v, str) and not v.strip():
                    problems.append(f"{module}/{name}: empty fr value for '{k}'")
            en.update(e); fr.update(f)
        if os.path.isdir(fr_dir):
            for name in os.listdir(fr_dir):
                if name.endswith(".strings") and not os.path.exists(os.path.join(en_dir, name)):
                    problems.append(f"{module}/en.lproj/{name} is missing")
    return en, fr, problems

PATTERNS = [
    re.compile(r'\btr\(\s*"([^"\\]+)"'),
    re.compile(r'Text\(loc:\s*"([^"\\]+)"'),
    re.compile(r'L10n\.shared\.string\(\s*"([^"\\]+)"'),
    re.compile(r'\b(?:titleKey|nameKey|descriptionKey|groupKey|messageKey)\s*:\s*"([^"\\]+)"'),
    re.compile(r'\b(?:Edit|InsertClip|UpdateClip)\(\s*"([^"\\]+)"'),
    re.compile(r'(?:beginGesture|gestureName:|nameKey:)\s*\(?\s*"([^"\\]+)"'),
    re.compile(r'\b(?:nameKey|titleKey)\s*=\s*"([^"\\]+)"'),
]

def used_keys():
    keys = {}
    for dirpath, _, files in os.walk(SRC):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8").read()
            for pat in PATTERNS:
                for m in pat.finditer(text):
                    k = m.group(1)
                    if "\\(" in k or k.endswith("."):
                        continue
                    keys.setdefault(k, os.path.relpath(path, ROOT))
    return keys

def main():
    en, fr, problems = tables()
    for k, where in sorted(used_keys().items()):
        if k not in en:
            problems.append(f"key '{k}' used in {where} is missing from en tables")
    if problems:
        print("✘ localization check failed:")
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print(f"✔ localization complete: {len(en)} keys in en, {len(fr)} in fr")

if __name__ == "__main__":
    main()
