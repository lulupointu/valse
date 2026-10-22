#!/usr/bin/env python3
"""Unit tests of scripts/ui_select.py (stage-1 UI script selection). Run by scripts/test.sh; alone:
    python3 scripts/test_ui_select.py [-v]
Synthetic cases pin each mechanism; the repo checks fail when the selector's knowledge of the driver / map rots (a
renamed driver function, a new step action, a map glob matching nothing); history cases replay real fixes."""
import os
import re
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ui_select as U  # noqa: E402

ROOT = U.ROOT


class Mem(U.Source):
    """In-memory change: `old` / `new` = {path: text}."""
    def __init__(self, old, new, map_text="smoke: \n"):
        self.old, self.new = dict(old), dict(new)
        self.new.setdefault(U.MAP, map_text)
        self.old.setdefault(U.MAP, self.new[U.MAP])

    def changed(self):
        return sorted(p for p in set(self.old) | set(self.new) if self.old.get(p) != self.new.get(p))

    def read_new(self, path): return self.new.get(path)
    def read_old(self, path): return self.old.get(path)

    def list_new(self, prefix):
        return sorted(p for p in self.new if os.path.dirname(p) == prefix)

    def grep_new(self, needle, prefix):
        return sorted(p for p, t in self.new.items() if p.startswith(prefix) and p.endswith(".swift") and needle in t)

    def swift_files(self, prefix):
        return sorted(p for p in self.new if p.startswith(prefix) and p.endswith(".swift"))


def script(steps, **top):
    import json
    return json.dumps(dict(top, steps=steps))


SCRIPTS = {
    "scroller": script([{"scroll": "id:timeline", "dy": 3}, {"expect": {"path": "ui.scrollY", "gt": 0}}], project="demo"),
    "clicker": script([{"click": "id:asset.search"}, {"type": "su"}, {"expect": {"path": "ui.toast", "equals": "Saved"}}]),
    "menu_fr": script([{"menu": "menu.file/menu.export"}, {"snapshot": "x", "baseline": "x-fr"}], lang="fr"),
    "menu_en": script([{"menu": "menu.file/menu.export"}, {"snapshot": "y", "baseline": "y"}]),
    "clips": script([{"click": "clip:main/0"}, {"expect": {"path": "selectedClips.0.volume", "equals": 1}}], project="demo"),
    "durations": script([{"click": "id:transition.duration.field"}, {"expect": {"path": "main.clips.0.transition", "equals": "x"}}]),
}


def mem_scripts(extra_old=None, extra_new=None, map_text="smoke: \n"):
    base = {f"{U.UI_DIR}/{n}.json": t for n, t in SCRIPTS.items()}
    old = dict(base, **(extra_old or {}))
    new = dict(base, **(extra_new or {}))
    return Mem(old, new, map_text)


def selected(src):
    sel, _ = U.select(src)
    return sel


DRIVER = U.TESTING + "UITestDriver.swift"
DRIVER_SRC = '''public final class UITestDriver {
    public func run() async -> Int32 {
        let x = 1
        return 0
    }

    private func perform(_ step: [String: Any], index: Int) async throws {
        let settle = 0.25
        if let t = step["click"] ?? step["doubleClick"] ?? step["rightClick"] {
            click(t)
        } else if let t = step["scroll"] {
            let dy = 1
            deliverScroll(t, dy)
        } else if let k = step["key"] as? String {
            key(k)
        }
    }

    private func deliverScroll(_ t: Any, _ dy: Int) {
        post(t, dy)
    }
}
'''


class SyntheticTests(unittest.TestCase):
    def test_script_features(self):
        s = U.Script("s", SCRIPTS["clips"])
        self.assertIn("click", s.actions)
        self.assertEqual(s.targets, {"clip"})
        self.assertIn("volume", s.segments)
        self.assertEqual(s.project, "demo")
        fr = U.Script("f", SCRIPTS["menu_fr"])
        self.assertEqual(fr.langs, {"fr"})
        self.assertEqual(fr.baselines, {"x-fr"})
        self.assertIn("menu.export", fr.menus)

    def test_changed_script_selects_itself_only(self):
        src = mem_scripts(extra_new={f"{U.UI_DIR}/scroller.json": SCRIPTS["scroller"] + "\n"})
        self.assertEqual(set(selected(src).why), {"scroller"})

    def test_driver_perform_branch_selects_its_action_only(self):
        new = DRIVER_SRC.replace("let dy = 1", "let dy = 2")
        sel = selected(mem_scripts({DRIVER: DRIVER_SRC}, {DRIVER: new}))
        self.assertEqual(set(sel.why), {"scroller"})
        self.assertIn("perform ▸ scroll", sel.why["scroller"][0])

    def test_driver_helper_maps_to_its_users(self):
        new = DRIVER_SRC.replace("post(t, dy)", "post(t, dy * 2)")
        self.assertEqual(set(selected(mem_scripts({DRIVER: DRIVER_SRC}, {DRIVER: new})).why), {"scroller"})

    def test_driver_core_selects_all(self):
        new = DRIVER_SRC.replace("let x = 1", "let x = 2")
        sel = selected(mem_scripts({DRIVER: DRIVER_SRC}, {DRIVER: new}))
        self.assertEqual(set(sel.why), set(SCRIPTS))
        self.assertTrue(all("→ ALL" in r[0] for r in sel.why.values()))

    def test_driver_comment_only_selects_nothing(self):
        new = DRIVER_SRC.replace("let dy = 1", "let dy = 1  // note").replace("        post(t, dy)", "        // why\n        post(t, dy)")
        self.assertEqual(set(selected(mem_scripts({DRIVER: DRIVER_SRC}, {DRIVER: new})).why), {"scroller"})  # trailing comment = changed line

    def test_statedump_key_selects_readers(self):
        path = U.TESTING + "StateDump.swift"
        old = '''public enum StateDump {
    public static func make(_ store: EditorStore) -> [String: Any] {
        var ui: [String: Any] = [:]
        if let t = store.toast { ui["toast"] = t.message }
        let vol = store.volume
        ui["scrollY"] = 0
        var d: [String: Any] = ["ui": ui]
        d["volume"] = vol
        return d
    }
}
'''
        sel = selected(mem_scripts({path: old}, {path: old.replace("t.message", "t.text")}))
        self.assertEqual(set(sel.why), {"clicker"})
        # a changed `let` feeds the keys of the lines using it
        sel = selected(mem_scripts({path: old}, {path: old.replace("store.volume", "store.gain")}))
        self.assertEqual(set(sel.why), {"clips"})

    def test_strings_change_selects_language_scripts(self):
        en, fr = "app/Sources/MontageUI/Resources/en.lproj/Home.strings", "app/Sources/MontageUI/Resources/fr.lproj/Home.strings"
        old = {en: '"menu.export" = "Export…";\n"other.key" = "Other";\n', fr: '"menu.export" = "Exporter…";\n'}
        sel = selected(mem_scripts(old, {en: old[en], fr: '"menu.export" = "Exporter";\n'}))
        self.assertEqual(set(sel.why), {"menu_fr"})
        sel = selected(mem_scripts(old, {en: old[en].replace("Export…", "Export"), fr: old[fr]}))
        self.assertEqual(set(sel.why), {"menu_en"})
        # an English text asserted literally (toast "Saved") selects the script asserting it; the key has no Swift user
        # here, so the English baseline scripts are selected too (safe fallback)
        old2 = {en: '"toast.saved" = "Saved";\n'}
        sel = selected(mem_scripts(old2, {en: '"toast.saved" = "Saved!";\n'}))
        self.assertEqual(set(sel.why), {"clicker", "menu_en"})
        self.assertIn("used literally", sel.why["clicker"][0])

    def test_rendered_key_selects_baseline_scripts_of_the_view(self):
        en = "app/Sources/MontageUI/Resources/en.lproj/X.strings"
        view = "app/Sources/MontageUI/Home/ExportMenu.swift"
        src = 'struct ExportMenu: View {\n    var body: some View {\n        Text(tr("export.title"))\n        Button("menu.export") {}\n    }\n}\n'
        sel = selected(mem_scripts({en: '"export.title" = "A";\n', view: src}, {en: '"export.title" = "B";\n', view: src}))
        self.assertEqual(set(sel.why), {"menu_en"})

    def test_swift_reach_direct_and_through_users(self):
        view = "app/Sources/MontageUI/AssetPanel/Search.swift"
        helper = "app/Sources/MontageUI/AssetPanel/SearchModel.swift"
        v = 'struct SearchBox: View {\n    var body: some View {\n        TextField("", text: $t)\n            .testID("asset.search")\n        let q = SearchModel.debounced(t)\n    }\n}\n'
        h = 'enum SearchModel {\n    static func debounced(_ s: String) -> String {\n        return s\n    }\n}\n'
        # direct: the changed view uses the test ID
        sel = selected(mem_scripts({view: v, helper: h}, {view: v.replace('text: $t', 'text: $u'), helper: h}))
        self.assertEqual(set(sel.why), {"clicker"})
        # through a user: the helper has no test ID, the view calling it does
        sel = selected(mem_scripts({view: v, helper: h}, {view: v, helper: h.replace("return s", "return s + \"\"")}))
        self.assertEqual(set(sel.why), {"clicker"})
        self.assertIn("SearchModel.swift:debounced ← Search.swift:body", sel.why["clicker"][0])

    def test_derived_test_ids_match_their_base(self):
        f = "app/Sources/MontageUI/Inspector/T.swift"
        a = 'struct T: View {\n    var body: some View {\n        SliderRow(value: v, testID: "transition.duration")\n    }\n}\n'
        sel = selected(mem_scripts({f: a}, {f: a.replace("value: v", "value: w")}))
        self.assertEqual(set(sel.why), {"durations"})

    def test_no_test_hook_falls_back_to_the_directory_rule(self):
        f = "app/Sources/MontageEngine/Audio/Mixer.swift"
        a = 'enum Mixer {\n    static func gainCurveForTests(_ x: Double) -> Double {\n        return x\n    }\n}\n'
        m = "smoke: \napp/Sources/MontageEngine/Audio/*  clips\n"
        sel = selected(mem_scripts({f: a}, {f: a.replace("return x", "return x * 2")}, map_text=m))
        self.assertEqual(set(sel.why), {"clips"})
        self.assertIn("fallback rule", sel.why["clips"][0])

    def test_specificity_rule_prefix(self):
        # an interpolated-ID prefix shared by more than hub_limit scripts ("asset.tile.") links a change to no feature
        view = "app/Sources/MontageUI/AssetPanel/Tiles.swift"
        v = 'struct Tiles: View {\n    var body: some View {\n        Tile(x).testID("asset.tile.\\(x.id)")\n    }\n}\n'
        def tiles(n):
            return {f"{U.UI_DIR}/tile{i}.json": script([{"click": f"id:asset.tile.t{i}"}]) for i in range(n)}
        for n, expect_tiles in ((13, False), (5, True)):
            extra = tiles(n)
            sel = selected(mem_scripts(dict(extra, **{view: v}), dict(extra, **{view: v.replace("Tile(x)", "Tile(y)")})))
            self.assertEqual(any(k.startswith("tile") for k in sel.why), expect_tiles, (n, sorted(sel.why)))

    def test_specificity_rule_bridge(self):
        # a changed identifier the state dump writes as a key read by more than hub_limit scripts (undo.name) selects none
        dump = U.TESTING + "StateDump.swift"
        d = 'public enum StateDump {\n    public static func make(_ s: EditorStore) -> [String: Any] {\n        var u: [String: Any] = [:]\n        u["name"] = s.undoNameKey\n        u["gain"] = s.mixerGain\n        return u\n    }\n}\n'
        f = "app/Sources/MontageCore/Editing/Ops.swift"
        a = 'enum Ops {\n    static func run(_ s: EditorStore) {\n        s.undoNameKey = "a"\n        s.mixerGain = 1\n    }\n}\n'
        readers = {f"{U.UI_DIR}/r{i}.json": script([{"expect": {"path": "undo.name", "equals": "x"}}]) for i in range(13)}
        readers[f"{U.UI_DIR}/g.json"] = script([{"expect": {"path": "ui.gain", "equals": 1}}])
        base = dict(readers, **{dump: d})
        sel = selected(mem_scripts(dict(base, **{f: a}), dict(base, **{f: a.replace('"a"', '"b"')})))
        self.assertFalse(any(k.startswith("r") and k[1:].isdigit() for k in sel.why), sorted(sel.why))
        sel = selected(mem_scripts(dict(base, **{f: a}), dict(base, **{f: a.replace("= 1", "= 2")})))
        self.assertIn("g", sel.why)

    def test_type_header_and_stored_property_are_covered_by_members(self):
        # a new file: its `struct … {` header and `let store` line reach no hook themselves, but the type's other
        # members do, so the directory fallback rule is not pulled in
        f = "app/Sources/MontageUI/AssetPanel/Grid.swift"
        a = 'struct Grid: View {\n    let store: EditorStore\n    var body: some View {\n        Field().testID("asset.search")\n    }\n}\n'
        m = "smoke: \napp/Sources/MontageUI/AssetPanel/*  clips\n"
        sel = selected(mem_scripts({}, {f: a}, map_text=m))
        self.assertEqual(set(sel.why), {"clicker"})
        # a header-only change (new conformance) is still checked against the whole type
        b = a.replace("struct Grid: View {", "struct Grid: View, Equatable {")
        self.assertEqual(set(selected(mem_scripts({f: a}, {f: b}, map_text=m)).why), {"clicker"})
        # …and a lone stored-property change without a hooked member still falls back to the directory rule
        c = 'struct Grid {\n    let store: EditorStore\n    func f() {\n        g()\n    }\n}\n'
        self.assertIn("clips", selected(mem_scripts({f: c}, {f: c.replace("let store: EditorStore", "let store: Store")}, map_text=m)).why)

    def test_always_rule_and_smoke(self):
        f = "app/Sources/MontageApp/main.swift"
        m = "smoke: scroller\nalways app/Sources/MontageApp/*  ALL\n"
        sel = selected(mem_scripts({f: "let a = 1\n"}, {f: "let a = 2\n"}, map_text=m))
        self.assertEqual(set(sel.why), set(SCRIPTS))
        sel = selected(mem_scripts({}, {"docs/X.md": "x"}, map_text=m))
        self.assertEqual(set(sel.why), {"scroller"})


class AutoBaseTests(unittest.TestCase):
    """--base auto: the nearest of main / batch-* (scratch git repo)."""
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.git("init", "-q", "-b", "main")
        self.commit("m1")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *a):
        return subprocess.run(["git", "-C", self.d, "-c", "user.name=t", "-c", "user.email=t@t", *a],
                              capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, msg):
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def test_feature_off_main(self):
        self.git("switch", "-q", "-c", "feat")
        self.commit("f1")
        ref, mb, note = U.auto_base(self.d)
        self.assertEqual(ref, "main")
        self.assertEqual(mb, self.git("rev-parse", "main"))
        self.assertIn("auto", note)

    def test_feature_off_a_batch_branch(self):
        self.git("switch", "-q", "-c", "batch-7")
        b = self.commit("b1")                       # the batch has commits main doesn't
        self.git("switch", "-q", "-c", "feat")
        self.commit("f1")
        self.git("switch", "-q", "main")
        self.commit("m2")                           # main moved on too
        self.git("switch", "-q", "feat")
        ref, mb, _ = U.auto_base(self.d)
        self.assertEqual((ref, mb), ("batch-7", b))

    def test_a_batch_that_already_contains_head_is_not_a_base(self):
        self.git("switch", "-q", "-c", "feat")
        f = self.commit("f1")
        self.git("switch", "-q", "-c", "batch-8", "main")
        self.git("merge", "-q", "--no-ff", "-m", "merge feat", "feat")
        self.git("switch", "-q", "feat")
        ref, mb, _ = U.auto_base(self.d)
        self.assertEqual(ref, "main")
        self.assertNotEqual(mb, f)


def repo_file(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


class RepoTests(unittest.TestCase):
    """The selector's hand-kept knowledge must match the repo (catches rot)."""

    def test_actions_match_the_driver(self):
        src = repo_file(U.TESTING + "UITestDriver.swift")
        m = re.search(r'static let actions = \[(.*?)\]', src, re.S)
        self.assertIsNotNone(m)
        self.assertEqual(re.findall(r'"(\w+)"', m.group(1)), U.ACTIONS, "UITestDriver.actions changed: update ui_select.ACTIONS")

    def test_driver_funcs_exist(self):
        for key in U.DRIVER_FUNCS:
            fname, func = key.split(":")
            src = repo_file(U.TESTING + fname)
            self.assertRegex(src, rf'\b(func|var|let|class|struct)\s+{func}\b', f"{key} no longer exists: update DRIVER_FUNCS")

    def test_testing_files_are_known(self):
        known = set(U.TESTING_FILES) | {"UITestDriver.swift", "SyntheticEvents.swift", "StateDump.swift"}
        for f in os.listdir(os.path.join(ROOT, U.TESTING)):
            if f.endswith(".swift"):
                self.assertIn(f, known, f"new test-support file {f}: add it to ui_select.TESTING_FILES (ALL if unsure)")

    def test_perform_branches_are_attributed(self):
        """Every `step["x"]` branch of perform() is attributed to its step keys (not to ALL)."""
        src = repo_file(U.TESTING + "UITestDriver.swift").split("\n")
        start = next(i for i, l in enumerate(src) if re.match(r'\s*private func perform\(', l))
        branches = 0
        for i in range(start + 1, len(src)):
            l = src[i]
            if re.match(r'^    (private |public )?(static )?func ', l):
                break
            if re.match(r'^\s{8}(\} else )?if\b.*step\["', l) and i + 1 < len(src) and src[i + 1].strip():
                pred, what = U.driver_hunk_preds("UITestDriver.swift", src, i + 2)
                self.assertIsNot(pred, U.ALL, f"line {i + 2}: {what}")
                branches += 1
        self.assertGreater(branches, 15)

    def test_map_globs_match_something(self):
        src = U.WorkTree("HEAD", files=[])
        scripts = U.load_scripts(src)
        smoke, rules = U.load_map(src)
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True).stdout.split("\n")
        import fnmatch
        for g in smoke:
            self.assertTrue(fnmatch.filter(sorted(scripts), g), f"smoke script {g} does not exist")
        for pat, targets, _ in rules:
            self.assertTrue(fnmatch.filter(tracked, pat), f"ui_map.txt rule {pat} matches no file")
            for t in targets:
                if t not in ("ALL", "BASELINES", "NONE"):
                    self.assertTrue(fnmatch.filter(sorted(scripts), t), f"ui_map.txt {pat}: {t} matches no script")


def have(sha):
    return subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode == 0


class CodeOnly(U.Commit):
    def changed(self):
        return [f for f in super().changed() if f.startswith("app/Sources/")]


class HistoryTests(unittest.TestCase):
    """Real fixes on main: the CODE part of the commit must select the script that caught / pins the bug."""
    CASES = [
        ("a31fa89", {"audio_online"}),                         # asset search dropped the last keystrokes (macOS 13)
        ("bbabb61", {"export_dialog", "w5_transition_drop"}),  # export disabled w/o FFmpeg; Softness reset Duration
        ("9790269", {"fin_guides_scopes"}),                    # guide double-click (state-dump bridge: editingGuide)
        ("ba1d11a", {"audio_delete_selected"}),                # audio inspector crash (composite ID inspector.tab.audioBasic)
        ("814f57b", {"w5_animation_fr", "w5_animation_text_sticker"}),  # animation tiles (render level, baselines)
        ("cc44062", {"f3_text_box_resize"}),                   # text box resize handle (bridge: boxWidth)
        ("96954d1", {"f3_drop_empty"}),                        # drop on empty timeline (reaches UITestDriver.drop)
        ("92729b6", {"audio_online_fr"}),                      # Settings tab bar width: baseline of element id:settings
    ]

    def test_cases(self):
        for sha, want in self.CASES:
            if not have(sha):
                continue
            sel, _ = U.select(CodeOnly(sha))
            self.assertTrue(want <= set(sel.why), f"{sha}: missing {sorted(want - set(sel.why))}")


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[sys.argv[0]])
