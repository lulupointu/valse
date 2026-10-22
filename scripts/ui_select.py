#!/usr/bin/env python3
"""Selects the UI scripts relevant to a change (stage 1 of the gate, scripts/check_fast.sh).

  ui_select.py [--base auto|<ref>] [--explain] [--files f1 f2 …]
  ui_select.py --commit <sha> [--explain]          # replay: the diff of <sha> vs its first parent, files read at <sha>

Changed files = `git diff <base>...HEAD` + uncommitted (staged, unstaged, untracked) changes, or --files / --commit.
--base auto (default): the nearest of main / the local batch-* branches HEAD is based on (the most recent merge-base;
a batch that already contains HEAD doesn't count), so a branch made from a batch branch isn't diffed against main.
Prints one script path per line (app/Tests/UIScripts/<name>.json); --explain prints WHY each one was picked to stderr.

What a script depends on is derived from the script itself (actions, target kinds, test IDs, state-dump paths, menu
paths, project, language, baselines), so most selection needs no hand-written mapping:
  - a changed script / fixture / baseline selects the scripts using it;
  - UITestDriver.swift / SyntheticEvents.swift: each changed hunk is attributed to the step action (`perform` branch),
    target kind (`resolveBase` case), project kind (`setUp` case) or helper it lives in → only the scripts using that
    (DRIVER_FUNCS below); hunks in the driver core (run loop, idle, event dispatch) → ALL;
  - StateDump.swift: the dump keys written / read by the changed lines (`"key":`, `ui["key"]`, plus the keys fed by a
    changed `let x = …` / `func f`) → the scripts whose `expect` / `waitFor` paths go through those keys;
  - Resources/<lang>.lproj/*.strings: the changed keys → scripts in that language that use the key or its old/new text
    literally, plus the baseline-snapshot scripts the Swift files rendering the key would select;
  - any other app/Sources Swift file (see "Swift reach" below): each changed declaration → the test IDs / l10n keys /
    command names it contains, else those around the code using it (≤ 3 levels; the nearest hook wins, then one more
    level for scripts with a baseline snapshot); reaching UITestDriver / StateDump selects the scripts using that
    step / dump key; identifiers on changed lines that the state dump exposes (`.editingGuide`) → scripts reading
    that key; a declaration that reaches no test hook → the ui_map.txt directory (fallback) rule of its file;
  - ui_map.txt `always` rules (app entry, theme, render / playback engine) and, for non-Swift files, its rules.
Plus a small smoke set (ui_map.txt `smoke:`). Unknown territory (a hunk the parsers cannot attribute) falls back to ALL.
Unit tests: scripts/test_ui_select.py (run by scripts/test.sh).
"""
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI_DIR = "app/Tests/UIScripts"
MAP = "app/Tests/ui_map.txt"
TESTING = "app/Sources/MontageUI/Testing/"
LITERAL = re.compile(r'"((?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z0-9_]*(?:\\\()?)')   # "inspector.tab.\(  /  "cmd.split"
ACTIONS = ["click", "press", "doubleClick", "rightClick", "contextMenu", "drag", "scroll", "hover", "key", "type", "menu", "drop", "dragExit",
           "release", "wait", "idle", "snapshot", "dump", "expect", "waitFor", "seek", "select", "perf", "metric", "log",
           "a11yAudit"]
TARGET_KEYS = ["click", "doubleClick", "rightClick", "contextMenu", "drag", "to", "hover", "scroll", "on", "select"]


# ───────────────────────────── sources: the working tree vs a base, or one commit vs its parent ─────────────────────────────

def _git(*args, check=False):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, errors="replace")
    if check and r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout if r.returncode == 0 else ""


class Source:
    """Where the change and the files come from. `old` = before the change, `new` = after (None: file absent)."""
    def changed(self): raise NotImplementedError
    def read_new(self, path): raise NotImplementedError
    def read_old(self, path): raise NotImplementedError
    def list_new(self, prefix): raise NotImplementedError
    def grep_new(self, needle, prefix):
        """Files under `prefix` (new version) containing the fixed string `needle`."""
        raise NotImplementedError

    def swift_files(self, prefix):
        """Every .swift file under `prefix` (new version)."""
        raise NotImplementedError

    def grep_word(self, word, prefix):
        """Swift files under `prefix` (new version) using the identifier `word` (one word index per source)."""
        idx = getattr(self, "_words", None)
        if idx is None or idx[0] != prefix:
            words = {}
            for path in self.swift_files(prefix):
                for w in set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', self.read_new(path) or "")):
                    words.setdefault(w, []).append(path)
            self._words = idx = (prefix, words)
        return sorted(idx[1].get(word, ()))


def auto_base(root=None):
    """The diff base of a feature branch: the nearest of `main` / local `batch-*` branches it is based on, i.e. the one
    whose merge-base with HEAD is the most recent (fewest commits between it and HEAD; ties → main). A branch that
    already contains HEAD (the batch this branch was merged into) is not a base. → (ref, merge-base sha, note)."""
    def git(*a):
        r = subprocess.run(["git", "-C", root or ROOT, *a], capture_output=True, text=True, errors="replace")
        return r.stdout.strip() if r.returncode == 0 else ""
    head = git("rev-parse", "HEAD")
    refs = ["main"] + sorted(b for b in git("for-each-ref", "--format=%(refname:short)", "refs/heads/batch-*").split("\n") if b)
    best = None
    for ref in refs:
        tip = git("rev-parse", "--verify", "-q", ref + "^{commit}")
        if not tip:
            continue
        if tip != head and subprocess.run(["git", "-C", root or ROOT, "merge-base", "--is-ancestor", head, tip]).returncode == 0:
            continue                                   # HEAD already merged into it: it's not what this branch is based on
        mb = git("merge-base", ref, "HEAD")
        if not mb:
            continue
        ahead = int(git("rev-list", "--count", f"{mb}..HEAD") or 0)
        if best is None or ahead < best[2]:
            best = (ref, mb, ahead)
    if best is None:
        return "main", git("merge-base", "main", "HEAD"), "main (no main / batch-* branch is a base of HEAD)"
    ref, mb, ahead = best
    return ref, mb, f"{ref} (auto: nearest of main / batch-*; merge-base {mb[:7]}, {ahead} commit(s) ahead)"


class WorkTree(Source):
    def __init__(self, base="auto", files=None):
        self.files = files
        if base == "auto":
            base, mb, self.note = auto_base()
        else:
            mb = _git("merge-base", base, "HEAD").strip()
            self.note = f"{base} (--base; merge-base {mb[:7]})" if mb else base
        self.ref = base
        self.base = mb or base

    def changed(self):
        if self.files is not None:
            return sorted(set(self.files))
        files = set(_git("diff", "--name-only", self.base).split("\n"))          # merge-base → working tree (staged + unstaged)
        files |= set(_git("ls-files", "--others", "--exclude-standard").split("\n"))
        return sorted(f for f in files if f.strip())

    def read_new(self, path):
        p = os.path.join(ROOT, path)
        if not os.path.isfile(p):
            return None
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()

    def read_old(self, path):
        if self.files is not None and path in self.files and path != MAP:
            return None          # --files: the whole file counts as changed (it may not differ from the base yet)
        r = subprocess.run(["git", "-C", ROOT, "show", f"{self.base}:{path}"], capture_output=True, text=True, errors="replace")
        return r.stdout if r.returncode == 0 else None

    def list_new(self, prefix):
        return sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, prefix, "*")))

    def grep_new(self, needle, prefix):
        r = subprocess.run(["grep", "-rlF", "--include=*.swift", needle, os.path.join(ROOT, prefix)], capture_output=True, text=True)
        return sorted(os.path.relpath(p, ROOT) for p in r.stdout.split("\n") if p.strip())

    def swift_files(self, prefix):
        out = []
        for d, _, fs in os.walk(os.path.join(ROOT, prefix)):
            out += [os.path.relpath(os.path.join(d, f), ROOT) for f in fs if f.endswith(".swift")]
        return sorted(out)


class _Cat:
    """One `git cat-file --batch` process: fast blob reads for history replays (`--commit`)."""
    proc = None

    @classmethod
    def read(cls, spec):
        if cls.proc is None:
            cls.proc = subprocess.Popen(["git", "-C", ROOT, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        cls.proc.stdin.write((spec + "\n").encode()); cls.proc.stdin.flush()
        head = cls.proc.stdout.readline().decode().split()
        if len(head) < 3 or head[1] == "missing":
            return None
        data = cls.proc.stdout.read(int(head[2])); cls.proc.stdout.read(1)
        return data.decode("utf-8", errors="replace") if head[1] == "blob" else None


class Commit(Source):
    def __init__(self, sha):
        self.sha = _git("rev-parse", sha, check=True).strip()
        parents = _git("rev-list", "--parents", "-n", "1", self.sha).split()
        self.parent = parents[1] if len(parents) > 1 else None

    def changed(self):
        if not self.parent:
            return []
        return sorted(f for f in _git("diff", "--name-only", self.parent, self.sha).split("\n") if f.strip())

    def read_new(self, path): return _Cat.read(f"{self.sha}:{path}")
    def read_old(self, path): return _Cat.read(f"{self.parent}:{path}") if self.parent else None

    def list_new(self, prefix):
        return sorted(f"{prefix}/{f}" for f in _git("ls-tree", "--name-only", f"{self.sha}:{prefix}/").split("\n") if f.strip())

    def blob_ids(self, prefix):
        out = {}
        for l in _git("ls-tree", f"{self.sha}:{prefix}/").split("\n"):
            if "\t" in l:
                meta, name = l.split("\t", 1)
                out[f"{prefix}/{name}"] = meta.split()[2]
        return out

    def grep_new(self, needle, prefix):
        out = _git("grep", "-lF", needle, self.sha, "--", f"{prefix}/*.swift")
        return sorted(l.split(":", 1)[1] for l in out.split("\n") if ":" in l)

    def swift_files(self, prefix):
        return sorted(f for f in _git("ls-tree", "-r", "--name-only", self.sha, "--", prefix).split("\n") if f.endswith(".swift"))


# ───────────────────────────── diff hunks ─────────────────────────────

def changed_lines(old, new):
    """(removed [(old line no, text)], added [(new line no, text)]) between two versions (difflib, no git needed)."""
    import difflib
    a = (old or "").split("\n")
    b = (new or "").split("\n")
    removed, added = [], []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag in ("replace", "delete"):
            removed += [(i + 1, a[i]) for i in range(i1, i2)]
        if tag in ("replace", "insert"):
            added += [(j + 1, b[j]) for j in range(j1, j2)]
    return removed, added


def is_noise(line):
    s = line.strip()
    return (not s or s.startswith(("//", "/*", "*", "import ", "@testable import ")) or s in ("{", "}", ")", "]")
            or s.startswith("// MARK"))


def indent(line):
    return len(line) - len(line.lstrip(" "))


# ───────────────────────────── scripts ─────────────────────────────

class Script:
    def __init__(self, name, text, baselines=()):
        self.name, self.text = name, text
        stripped = "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))
        try:
            self.obj = json.loads(stripped)
        except ValueError:
            self.obj = {}
        self.actions, self.options, self.targets, self.ids, self.paths, self.menus = set(), set(), set(), set(), set(), set()
        self.strings, self.baselines, self.snapshots, self.drops = set(), set(), set(), set()
        self.window_baseline = False
        self.baseline_elements = set()
        self.project = str(self.obj.get("project", "empty"))
        self.requires = self.obj.get("requires") or {}
        langs = {self.obj.get("lang", "en")}
        if "language.fr" in text or '"fr"' in text:
            langs.add("fr")
        self.langs = langs
        def walk(x):
            if isinstance(x, dict):
                for k, v in x.items():
                    yield k
                    yield from walk(v)
            elif isinstance(x, list):
                for v in x:
                    yield from walk(v)
            elif isinstance(x, str):
                yield x
        strs = list(walk(self.obj)) if self.obj else re.findall(r'"((?:[^"\\]|\\.)*)"', stripped)
        for s in strs:
            if len(s) < 2:
                continue
            self.strings.add(s[3:] if s.startswith("id:") else s)
            if s.startswith("id:"):
                self.ids.add(s[3:])
            for part in s.split("/") if "/" in s and not s.startswith(("fixtures", ".", "/")) else ():
                self.strings.add(part)          # "menu.file/menu.export", "tlmenu.a/tlmenu.b" → each key
        for step in self.obj.get("steps", []) if isinstance(self.obj.get("steps"), list) else []:
            if not isinstance(step, dict):
                continue
            for k in step:
                (self.actions if k in ACTIONS else self.options).add(k)
            for k in TARGET_KEYS:
                v = step.get(k)
                for t in (v if isinstance(v, list) else [v]):
                    if isinstance(t, str) and ":" in t:
                        self.targets.add(t.split(":", 1)[0])
                    elif isinstance(t, (list, dict)) and k != "select":
                        self.targets.add("point")
            for k in ("expect", "waitFor"):
                v = step.get(k)
                for spec in (v if isinstance(v, list) else [v]):
                    if isinstance(spec, dict) and isinstance(spec.get("path"), str):
                        self.paths.add(spec["path"])
            if isinstance(step.get("menu"), str):
                self.menus |= set(step["menu"].split("/"))
            if isinstance(step.get("menuItem"), str):
                self.menus |= set(step["menuItem"].split("/"))
            if "contextMenu" in step and isinstance(step.get("item"), str):
                self.menus |= set(step["item"].split("/"))
            if isinstance(step.get("snapshot"), str):
                self.snapshots.add(step["snapshot"])
                if "baseline" in step:
                    self.baselines.add(step["baseline"] if isinstance(step["baseline"], str) else step["snapshot"])
                    if "element" not in step:
                        self.window_baseline = True     # a full-window baseline renders the whole screen
                    elif isinstance(step["element"], str):
                        self.baseline_elements.add(step["element"][3:] if step["element"].startswith("id:") else step["element"])
            if isinstance(step.get("drop"), dict):
                self.drops |= set(step["drop"])
        self.segments = {seg for p in self.paths for seg in p.split(".")}

    def uses(self, what):
        return what in self.actions or what in self.options


_SCRIPT_CACHE = {}


def load_scripts(src):
    out = {}
    ids = src.blob_ids(UI_DIR) if hasattr(src, "blob_ids") else None
    for p in src.list_new(UI_DIR):
        if p.endswith(".json"):
            n = os.path.basename(p)[:-5]
            if ids and ids.get(p):
                key = (n, ids[p])
                if key not in _SCRIPT_CACHE:
                    _SCRIPT_CACHE[key] = Script(n, _Cat.read(ids[p]) or "")
                out[n] = _SCRIPT_CACHE[key]
            else:
                out[n] = Script(n, src.read_new(p) or "")
    return out


def load_map(src, text=None):
    smoke, rules = [], []
    text = text if text is not None else (src.read_new(MAP) or "")
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("smoke:"):
            smoke = line[len("smoke:"):].split()
            continue
        parts = line.split()
        always = parts[0] == "always"
        if always:
            parts = parts[1:]
        rules.append((parts[0], parts[1:], always))
    return smoke, rules


# ───────────────────────────── the selection ─────────────────────────────

ALL = "ALL"


class Selection:
    def __init__(self, scripts):
        self.scripts = scripts
        self.why = {}

    def add(self, names, reason):
        for n in names:
            if n in self.scripts:
                self.why.setdefault(n, []).append(reason)

    def add_if(self, pred, reason):
        self.add([n for n, s in self.scripts.items() if pred(s)], reason)

    def add_globs(self, globs, reason):
        names = sorted(self.scripts)
        for g in globs:
            self.add(fnmatch.filter(names, g), reason)


# Driver / event helpers → which scripts exercise them. Keys: "<file>:<func>" (func = enclosing declaration of the
# changed line). Value: predicate over Script, or ALL. Unlisted function in these files → ALL.
def _any_target(s): return bool(s.targets)
def _id_pointer(s): return "id" in s.targets
def _uses(*names): return lambda s: any(s.uses(n) for n in names)

DRIVER_FUNCS = {
    "UITestDriver.swift:axElement": _uses("press"),
    "UITestDriver.swift:scrollIntoView": _id_pointer,
    "UITestDriver.swift:resolve": _any_target,
    "UITestDriver.swift:point": _any_target,
    "UITestDriver.swift:clip": lambda s: "clip" in s.targets or s.uses("select"),
    "UITestDriver.swift:timelineView": lambda s: bool(s.targets & {"clip", "time", "header"}),
    "UITestDriver.swift:findView": lambda s: _id_pointer(s) or s.uses("snapshot"),
    "UITestDriver.swift:deliverScroll": _uses("scroll"),
    "UITestDriver.swift:performMenu": _uses("menu", "menuItem", "contextMenu"),
    "UITestDriver.swift:contextMenu": _uses("contextMenu"),
    "UITestDriver.swift:drop": _uses("drop"),
    "UITestDriver.swift:snapshot": _uses("snapshot"),
    "UITestDriver.swift:resize": _uses("snapshot"),
    "UITestDriver.swift:baselineURL": lambda s: bool(s.baselines),
    "UITestDriver.swift:prepareProcess": lambda s: bool(s.baselines),
    "UITestDriver.swift:osConditionUnmet": lambda s: bool(s.options & {"minOS", "maxOS", "ffmpeg"}),
    "UITestDriver.swift:osMajor": lambda s: bool(s.options & {"minOS", "maxOS", "ffmpeg"}) or "minOS" in s.requires or bool(s.baselines),
    "UITestDriver.swift:skipExitCode": lambda s: bool(s.requires),
    "UITestDriver.swift:perf": _uses("perf"),
    "UITestDriver.swift:perfInteraction": _uses("perf"),
    "UITestDriver.swift:measure": _uses("perf"),
    "UITestDriver.swift:pauseAnchors": _uses("perf"),
    "UITestDriver.swift:viewScrollPerf": _uses("perf"),
    "UITestDriver.swift:recordMetric": _uses("metric"),
    "UITestDriver.swift:measureOpenProject": _uses("metric"),
    "UITestDriver.swift:makeBin": lambda s: s.project.startswith("media:"),
    "UITestDriver.swift:make": lambda s: s.project.startswith("stress"),
    "UITestDriver.swift:trackSlider": _any_target,          # NSSlider emulation: any pointer script may hit a slider
    "UITestDriver.swift:acceptFirstMouse": _any_target,
    "UITestDriver.swift:isSwiftUIView": _any_target,
    "SyntheticEvents.swift:click": _uses("click", "doubleClick", "rightClick"),
    "SyntheticEvents.swift:drag": _uses("drag"),
    "SyntheticEvents.swift:move": _uses("hover"),
    "SyntheticEvents.swift:scroll": _uses("scroll"),
    "SyntheticEvents.swift:modifiers": _uses("modifiers"),
    "SyntheticEvents.swift:parseKey": _uses("key"),
    "SyntheticEvents.swift:key": _uses("key"),
    "SyntheticEvents.swift:type": _uses("type"),
    "SyntheticEvents.swift:installKeyRouting": _uses("key", "type"),
    "SyntheticEvents.swift:slideDraggedImage": _uses("drop"),
    "SyntheticEvents.swift:enumerateDraggingItems": _uses("drop"),
    "SyntheticEvents.swift:resetSpringLoading": _uses("drop"),
    "SyntheticEvents.swift:SyntheticDraggingInfo": _uses("drop"),
}
# Whole test-support files → scripts.
TESTING_FILES = {
    "ImageDiff.swift": lambda s: bool(s.baselines),
    "ImageDiffCLI.swift": None,                               # CLI only (scripts/imgdiff.sh)
    "AccessibilityAudit.swift": _uses("a11yAudit"),
    "AccessibilityAuditAX.swift": _uses("a11yAudit"),
    "PerfProbe.swift": lambda s: s.uses("perf") or s.uses("metric"),
    "SettingsScrollProbe.swift": lambda s: any(p.startswith("ui.settings") for p in s.paths),
    "JSONPath.swift": lambda s: s.uses("expect") or s.uses("waitFor"),
    "TestID.swift": ALL,
}
DECL = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|class|final|nonisolated|override|'
                  r'mutating|lazy|weak)\s+)*(?:func|var|let|init|subscript|class|struct|enum|extension)\b\s*([A-Za-z_]\w*)?')


def enclosing_decl(lines, ln):
    """Name of the innermost declaration (func / var / type) containing 1-based line `ln`, or None at top level."""
    target = lines[ln - 1] if 0 < ln <= len(lines) else ""
    m = DECL.match(target)
    if m and m.group(1):
        name = m.group(1)
    else:
        name = None
    lim = indent(target) if target.strip() else 10 ** 6
    best = name
    if best is not None and not target.strip().startswith(("let ", "var ")):
        return best
    for i in range(ln - 2, -1, -1):
        l = lines[i]
        if not l.strip() or l.strip().startswith("//"):
            continue
        if indent(l) < lim:
            m = DECL.match(l)
            if m and re.search(r'\b(func|init|var|class|struct|enum|extension)\b', l.split("=")[0]) and m.group(1):
                d = m.group(1)
                # a `let`/`var` inside a function is not a declaration of interest: keep looking for the function
                if re.match(r'^\s*(let|var)\b', l) and indent(l) >= 8:
                    lim = indent(l)
                    continue
                return d
            lim = min(lim, indent(l))
    return best


def perform_branch(lines, ln):
    """For a line inside UITestDriver.perform: the step keys of the `if let … = step["x"]` branch it is in (or None)."""
    lim = indent(lines[ln - 1]) if lines[ln - 1].strip() else 10 ** 6
    for i in range(ln - 1, -1, -1):
        l = lines[i]
        if re.match(r'^\s*(private )?func perform\(', l):
            return None
        if l.strip() and indent(l) <= lim and re.match(r'^\s*(\} else )?if\b', l) and 'step["' in l:
            return set(re.findall(r'step\["(\w+)"\]', l))
        if l.strip() and indent(l) < lim:
            lim = indent(l)
    return None


def switch_case(lines, ln, func):
    """For a line inside `func`'s switch: the `case …:` it belongs to (text), or None when outside a case."""
    lim = indent(lines[ln - 1]) if lines[ln - 1].strip() else 10 ** 6
    for i in range(ln - 1, -1, -1):
        l = lines[i]
        if re.match(rf'^\s*(public |private |static )*func {func}\(', l):
            return None
        if l.strip() and indent(l) <= lim and re.match(r'^\s*(case\b.*:|default:)', l):
            return l.strip()
        if l.strip() and indent(l) < lim:
            lim = indent(l)
    return None


def project_pred(case):
    m = re.match(r'case "([^"]+)":', case)
    if m:
        return lambda s, v=m.group(1): s.project == v
    m = re.search(r'hasPrefix\("([^"]+)"\)', case)
    if m:
        return lambda s, v=m.group(1): s.project.startswith(v)
    if case.startswith("default"):
        return lambda s: "/" in s.project or s.project.endswith(".montage")
    return None


def target_pred(case):
    kinds = re.findall(r'"(\w+)"', case)
    return (lambda s, k=set(kinds): bool(s.targets & k)) if kinds else None


def driver_hunk_preds(fname, lines, ln):
    """→ (predicate | ALL, description) for one changed line of UITestDriver.swift / SyntheticEvents.swift."""
    func = enclosing_decl(lines, ln)
    if fname == "UITestDriver.swift" and func == "perform":
        keys = perform_branch(lines, ln)
        if keys:
            keys = {k for k in keys if k in ACTIONS} or keys
            return (lambda s, k=keys: any(s.uses(x) for x in k)), f"perform ▸ {'/'.join(sorted(keys))} steps"
        return ALL, "perform (step dispatch core)"
    if fname == "UITestDriver.swift" and func == "resolveBase":
        case = switch_case(lines, ln, "resolveBase")
        p = target_pred(case) if case else None
        if p:
            return p, f"target {case}"
        return _any_target, "target resolution"
    if fname == "UITestDriver.swift" and func == "setUp":
        case = switch_case(lines, ln, "setUp")
        p = project_pred(case) if case else None
        if p:
            return p, f"setUp project {case}"
        return ALL, "setUp (every script)"
    key = f"{fname}:{func}"
    if key in DRIVER_FUNCS:
        return DRIVER_FUNCS[key], f"{func}()"
    return ALL, f"{func or 'top level'} (driver core)"


DUMP_KEY = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:|\w\["([A-Za-z_][A-Za-z0-9_]*)"\]')


def dump_keys(line):
    return {a or b for a, b in DUMP_KEY.findall(line)}


def statedump_keys(lines, ln, depth=0):
    """State-dump keys affected by changed line `ln` of a dump-producing file: the keys on the line, else on its block
    (the following more-indented lines), else the keys of the lines using the name it declares (let x / func f)."""
    line = lines[ln - 1]
    keys = dump_keys(line)
    if keys:
        return keys
    ind = indent(line)
    for l in lines[ln:]:
        if not l.strip():
            continue
        if indent(l) <= ind:
            break
        keys |= dump_keys(l)
    if keys:
        return keys
    m = re.match(r'^\s*(?:(?:static|private|public|func|let|var)\s+)+([A-Za-z_]\w*)', line)
    if m and depth < 3:
        name = m.group(1)
        for i, l in enumerate(lines):
            if i != ln - 1 and re.search(rf'\b{re.escape(name)}\b', l) and not l.strip().startswith("//"):
                keys |= statedump_keys(lines, i + 1, depth + 1)
    return keys


STRINGS_LINE = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def strings_entries(text):
    out = {}
    for l in (text or "").split("\n"):
        m = STRINGS_LINE.match(l)
        if m:
            out[m.group(1)] = m.group(2)
    return out


# ───────────────────────────── Swift reach: changed lines → declarations → their users → literals ─────────────────────────────
#
# A Swift file is split into declaration blocks (func / var / init / type …, by indentation). A changed line belongs to its
# innermost non-local block. The dotted string literals (test IDs, l10n keys, command names) of that block are what the
# change can affect directly; the block's name is then looked up in app/Sources (`grep -w`) and the blocks USING it add
# their literals too, REACH_DEPTH levels deep. Scripts using one of those literals are selected. Names that are too
# generic (`body`, `init`, …, or used in more than REACH_MAX_FILES files) are not followed; a `body` / generic member is
# followed through its enclosing type's name instead.

DECL_RE = re.compile(r'^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|class|final|'
                     r'nonisolated|override|mutating|lazy|weak|unowned|open|required|convenience|dynamic|indirect)'
                     r'(?:\([^)]*\))?\s+)*(func|var|let|init|subscript|class|struct|enum|extension|protocol|actor)\b\s*'
                     r'([A-Za-z_]\w*)?')
TYPE_KINDS = {"class", "struct", "enum", "extension", "protocol", "actor"}
GENERIC_NAMES = {"body", "init", "make", "update", "view", "content", "value", "id", "label", "title", "name", "run", "start",
                 "stop", "apply", "reset", "load", "save", "dump", "description", "hash", "encode", "decode", "shared", "store",
                 "state", "model", "item", "items", "text", "string", "data", "result", "action", "handle", "perform", "main",
                 "count", "index", "key", "kind", "type", "style", "color", "font", "size", "frame", "rect", "point", "time",
                 "duration", "start", "end", "range", "url", "path", "image", "icon", "help", "makeBody", "layout", "draw",
                 "isEnabled", "isSelected", "selection", "project", "clip", "track", "media", "asset", "engine", "player",
                 "window", "view", "views", "row", "rows", "cell", "section", "sections", "header", "footer", "button",
                 "toggle", "picker", "slider", "field", "list", "grid", "tab", "tabs", "panel", "menu", "sheet", "dialog",
                 "close", "open", "show", "hide", "refresh", "reload", "clear", "add", "remove", "insert", "delete", "set", "get"}
SWIFT_WORDS = {"let", "var", "func", "return", "self", "true", "false", "nil", "guard", "else", "case", "switch", "where",
               "some", "Any", "with", "map", "compactMap", "flatMap", "sorted", "filter", "first", "last", "count", "isEmpty"}
BRIDGE_STOP = {"seconds", "count", "map", "description", "rawValue", "shared", "store", "isEmpty", "first", "last", "sorted",
               "contains", "filter", "compactMap", "enumerated", "keys", "values", "session", "project", "timeline", "engine",
               "player", "state", "dump", "make", "self", "some", "none", "init", "minX", "minY", "maxX", "maxY", "width",
               "height", "frame", "string", "text", "name", "kind", "index", "track", "start", "duration", "end", "selection",
               "tracks", "clips", "media", "asset", "assets", "mediaID", "content", "playhead", "transport", "isPlaying"}
REACH_DEPTH = 3
HUB_IDS = re.compile(r'^(panel\.\w+|timeline|dialog\.(ok|close|cancel))$')   # containers every screen has
USE_CONTEXT_MAX = 40
DEAD_FILE_LITERALS = True  # a changed declaration without test hook: the file's test IDs first, the directory rule if none      # lines of a user's code around a use that may link it to scripts (beyond: climb further)
HUB_SCRIPTS = 12          # a string used by more than max(this, 10 %) of the scripts (panel IDs, undo.name) is no test hook
REACH_MAX_FILES = 12


def hub_limit(scripts):
    """Specificity rule: a link (script string, ID prefix, bridged dump key) shared by more scripts than this says nothing
    about which feature a change touches (`undo.name`, `*.count`, every `asset.tile.*` click), so it selects nothing by
    itself; the scripts it would pull are reached through specific links, or the fallback rules."""
    return max(HUB_SCRIPTS, len(scripts) // 10)


class Block:
    __slots__ = ("start", "end", "kind", "name", "indent", "parent", "local")

    def __init__(self, start, end, kind, name, ind):
        self.start, self.end, self.kind, self.name, self.indent = start, end, kind, name, ind
        self.parent, self.local = None, False


class SwiftFile:
    def __init__(self, path, text):
        self.path, self.text = path, text or ""
        self.lines = self.text.split("\n")
        self.blocks = []
        lines = self.lines
        n = len(lines)
        for i, l in enumerate(lines):
            m = DECL_RE.match(l)
            if not m or (m.group(2) in ("let", "var") and not m.group(3)):
                continue
            ind = len(m.group(1))
            end = i
            j = i + 1
            while j < n:
                lj = lines[j]
                if not lj.strip():
                    j += 1; continue
                ij = indent(lj)
                if ij > ind:
                    end = j
                elif ij == ind and lj.strip()[0] in "}])":
                    end = j; break
                else:
                    break
                j += 1
            self.blocks.append(Block(i + 1, end + 1, m.group(2), m.group(3) or "", ind))
        # parents / locals (a let/var inside a func/init/accessor is local: its lines belong to the function)
        stack = []
        for b in self.blocks:
            while stack and not (stack[-1].start <= b.start <= stack[-1].end and b.indent > stack[-1].indent):
                stack.pop()
            b.parent = stack[-1] if stack else None
            p = b.parent
            b.local = p is not None and p.kind not in TYPE_KINDS and b.kind in ("let", "var")
            stack.append(b)
        self.members = [b for b in self.blocks if not b.local]

    def block_at(self, ln):
        """The type member (func / var / init … directly in a type, or top-level) containing line `ln`; a type header line
        or a line directly in a type → that type; nested functions / closures count as their enclosing member."""
        best = None
        for b in self.members:
            if b.start <= ln <= b.end and (best is None or b.start >= best.start):
                best = b
        while best is not None and best.parent is not None and best.parent.kind not in TYPE_KINDS:
            best = best.parent
        return best

    def literals(self, b):
        lo, hi = (b.start, b.end) if b else (1, len(self.lines))
        return dotted_literals("\n".join(self.lines[lo - 1:hi]))

    def follow_names(self, b):
        """Names to look up for users of block `b`, best first: its own, then its enclosing types' (for `body` & other
        generic members, or when a name is used too widely)."""
        out, cur = [], b
        while cur is not None:
            # a member of a (non-extension) type is only looked up in files that also name that type
            owner = cur.parent
            scope = owner.name if owner is not None and owner.kind in TYPE_KINDS - {"extension"} and owner.name else None
            # short names (`nav`) only with that scope: following the whole type instead reached its every user
            if (cur.name and cur.name not in GENERIC_NAMES and (len(cur.name) >= 4 or (scope and len(cur.name) >= 3))
                    and not (cur.kind == "extension")):
                out.append((cur.name, scope))
            cur = cur.parent
        return out


def strip_comments(text):
    """Swift text without `//` comments (strings are kept: `"a//b"` stays)."""
    out = []
    for l in text.split("\n"):
        if "//" in l:
            q, i = False, 0
            while i < len(l):
                c = l[i]
                if c == "\\":
                    i += 2; continue
                if c == '"':
                    q = not q
                elif not q and l.startswith("//", i):
                    l = l[:i]; break
                i += 1
        out.append(l)
    return "\n".join(out)


PLAIN_ID = re.compile(r'(?:testID|accessibilityIdentifier|setAccessibilityIdentifier)\(?\s*:?\s*"([A-Za-z][A-Za-z0-9_]{2,})"')


def dotted_literals(text):
    """Dotted string literals ("asset.search", "inspector.tab.\\(" as a prefix) + plain test IDs (`.testID("settings")`)."""
    code = strip_comments(text)
    lits = {(m.group(1), False) for m in PLAIN_ID.finditer(code)}
    for m in LITERAL.finditer(code):
        s = m.group(1)
        prefix = s.endswith("\\(")
        s = s[:-2] if prefix else s
        if len(s) < 5 or s.endswith(".swift") or s.count(".") == 0:
            continue
        lits.add((s, prefix))
    return lits


_INDEX = {}


def _string_index(scripts):
    """{string or dotted prefix (≥ 2 parts) of a script string: [(script, string)]} — "transition.duration" also matches
    the derived IDs "transition.duration.field" / ".value"…"""
    key = id(scripts)
    if key not in _INDEX:
        idx, freq, hubs = {}, {}, set()
        for sc in scripts.values():
            for t in sc.strings:
                freq[t] = freq.get(t, 0) + 1
        for n in sorted(scripts):
            for t in sorted(scripts[n].strings):
                # "panel.inspector", "undo.name": used everywhere, they link a change to no feature (measured: matching
                # them even in the changed code itself doubles the selection; scripts using only them are reached
                # through the state-dump bridge or the fallback rules)
                if freq[t] > hub_limit(scripts) or HUB_IDS.match(t):
                    hubs.add(t)
                    continue
                parts = t.split(".")
                for k in [".".join(parts[:k]) for k in range(len(parts), 1, -1)] or [t]:
                    idx.setdefault(k, []).append((n, t))
        _INDEX.clear()
        _INDEX[key] = (scripts, idx, hubs)
    return _INDEX[key][1], _INDEX[key][2]


_PREFIX_USERS = {}


def match_literals(scripts, lits):
    """{script: (string it uses, matching (literal, is_prefix))}."""
    idx, hubs = _string_index(scripts)
    out = {}
    for lit, pre in sorted(lits):
        if not pre:
            for n, t in idx.get(lit, ()):
                out.setdefault(n, (t, (lit, False)))
    prefixes = sorted(l for l, p in lits if p)
    if prefixes:
        # an interpolated-ID prefix every tile / row of the app shares ("asset.tile.") is not specific (hub_limit)
        limit = hub_limit(scripts)
        if _PREFIX_USERS.get("scripts") is not scripts:
            _PREFIX_USERS.clear(); _PREFIX_USERS["scripts"] = scripts
        def users(p):
            if p not in _PREFIX_USERS:
                _PREFIX_USERS[p] = sum(1 for sc in scripts.values() if any(t.startswith(p) and t not in hubs for t in sc.strings))
            return _PREFIX_USERS[p]
        prefixes = [p for p in prefixes if users(p) <= limit]
        for n in sorted(scripts):
            if n in out:
                continue
            hit = next(((t, (p, True)) for t in sorted(scripts[n].strings) for p in prefixes if t.startswith(p) and t not in hubs), None)
            if hit:
                out[n] = hit
    return out


class Reach:
    """Literal reach from changed lines (cached per source)."""
    def __init__(self, src):
        self.src = src
        self.files = {}
        self.users = {}

    def file(self, path, old=False):
        key = (path, old)
        if key not in self.files:
            self.files[key] = SwiftFile(path, self.src.read_old(path) if old else self.src.read_new(path))
        return self.files[key]

    def users_of(self, name, scope=None, home=None):
        """Files using `name` (and naming `scope`, the member's type, if given; `home` = the declaring file always counts);
        None when more than REACH_MAX_FILES (too generic to follow)."""
        key = (name, scope, home)
        if key not in self.users:
            fs = set(self._grep(name))
            if scope:
                fs &= set(self._grep(scope)) | {home}
            fs = sorted(fs)
            self.users[key] = fs if len(fs) <= REACH_MAX_FILES else None
        return self.users[key]

    def bridge(self):
        """State-dump bridge {identifier: {dump keys}}: in the state-dump code (StateDump.swift and the `…dump…` members
        it calls), the member names read by the line writing a key, e.g. `ui["editingGuide"] = store.playerUI.editingGuide
        != nil` → editingGuide → "editingGuide". Only identifiers used in at most REACH_MAX_FILES files are kept."""
        if hasattr(self, "_bridge"):
            return self._bridge
        raw = {}
        files = set(self.src.grep_new("Dump", "app/Sources")) | set(self.src.grep_word("dump", "app/Sources"))
        for path in sorted(files):
            f = self.file(path)
            whole = path.endswith("StateDump.swift")
            for b in f.members:
                if not whole and not re.search(r'(?i)dump', b.name or ""):
                    continue
                for l in f.lines[b.start - 1:b.end]:
                    code = strip_comments(l)
                    marks = [(m.start(), m.group(1) or m.group(2)) for m in DUMP_KEY.finditer(code)]
                    if not marks:
                        continue
                    blank = re.sub(r'"(?:[^"\\]|\\.)*"', lambda q: '"' + " " * (len(q.group(0)) - 2) + '"', code)
                    for m in re.finditer(r'(?<![A-Za-z0-9_"])([a-z][A-Za-z0-9_]{3,})\b', blank):
                        if m.group(1) in SWIFT_WORDS:
                            continue
                        ident = m.group(1)
                        if ident in BRIDGE_STOP:
                            continue
                        # the key named like the identifier, else the last key written before it on the line
                        before = [k for pos, k in marks if pos < m.start()]
                        named = [k for _, k in marks if k == ident]
                        raw.setdefault(ident, set()).add(named[0] if named else before[-1] if before else marks[0][1])
        self._bridge = {i: k for i, k in raw.items() if self.users_of(i) is not None}
        return self._bridge

    def id_prefixes(self):
        """Interpolated ID prefixes used anywhere in app/Sources ("inspector.tab." from "inspector.tab.\\(tab.id)")."""
        if not hasattr(self, "_prefixes"):
            pre = set()
            for path in self.src.swift_files("app/Sources"):
                for m in re.finditer(r'"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.)\\\(', self.src.read_new(path) or ""):
                    if m.group(1).count(".") >= 2 or len(m.group(1)) >= 8:
                        pre.add(m.group(1))
            self._prefixes = sorted(pre)
        return self._prefixes

    def literals(self, text, narrow=False):
        """Dotted literals of `text` + the composite IDs its plain literals form with the interpolated ID prefixes
        (`narrow`: a small context around a use, e.g. one registry entry, where even short plain literals like "out" count;
        otherwise only distinctive ones like "audioBasic")."""
        lits = dotted_literals(text)
        plain = {l for l in re.findall(r'"([A-Za-z][A-Za-z0-9_]{1,}(?:\.[A-Za-z0-9_]+)*)"', strip_comments(text))
                 if (narrow and len(l) >= 2) or re.search(r'[A-Z0-9]', l[1:]) or len(l) >= 12}
        if plain:
            for p in self.id_prefixes():
                for l in plain:
                    lits.add((p + l, False))
        return lits

    def _grep(self, word):
        k = ("grep", word)
        if k not in self.users:
            self.users[k] = self.src.grep_word(word, "app/Sources")
        return self.users[k]

    @staticmethod
    def contexts(f, ln, block):
        """Line ranges around a use at line `ln`, narrowest first: the enclosing bracket groups (by indentation) up to the
        whole member block — e.g. the one `InspectorTab(id: "transition", …)` entry of a registry, not the registry."""
        lines = f.lines
        lo_lim = block.start if block else 1
        hi_lim = block.end if block else len(lines)
        out, cur = [(ln, ln)], ln
        while True:
            ind = indent(lines[cur - 1])
            o = cur - 1
            while o >= lo_lim and (not lines[o - 1].strip() or indent(lines[o - 1]) >= ind):
                o -= 1
            if o < lo_lim:
                break
            oi = indent(lines[o - 1])
            e = o
            while e + 1 <= hi_lim:
                l = lines[e]
                if not l.strip() or indent(l) > oi:
                    e += 1; continue
                if indent(l) == oi and l.strip()[0] in "}])":
                    e += 1
                break
            out.append((o, e))
            cur = o
            if o <= lo_lim:
                break
        out.append((lo_lim, hi_lim))
        return out

    def from_lines(self, seeds, scripts):
        """seeds: [(SwiftFile, [line numbers])] → ({script: (string used, literal)}, {literal: how}, changed blocks from
        which no test hook was reached).

        Each changed member block (its whole text) is checked for literals used by scripts; a block without one is
        followed to its users (narrowest context around each use first), REACH_DEPTH levels at most: the nearest test hook
        on every path wins."""
        hits, how_of, skipped, hit_origins, origins = {}, {}, set(), set(), []
        frontier, seen, owner, links = [], set(), {}, []
        for f, lns in seeds:
            for ln in lns:
                b = f.block_at(ln)
                k = (f.path, b.start if b else 0)
                if k not in seen:
                    seen.add(k)
                    owner[k] = f"{os.path.basename(f.path)}:{b.name if b else 'top level'}"
                    rng = [(b.start, b.end)] if b else [(1, len(f.lines))]
                    label = f"{os.path.basename(f.path)}:{b.name if b else 'top level'}"
                    origins.append(label)
                    frontier.append((f, b, rng, label, label, False))
        # A type's header line (`extension X {`, `struct X: View {`) or a one-line stored property (`let store: S`)
        # changed together with other members of that type does nothing by itself: it is covered by those members' hooks
        # (measured: a new file's headers / `let store` reached no hook and pulled the whole directory fallback rule).
        for f, lns in seeds:
            for ln in lns:
                b = f.block_at(ln)
                if b is None:
                    continue
                if b.kind in TYPE_KINDS and ln == b.start:
                    typ = b
                elif b.kind in ("let", "var") and b.start == b.end and b.parent is not None and b.parent.kind in TYPE_KINDS:
                    typ = b.parent
                else:
                    continue
                for ln2 in lns:
                    b2 = f.block_at(ln2)
                    if (b2 is not None and b2 is not b and typ.start < ln2 <= typ.end and b2.kind not in TYPE_KINDS
                            and b2.end > b2.start):
                        links.append((f"{os.path.basename(f.path)}:{b.name}", f"{os.path.basename(f.path)}:{b2.name}"))
                        break
        for depth in range(REACH_DEPTH + 2):
            nxt = []
            for f, b, ranges, how, origin, render in frontier:
                found = None
                if depth > 0 and f.path.startswith(TESTING):
                    # reached the UI test support itself: the scripts using that driver step / dump key
                    fname, ln = f.path[len(TESTING):], ranges[0][0]
                    if fname in ("UITestDriver.swift", "SyntheticEvents.swift"):
                        pred, what = driver_hunk_preds(fname, f.lines, ln)
                        users = [n for n in sorted(scripts) if pred is not ALL and pred(scripts[n])]
                        # a specific step (drop, scroll …) is a test hook; one most scripts use (click, snapshot) is not
                        if users and len(users) <= len(scripts) // 5:
                            found = {n: (what, (f"driver {what}", False)) for n in users}
                    elif fname == "StateDump.swift":
                        keys = statedump_keys(f.lines, ln)
                        found = {n: (f"dump key {k}", (f"dump {k}", False)) for k in sorted(keys) for n in sorted(scripts)
                                 if k in scripts[n].segments}
                    if found:
                        hit_origins.add(origin)
                        for n, (used, lit) in found.items():
                            hits.setdefault(n, (used, lit))
                            how_of.setdefault(lit, how)
                    continue                                  # never climb out of the test support
                for lo, hi in ranges:
                    if depth > 0 and hi - lo > USE_CONTEXT_MAX and (lo, hi) != ranges[-1]:
                        continue            # a hub (the editor layout, a registry): only the code right around the use
                    if depth > 0 and hi - lo > USE_CONTEXT_MAX and b is not None and b.end - b.start > USE_CONTEXT_MAX:
                        continue
                    small = hi - lo < 12
                    # render level: scripts with a baseline of that part of the screen (any baseline near the use, a
                    # full-window baseline anywhere in the user)
                    pool = scripts if not render else {n: sc for n, sc in scripts.items()
                                                       if sc.baselines and (small or sc.window_baseline)}
                    found = match_literals(pool, self.literals("\n".join(f.lines[lo - 1:hi]), narrow=depth > 0 and small))
                    if found:
                        break
                if render:
                    # the container a baseline snapshot crops to (`"element": "id:settings"`) is set on this user
                    lo, hi = ranges[-1]
                    ids = {l for l, p in dotted_literals("\n".join(f.lines[lo - 1:hi])) if not p}
                    found = dict(found or {})
                    for n, sc in sorted(scripts.items()):
                        for el in sorted(sc.baseline_elements & ids)[:1]:
                            found.setdefault(n, (el, (el, False)))
                if found:
                    hit_origins.add(origin)
                    for n, (used, lit) in found.items():
                        hits.setdefault(n, (used, lit if not render else (lit[0] + " (renders)", lit[1])))
                        how_of.setdefault(lit if not render else (lit[0] + " (renders)", lit[1]), how)
                    if render:
                        continue
                    # nearest test hook found on this path; one more level up only for scripts with a baseline snapshot of
                    # the screen around it (the changed view renders inside its users)
                    render, hit_here = True, True
                else:
                    hit_here = False
                if b is None or (depth >= REACH_DEPTH and not hit_here):
                    continue
                name = users = None
                for cand, scope in f.follow_names(b):
                    users = self.users_of(cand, scope, f.path)
                    if users is not None:
                        name, nscope = cand, scope; break
                    skipped.add(cand)
                if name is None:
                    continue
                pat = re.compile(rf'\b{re.escape(name)}\b')
                # a short member name (`nav`) counts outside its own file only where it is qualified (`Catalog.nav`)
                qual = re.compile(rf'\b{re.escape(nscope)}\s*\.\s*{re.escape(name)}\b') if nscope and len(name) < 4 else None
                for u in users:
                    uf = self.file(u)
                    upat = qual if qual is not None and u != f.path else pat
                    for i, l in enumerate(uf.lines):
                        if not upat.search(l) or l.strip().startswith("//"):
                            continue
                        ub = uf.block_at(i + 1)
                        if ub is not None and ub.name == name and ub.start == i + 1:
                            continue            # the declaration itself
                        k = (u, i + 1)
                        kb = (u, ub.start if ub else 0)
                        if k in seen or kb in seen:
                            if kb in owner:
                                links.append((origin, owner[kb]))    # joins another changed block's path
                            continue
                        seen.add(k)
                        nxt.append((uf, ub, self.contexts(uf, i + 1, ub), f"{how} ← {os.path.basename(u)}:{ub.name if ub else 'top level'}",
                                    origin, render))
            frontier = nxt
            if not frontier:
                break
        alive = set(hit_origins)
        for _ in range(len(links) + 1):
            grown = {a for a, b in links if b in alive} | {b for a, b in links if a in alive}
            if grown <= alive:
                break
            alive |= grown
        dead = [o for o in origins if o not in alive]
        return hits, how_of, dead


def select(src, scripts=None, map_text=None):
    scripts = scripts if scripts is not None else load_scripts(src)
    smoke, rules = load_map(src, map_text)
    sel = Selection(scripts)
    sel.add_globs(smoke, "smoke set")
    files = src.changed()
    rendered_cache = {}

    reach = Reach(src)

    def rule_scripts(rel, always_only):
        """Scripts of the ui_map.txt rules matching `rel` ({name: reason}); `always_only`: only `always` rules."""
        out = {}
        for pat, targets, always in rules:
            if always_only and not always:
                continue
            if fnmatch.fnmatch(rel, pat):
                tag = "always rule" if always else "fallback rule"
                for t in targets:
                    if t == "ALL":
                        for n in scripts: out.setdefault(n, f"{rel}: {tag} {pat} → ALL")
                    elif t == "BASELINES":
                        for n, s in scripts.items():
                            if s.baselines: out.setdefault(n, f"{rel}: {tag} {pat} → BASELINES")
                    elif t != "NONE":
                        for n in fnmatch.filter(sorted(scripts), t): out.setdefault(n, f"{rel}: {tag} {pat}")
        return out

    def reach_scripts(seeds):
        """{script: reason} for the literal reach of seed lines."""
        hits, how_of, dead = reach.from_lines(seeds, scripts)
        out = {n: (f"uses {used!r} ← {how_of[lit]}" if not lit[0].startswith(("driver ", "dump ")) else
                   f"{how_of[lit]} ({used})") for n, (used, lit) in hits.items()}
        return out, hits, dead

    for rel in files:
        base = os.path.basename(rel)
        # scripts, fixtures, baselines
        if rel.startswith(UI_DIR + "/") and rel.endswith(".json") and "/fixtures/" not in rel:
            sel.add([base[:-5]], f"changed script {rel}")
            continue
        if rel.startswith(UI_DIR + "/fixtures/"):
            sub = rel[len(UI_DIR) + 1:]
            top = "/".join(sub.split("/")[:2])          # fixtures/<file or package dir>
            sel.add_if(lambda s: top in s.text, f"uses changed fixture {top}")
            continue
        if rel.startswith("app/Tests/Baselines/") and rel.endswith(".png"):
            b = base[:-4]
            sel.add_if(lambda s: b in s.baselines or f'"{b}"' in s.text, f"uses changed baseline {b}")
            continue
        # test support
        if rel.startswith(TESTING) and rel.endswith(".swift"):
            fname = rel[len(TESTING):]
            if fname in ("UITestDriver.swift", "SyntheticEvents.swift"):
                old, new = src.read_old(rel), src.read_new(rel)
                removed, added = changed_lines(old, new)
                olines, nlines = (old or "").split("\n"), (new or "").split("\n")
                done = set()
                for lines, chg in ((olines, removed), (nlines, added)):
                    for ln, text in chg:
                        if is_noise(text):
                            continue
                        pred, what = driver_hunk_preds(fname, lines, ln)
                        if what in done:
                            continue
                        done.add(what)
                        if pred is ALL:
                            sel.add(scripts, f"{fname}: {what} → ALL")
                        else:
                            sel.add_if(pred, f"{fname}: {what}")
                continue
            if fname == "StateDump.swift":
                old, new = src.read_old(rel), src.read_new(rel)
                removed, added = changed_lines(old, new)
                olines, nlines = (old or "").split("\n"), (new or "").split("\n")
                keys, global_change = set(), None
                for lines, chg in ((olines, removed), (nlines, added)):
                    for ln, text in chg:
                        if is_noise(text):
                            continue
                        func = enclosing_decl(lines, ln)
                        if func == "write":
                            global_change = "write()"; continue
                        if func == "easingName":
                            keys.add("keyframeEasings"); continue
                        if func == "kind":
                            keys.add("kind"); continue
                        k = statedump_keys(lines, ln)
                        if not k:
                            global_change = f"line {ln} {text.strip()[:50]!r}"
                        keys |= k
                if global_change:
                    sel.add(scripts, f"StateDump.swift: {global_change} (no dump key) → ALL")
                for k in sorted(keys):
                    sel.add_if(lambda s, k=k: k in s.segments, f"StateDump.swift: dump key {k!r}")
                continue
            pred = TESTING_FILES.get(fname, ALL)
            if pred is ALL:
                sel.add(scripts, f"{fname} → ALL")
            elif pred is not None:
                sel.add_if(pred, f"{fname}")
            continue
        # localization tables
        m = re.match(r'app/Sources/\w+/Resources/(\w+)\.lproj/.*\.(strings|stringsdict)$', rel)
        if m:
            lang = m.group(1)
            old, new = strings_entries(src.read_old(rel)), strings_entries(src.read_new(rel))
            changed = {k for k in set(old) | set(new) if old.get(k) != new.get(k)}
            if m.group(2) == "stringsdict":
                changed = None
            in_lang = lambda s, lang=lang: lang in s.langs
            if changed is None:
                sel.add_if(lambda s: in_lang(s) and bool(s.baselines), f"{rel} (plural table) → {lang} BASELINES")
                continue
            for key in sorted(changed):
                texts = {t for t in (old.get(key), new.get(key)) if t and len(t) >= 3}
                sel.add_if(lambda s, key=key, texts=texts: in_lang(s) and (key in s.strings or bool(texts & s.strings)),
                           f"{lang} l10n {key!r} used literally")
                # who renders it: the Swift files using the key (or an interpolated prefix of it)
                users = rendered_cache.get(key)
                if users is None:
                    users = src.grep_new(f'"{key}"', "app/Sources")
                    if not users:
                        parts = key.split(".")
                        for n in range(len(parts) - 1, 0, -1):
                            pre = ".".join(parts[:n]) + "."
                            users = src.grep_new(f'"{pre}\\(', "app/Sources")
                            if users:
                                break
                    rendered_cache[key] = users
                if not users:
                    sel.add_if(lambda s: in_lang(s) and bool(s.baselines), f"{lang} l10n {key!r} (no Swift user found) → {lang} BASELINES")
                    continue
                seeds = []
                for u in users:
                    f = reach.file(u)
                    lns = [i + 1 for i, l in enumerate(f.lines) if f'"{key}"' in l or any(
                        f'"{".".join(key.split(".")[:n])}.\\(' in l for n in range(1, key.count(".") + 1))]
                    seeds.append((f, lns))
                found, _, _ = reach_scripts(seeds)
                for n, why in found.items():
                    s = scripts[n]
                    if in_lang(s) and (s.baselines or s.uses("a11yAudit") or any(p.startswith(("ui.settings", "ui.anchorFrames"))
                                                                                for p in s.paths)):
                        sel.add([n], f"{lang} l10n {key!r} rendered: {why}")
            continue
        # other files: `always` rules; Swift sources: the literal reach of the changed lines, else the fallback rules
        for n, why in rule_scripts(rel, always_only=True).items():
            sel.add([n], why)
        if rel.endswith(".swift") and rel.startswith("app/Sources/"):
            old, new = src.read_old(rel), src.read_new(rel)
            removed, added = changed_lines(old, new)
            seeds = []
            rl = [ln for ln, t in removed if not is_noise(t)]
            al = [ln for ln, t in added if not is_noise(t)]
            if rl:
                seeds.append((reach.file(rel, old=True), rl))
            if al:
                seeds.append((reach.file(rel), al))
            if not seeds:
                continue                                   # comments / blank lines only
            found, _, dead = reach_scripts(seeds)
            for n, why in found.items():
                sel.add([n], f"{rel}: {why}")
            # state the changed lines touch that the dump exposes (`.editingGuide` → scripts reading ui.editingGuide)
            bridge = reach.bridge()
            idents = set()
            for _, t in removed + added:
                if not is_noise(t):
                    idents |= set(re.findall(r'\b([a-z][A-Za-z0-9_]{3,})\b', strip_comments(t)))
            for ident in sorted(idents & set(bridge)):
                for k in sorted(bridge[ident]):
                    readers = [n for n, sc in scripts.items() if k in sc.segments]
                    if len(readers) > hub_limit(scripts):
                        continue           # `undoNameKey` → "name" (undo.name, 83 scripts): not specific (hub_limit)
                    sel.add(readers, f"{rel}: changes `{ident}`, dumped as {k!r}")
            if dead:
                # some changed declaration reaches no test hook: the coarse directory rule covers it (measured: the
                # file's own test IDs instead would miss scripts, e.g. c4_caption_list for EditorStore+Fillers.swift)
                for n, why in rule_scripts(rel, always_only=False).items():
                    sel.add([n], f"{why} (no test ID / l10n key reached from {', '.join(dead[:2])})")
            continue
        for n, why in rule_scripts(rel, always_only=False).items():
            sel.add([n], why)
    return sel, files


def main(argv):
    base, explain, files, commit = "auto", False, None, None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--base":
            base = argv[i + 1]; i += 2; continue
        if a == "--commit":
            commit = argv[i + 1]; i += 2; continue
        if a == "--explain":
            explain = True; i += 1; continue
        if a == "--files":
            files = argv[i + 1:]; break
        print(__doc__, file=sys.stderr); return 2
    src = Commit(commit) if commit else WorkTree(base, files)
    sel, changed = select(src)
    for n in sorted(sel.why):
        print(f"{UI_DIR}/{n}.json")
    if explain:
        if isinstance(src, WorkTree) and files is None:
            print(f"diff base: {src.note}", file=sys.stderr)
        for n in sorted(sel.why):
            reasons = list(dict.fromkeys(sel.why[n]))
            more = f"  (+{len(reasons) - 2} more)" if len(reasons) > 2 else ""
            print(f"  {n:34s} {reasons[0]}", file=sys.stderr)
            for r in reasons[1:2]:
                print(f"  {'':34s} {r}{more}", file=sys.stderr)
        print(f"{len(sel.why)} of {len(sel.scripts)} UI scripts selected for {len(changed)} changed file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
