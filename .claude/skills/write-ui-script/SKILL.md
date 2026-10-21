---
name: write-ui-script
description: Write or fix a Montage UI test script (app/Tests/UIScripts/*.json, run by scripts/uitest.sh) - DSL steps and targets, waitFor on state dump paths instead of sleeps, text-field key routing gotcha, element-scoped snapshots and baselines (incl. macos13 overrides), test IDs, ui_map.txt selection. Use when adding UI coverage for a feature, when a UI script is flaky or fails, or when re-recording baselines.
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
  `{"waitFor": {"path": "ui.activeJobs", "equals": 0, "timeout": 600}}`. Timeouts are ceilings, not expected durations:
  give 3-5x what it takes alone (the waitFor returns as soon as the condition holds, so a big timeout costs nothing).
- Debounced inputs (search fields): after `type`, `waitFor` the committed query / result count, not a fixed delay
  (audio_online regression: last keystrokes dropped on macOS 13).
- Before a `snapshot`, `waitFor` whatever paints it (thumbnails, results, the selected tab) so pixels are final.
- Every `expect` right after an async action should be a `waitFor` instead.
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
- check_fast picks scripts via `app/Tests/ui_map.txt` (path glob → script globs), test IDs / l10n keys found in your
  changed Swift files, and changed scripts / baselines. New area or new script naming: add a rule there. Verify with
  `scripts/check_fast.sh --list` that your scripts are selected. Don't add to the `smoke:` line unless fast and broad.
- Name scripts by area prefix used in ui_map rules (e.g. `inspector_*`, `audio_*`, `w5_*`), and test both en and fr
  when you add strings that change layout (`"lang": "fr"`).
