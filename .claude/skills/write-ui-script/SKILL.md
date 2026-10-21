---
name: write-ui-script
description: Write or fix a Montage UI test script (app/Tests/UIScripts/*.json, run by scripts/uitest.sh) - DSL steps and targets, waitFor on state dump paths instead of sleeps, text-field key routing gotcha, element-scoped snapshots and baselines (incl. macos13 overrides), test IDs and check_fast script selection (ui_select.py). Use when adding UI coverage for a feature, when a UI script is flaky or fails, or when re-recording baselines.
---

# Montage UI scripts (full reference: docs/TESTING.md §1-2; driver: app/Sources/MontageUI/Testing/UITestDriver.swift)

The app runs offscreen, never activated; events are synthetic and in-process. Run one:
`scripts/uitest.sh app/Tests/UIScripts/<name>.json` (`--no-build` after a build, `--timeout <s>`, `--no-retry` to see
the first failure). Output: `build/uitest/<name>/report.json`, `final.json` (state dump), PNGs, `failure.{json,png}`.
`MONTAGE_UITEST_DEBUG=1` logs each event and its hit view. Copy a close example: `split_undo`, `inspector_field`,
`drag_media_to_timeline`, `text_add`, `c6_tooltips`, `audio_online`, `w5_keyframe_ease`, `ai_remove`.

## Skeleton (`//` comments only on their own line: trailing comments break the JSON)
```json
// what it proves (one line)
{
  // project: empty | demo | demo-bin | demo-transcript… | media:N | stress:N[:M] | home[:N[:…]] | fixtures/x.montage
  "project": "demo",
  "lang": "en",
  // optional: SKIPPED (exit 3) when missing; also {"content": true}, {"minOS": 14}
  "requires": {"models": ["coreml.lama-800"]},
  "steps": [
    {"click": "clip:main/1"},
    {"key": "cmd+b"},
    {"waitFor": {"path": "main.clips.count", "equals": 4, "timeout": 10}},
    {"expect": {"path": "undo.name", "equals": "cmd.split"}},
    {"snapshot": "after-split", "element": "id:timeline", "baseline": true}
  ]
}
```

## Steps (actions in `UITestDriver.actions`)
click / doubleClick / rightClick (+`"menuItem": "tlmenu.a/tlmenu.b"` for the timeline context menu) · press (AX press
of `id:`) · drag (`"by": [dx, dy]` or `"to"`, `"at"/"toAt"`, `"steps"`, `"hold": true` + later `{"release": true}`) ·
scroll (`dx`, `dy`, `"modifiers": ["cmd"]` zoom, `"phase"`) · hover · key (`"cmd+b"`, `"space"`, `"shift+left"`,
`"repeat"`) · type (`"replace": true` selects all first) · menu (`"menu.edit/menu.undo"`, l10n keys) · drop
(`{"media": 0}`, `{"effect": id}`, `{"transition": id}`, `{"sticker": id}`, `{"text": styleID}`, `{"files": […]}` + `"on"`)
· dragExit · expect · waitFor · snapshot · dump · a11yAudit · seek / select (setup shortcuts) · perf / metric · log ·
wait / idle. Any step: `"offset": [dx, dy]`, `"modifiers": […]`, `"settle": s` (default 0.25), `"minOS"`/`"maxOS"`/`"ffmpeg"`.
Targets: `id:<testID>` (+`"at": [fx, fy]`), `clip:<track|main>/<i>[:leading|:trailing|:body|:0.25]`, `clip:selected`,
`time:7.5@ruler|@main|@2`, `header:main/lock`, `player:0.5,0.5`, `point:x,y`. `id:` targets are scrolled into view first.
expect / waitFor operators: `equals notEquals approx(+tolerance) gt gte lt lte contains notContains count exists`.
State paths (StateDump.swift): `playhead`, `selection`, `selectedClips.0.opacity`, `main.clips.count`, `tracks.2.clips`,
`undo.{name,depth}`, `media.count`, `ui.{inspectorTab, toast, anchors, export.dialog.canExport, activeJobs, models.<id>}`,
`app.{screen, modal, …}`. Use `{"dump": "x"}` then Read `build/uitest/<name>/x.json` to discover paths; `ui.anchors`
lists the test IDs on screen.

## Load-robust by construction (the machine is never quiet; 10+ heavy runs overlap)
- NEVER rely on time: no `{"wait": s}` to let async work finish, no tight timeouts. Wait on the state that proves it:
  `{"waitFor": {"path": "media.count", "equals": 2, "timeout": 20}}`; AI / background jobs:
  `{"waitFor": {"path": "ui.activeJobs", "equals": 0, "timeout": 600}}`. A waitFor `timeout` is a NO-PROGRESS bound: it
  restarts whenever a progress signal changes (`ui.jobs` progress/state, `ui.activeJobs`, `ui.audioStage.progress`,
  `ui.export.jobs`, `ui.models.progress`, the waited value; add your own with `"progress": ["path"]`), so a long job a
  loaded machine slows down is waited for and only a stuck one fails. Give it 3-5x the longest gap between progress
  updates alone. Long work should report progress (a job's progress, or a dump key that moves) so its wait can tell slow
  from stuck. Real-model scripts (`requires.models`, or `"heavy": true`) run one at a time under `uitest.sh --jobs`.
- Debounced inputs (search fields): after `type`, `waitFor` the committed query / result count, not a fixed delay
  (audio_online regression: last keystrokes dropped on macOS 13).
- Before a `snapshot`, `waitFor` whatever paints it (thumbnails, results, the selected tab) so pixels are final.
- Every `expect` right after an async action should be a `waitFor` instead.
- The driver already helps (docs/TESTING.md §1 "Load-independent waits"): after each input step it waits for the UI to
  be quiescent (≤ 10 s; also renders the window, since SwiftUI hit-tests what it last drew); `expect` is re-checked
  every 50 ms until it holds (≤ 10 s); `waitFor` timeouts are floored at 30 s (no-progress bounds, above); click/drag/hover targets are awaited
  (≤ 10 s); animations are off. Assert end states; `exists: false` only for already-true facts.
- `"now": true` on an expect = check once, immediately (only when immediacy IS the point: "hidden at once"). An expect
  right after a `"settle": 0` step (e.g. a hover checking `ui.tooltipPending`) is `now` by default, without retry.
- report.json records each expect's `waitMs` and `expect_wait_ms_max`; uitest.sh prints `⚠ slow expect` when one waited
  > 2 s although the UI had settled = a latency regression (the app reacts late), fix it rather than ignore it.
- Snapshots: re-rendered until two consecutive renders are identical AND (with a baseline) it matches the baseline,
  ≤ 30 s (a hang bound, `MONTAGE_UITEST_SNAPSHOT_LIMIT`); a real difference fails with the last diff, and so does a
  view that never renders the same twice (something keeps animating / reloading).
- `id:` clicks are delivered exactly (SwiftUI `.testID` and AppKit `setAccessibilityIdentifier` targets alike): when
  the press is dispatched the window is laid out and drawn and the element located again, and the click goes where it
  is THEN (`click_retargets` when it had moved since resolution); an element not on screen at that moment gets nothing
  and is clicked again once it is (`click_redeliveries`, ≤ 3 attempts); a dispatched press is never repeated; an
  element rebuilt between press and release counts in `click_release_anomalies`. uitest.sh prints `⚠ click warning`
  for all three: not gating, but the target moved / was rebuilt under the click. `offset` clicks are sent as written.
  Driver self-test: `MONTAGE_UITEST_INJECT_CLICK_SKEW=0,40` / `MONTAGE_UITEST_INJECT_CLICK_VANISH=1` (scripts must pass).
- `waitFor` reads the same state as `expect` (`project.*` paths included).
- Transition / effect thumbnails render asynchronously: before a snapshot of the transitions tab
  `{"waitFor": {"path": "ui.transitionThumbsMissing", "equals": 0}}` (on-screen tiles whose still is not rendered yet).
- Flaky = bug in the test or the app: fix the wait; never "fix" by adding `wait` or raising the tolerance blindly.

## Gotcha: keys while a text field is editing
While the first responder is a text field (`NSText` field editor), the driver delivers key events (without ⌘) straight
to the window, bypassing the app's key monitor and shortcuts (SyntheticEvents.installKeyRouting). So after a `type` /
click into a field, `{"key": "space"}` or `delete` edits the text instead of playing / deleting a clip. End editing first
(click a neutral area such as `id:timeline`, or Return if the field commits on Return) before shortcut keys. Fields
that must react to ↑ / ↓ / Return / Esc should handle them in the field (`control(_:textView:doCommandBy:)`, see
`SwitcherSearchField`), not only in the app monitor. ⌘-shortcuts still take the normal path.

## Snapshots and baselines
- Scope to the component: `"element": "id:panel.inspector"` (or a smaller testID). Full-window baselines break on any
  unrelated UI change (settings-performance.png was re-recorded 9x, editor-fr.png 7x): avoid them in new scripts.
- Volatile pixels (dates, sizes, clocks, media frames): `"mask": ["id:x"]`; regions with video/thumbnails/fonts:
  `"threshold": 32-48, "tolerance": 0.01-0.03`; pure chrome keeps defaults (threshold 16, tolerance 0.005).
- First run creates `app/Tests/Baselines/<name>.png` ("baseline created — LOOK at it and commit it"). Intentional change:
  `scripts/uitest.sh --update-baselines app/Tests/UIScripts/<script>.json`, Read the new PNG, commit it.
- `app/Tests/Baselines/macos13/<name>.png` overrides on macOS 13 only (1x text, native control looks). Only for
  rendering-only differences recorded in the macOS 13 VM; never for layout bugs or behaviour (use `minOS`/`maxOS` steps).
  If you change a component that has a macos13 override, say so in your report (it must be re-recorded in the VM).

## Test IDs and selection
- Add IDs to what you build: SwiftUI `.testID("area.thing")`, AppKit `setAccessibilityIdentifier`. Never localized text.
- Not reachable: real NSMenu popups (SwiftUI `Menu`/`Picker`: use the `menu` step or a setup step), NSOpen/SavePanel,
  lazy grid tiles far down (scroll first). SwiftUI accessibility is audited with `{"a11yAudit": "name", "element": "id:x"}`.
- check_fast selects scripts with `scripts/ui_select.py` from the changed LINES (docs/TESTING.md "Stage-1 UI
  selection"): changed Swift declaration → its test IDs / l10n keys / command names (else those of the code using it,
  up to 3 levels) → the scripts whose JSON uses them; driver / StateDump changes → scripts using that action / dump
  path; `.strings` changes → scripts in that language using the key; plus changed scripts / fixtures / baselines.
- So the link from code to script IS the `.testID` (or l10n key / dump path) the script uses: give the UI you test a
  `.testID` and target it (`id:…`) or `waitFor` a dump key it feeds, otherwise check_fast won't pick your script.
- Verify: `python3 scripts/ui_select.py --explain` (one line per script: changed declaration → linking ID/key; `--files
  …`, `--commit <sha>`), or `scripts/check_fast.sh --list`. `app/Tests/ui_map.txt` now only holds the 5-script
  `smoke:` set, `always` rules and directory FALLBACK rules (used when a change reaches no test hook): don't add
  per-feature rules; don't grow `smoke:`.
- Test both en and fr when you add strings that change layout (`"lang": "fr"`).
