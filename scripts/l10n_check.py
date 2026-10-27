#!/usr/bin/env python3
"""Localization completeness check (run by scripts/test.sh).

Fails (exit 1) if:
  - a key exists in an en.lproj table but not in the matching fr.lproj table (or vice versa),
  - a literal key used in Swift sources (tr("…"), Text(loc: "…"), *Key: "…") is missing from every en table,
  - (U1) format arguments don't line up: en and fr have a different number of placeholders (%@, %d, %1$@…), a key
    is defined twice (two tables) with a different number of placeholders (whichever table loads last wins), or a
    literal `tr("key")` / `Text(loc: "key")` with NO arguments uses a string that has placeholders (shows "%@").
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

PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfFeEgGcCsSpaA]')

def placeholders(s):
    return len(PLACEHOLDER.findall(s.replace("%%", ""))) if isinstance(s, str) else 0

def tables():
    en, fr = {}, {}
    problems = []
    defined = {}   # (lang, key) -> [(table, value)]
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
            for lang, tab in (("en", e), ("fr", f)):
                for k, v in tab.items():
                    defined.setdefault((lang, k), []).append((f"{module}/{name}", v))
            en.update(e); fr.update(f)
        if os.path.isdir(fr_dir):
            for name in os.listdir(fr_dir):
                if name.endswith(".strings") and not os.path.exists(os.path.join(en_dir, name)):
                    problems.append(f"{module}/en.lproj/{name} is missing")
    for (lang, k), defs in sorted(defined.items()):
        if len({placeholders(v) for _, v in defs}) > 1:
            problems.append(f"{lang} key '{k}' defined in {', '.join(t for t, _ in defs)} with different format arguments")
    for k, v in en.items():
        if k in fr and placeholders(v) != placeholders(fr[k]):
            problems.append(f"'{k}': en has {placeholders(v)} format argument(s), fr has {placeholders(fr[k])}")
    return en, fr, problems

NO_ARGS = re.compile(r'\btr\(\s*"([^"\\]+)"\s*\)|Text\(loc:\s*"([^"\\]+)"\s*\)')

def calls_without_args():
    out = []
    for dirpath, _, files in os.walk(SRC):
        for fn in files:
            if fn.endswith(".swift"):
                path = os.path.join(dirpath, fn)
                text = open(path, encoding="utf-8").read()
                for m in NO_ARGS.finditer(text):
                    out.append((m.group(1) or m.group(2), f"{os.path.relpath(path, ROOT)}:{text.count(chr(10), 0, m.start()) + 1}"))
    return out

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

TUTOIEMENT = re.compile(r"\b(?:[Tt]u|[Tt]oi|[Rr]éessaie|[Ee]ssaie|[Vv]érifie-|Choisis|Saisis|Décris|Peins|Clique|Fais)\b")

def main():
    en, fr, problems = tables()
    # BUG-ERROR-COPY: French UI text uses "vous" (style guide, docs/UX.md "Error messages")
    for k, v in sorted(fr.items()):
        m = TUTOIEMENT.search(v) if isinstance(v, str) else None
        if m:
            problems.append(f"fr '{k}' uses tutoiement ({m.group(0)}): write it with \"vous\"")
    for k, where in sorted(used_keys().items()):
        if k not in en:
            problems.append(f"key '{k}' used in {where} is missing from en tables")
    for k, where in calls_without_args():
        if placeholders(en.get(k)) > 0:
            problems.append(f"{where}: '{k}' needs {placeholders(en[k])} format argument(s), called without any")
    if problems:
        print("✘ localization check failed:")
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print(f"✔ localization complete: {len(en)} keys in en, {len(fr)} in fr")

if __name__ == "__main__":
    main()
