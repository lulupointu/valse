# TESTING.md — UI tests, screenshot tests, perf tests in 5 minutes

Everything here runs **without touching the real screen, mouse or keyboard** and needs **no Screen Recording /
Accessibility permission**: the app opens its window far offscreen, never activates, and replays synthetic events
inside its own process. Safe to run while other agents (or the user) use the machine.

| I want to… | Run |
|---|---|
| unit / render tests | `scripts/test.sh` (see ARCHITECTURE.md §15) |
| an interaction test | `scripts/uitest.sh app/Tests/UIScripts/my_test.json` |
| all interaction tests | `scripts/uitest.sh --all` |
| a screenshot test | a `snapshot` step with `"baseline"` in a UI script |
| compare two PNGs | `scripts/imgdiff.sh a.png b.png [--tolerance 0.005] [--threshold 16]` |
| perf numbers / regressions | `scripts/perf.sh` (`--air` = MacBook Air approximation) |
| check a clean checkout builds + tests (before "ready to merge") | `scripts/check_clean.sh [--ui]` |
| just look at the UI | `scripts/screenshot.sh --demo --offscreen` |

## 1. A UI test in 5 minutes

Create `app/Tests/UIScripts/<name>.json` (`//` line comments allowed):

```json
// Select a clip, split it with ⌘B at 7.5 s, undo.
{
  "project": "demo",
  "steps": [
    {"click": "clip:main/1"},
    {"click": "time:7.5@ruler"},
    {"key": "cmd+b"},
    {"expect": [{"path": "main.clips.count", "equals": 4}, {"path": "undo.name", "equals": "cmd.split"}]},
    {"snapshot": "after-split", "element": "id:timeline"},
    {"key": "cmd+z"},
    {"expect": {"path": "main.clips.count", "equals": 3}}
  ]
}
```

Run `scripts/uitest.sh app/Tests/UIScripts/<name>.json`. Output goes to `build/uitest/<name>/`: `report.json` (steps,
errors, metrics), `final.json` (state dump), every `snapshot` PNG, and on failure `failure.json` + `failure.png`.
**Open the PNGs and look at them.** Exit code 0 = pass. `MONTAGE_UITEST_DEBUG=1` logs every event and its hit view.

Examples (copy one): `split_undo`, `trim_undo`, `drag_media_to_timeline`, `inspector_field`, `zoom_slider`, `swiftui_taps`, `language_fr`; per area: `timeline_edit` (move, ⌫, W, magnet), `canvas_drag` (select + drag on the preview), `inspector_tabs` (Scale + Speed fields), `audio_volume`, `text_add`, `ai_tts`, `ai_transcript_panel`.

### Script keys

- `project`: `"empty"` (default) · `"demo"` (synthetic demo project, playhead 0, nothing selected) · `"demo-bin"` (demo
  media in the bin, empty timeline) · `"stress:500"` (500 clips on 3 tracks) · a path to a `.montage` (relative to the script).
- `lang`: `"en"` (default) or `"fr"`. `size`: `[w, h]` window points (default 1687×983). `settle`: seconds to wait after
  loading (default 1.5).

### Targets (where a mouse step happens)

| Target | Meaning |
|---|---|
| `"id:toolbar.split"` | element with that test ID, centre; `"at": [fx, fy]` (0…1, top-left) picks another point |
| `"clip:main/1"` | clip 1 of the main track (`clip:<model track index>/<clip index>`, negative index = from the end) |
| `"clip:0/0:trailing"` | its right edge (`:leading`, `:body`, or `:0.25` = fraction of its width) |
| `"clip:selected"` | the (first) selected clip |
| `"time:7.5@ruler"` / `"time:3@main"` / `"time:3@2"` | a time on the ruler / on a track row |
| `"player:0.5,0.5"` | a point in the preview (0…1, top-left) |
| `"point:100,200"` | window content coordinates (points, top-left) |

Any step may add `"offset": [dx, dy]` (points, +y down) and `"modifiers": ["cmd", "shift", "opt", "ctrl"]`.

### Steps

| Step | Example |
|---|---|
| click / doubleClick / rightClick | `{"click": "id:inspector.tab.speed"}` · `{"click": "clip:main/0", "modifiers": ["shift"]}` |
| drag (press, N moves, release) | `{"drag": "clip:main/0:trailing", "by": [-60, 0]}` · `{"drag": "id:slider.opacity", "at": [0.9, 0.5], "to": "id:slider.opacity", "toAt": [0.2, 0.5], "steps": 12}` |
| scroll | `{"scroll": "id:timeline", "dx": -200, "dy": 0}` · zoom: `{"scroll": "id:timeline", "dy": 10, "modifiers": ["cmd"]}` |
| hover | `{"hover": "clip:main/0"}` |
| key (with modifiers) | `{"key": "cmd+b"}` `{"key": "space"}` `{"key": "shift+left", "repeat": 3}` `{"key": "delete"}` |
| type text (first responder) | `{"type": "Hello"}` · `{"type": "30", "replace": true}` (select all first) |
| menu bar command (by l10n key or title) | `{"menu": "menu.edit/menu.undo"}` |
| drag & drop from a panel | `{"drop": {"media": 0}, "on": "time:0@main"}` — also `{"effect": id}`, `{"transition": id}`, `{"sticker": id}`, `{"text": styleID}`, `{"files": ["a.mp4"]}` |
| assert on the state dump | `{"expect": {"path": "selectedClips.0.opacity", "lt": 0.6}}` or a list of them |
| wait for async work | `{"waitFor": {"path": "media.count", "equals": 2, "timeout": 10}}` · `{"wait": 0.5}` · `{"idle": 1}` |
| snapshot / screenshot test | `{"snapshot": "name", "element": "id:panel.inspector", "baseline": true, "tolerance": 0.01}` |
| dump state | `{"dump": "before-drop"}` → `build/uitest/<name>/before-drop.json` |
| setup shortcuts (not UI) | `{"seek": 2.5}` · `{"select": ["clip:main/0", "clip:1/0"]}` |
| perf / metric | see §3 |

After every input step the driver waits until all posted events were dispatched plus `settle` seconds (default 0.25).

`expect` operators: `equals`, `notEquals`, `approx` (+`tolerance`, default 0.001), `gt`/`gte`/`lt`/`lte`, `contains` /
`notContains` (string / array / dictionary key), `count`, `exists` (true/false). Numbers compare with 1e-6 tolerance.

### State dump (what `path` reads)

`playhead`, `duration`, `isPlaying` · `selection` (clip ids) · `selectedClips` (clip summaries) · `undo.{depth, redoDepth,
name, redoName, inGesture, revision, dirty}` · `tracks` (model order, bottom→top: `{index, kind, isMain, locked, hidden,
muted, clips}`) · `main` (the main track) · clip summary: `{id, track, index, kind, name, text, start, duration, end,
sourceStart, speed, opacity, enabled, blend, effects, transition, scale, rotation, positionX, positionY, volume,
keyframes, selected}` · `media` · `canvas.{width,height,aspect}` · `ui.{inspectorTab, inspectorTabs, assetTab,
exportSheet, export, language, toast, pixelsPerSecond, scrollTime, scrollY, menu, anchors}` (`ui.export.dialog.{scope, duration, video, audio, gif, captions, codec, container, outputs, canExport, …}`, `ui.export.jobs` / `ui.export.shown` = `{title, state, progress, written, outputs}`) · `project` (full project JSON).
Path segments: keys, indices (negative from the end), `count`, `first`, `last`. Source: `MontageUI/Testing/StateDump.swift`.

### Test IDs (stable element lookup)

SwiftUI: `.testID("area.thing")` (sets `accessibilityIdentifier`; while a UI test runs it also records the frame).
AppKit: `view.setAccessibilityIdentifier("timeline")`. Never use localized text in IDs. `ui.anchors` in the state dump
lists the IDs currently on screen. **Add IDs to the views you build** so tests can reach them. Existing IDs:

- panels: `panel.assets`, `panel.player`, `panel.inspector`, `panel.timeline`; AppKit views: `timeline`, `player`
- title bar: `titlebar.export`, `titlebar.shortcuts`
- timeline toolbar: `toolbar.{undo, redo, split, deleteLeft, deleteRight, delete, magnet, snapping, linkage, zoomFit, zoomOut, zoomSlider, zoomIn}`
- player: `player.play`
- inspector: `inspector.tab.<tabID>`, `inspector.section.<sectionID>`, `slider.<ParamKey.raw>` (e.g. `slider.opacity`,
  `slider.rotation`) and `slider.<key>.field` (numeric field); `Bind.value` sliders: `slider.<label>` (pass `testID:` to `SliderRow` for a stable one)
- export dialog: `export.dialog`, `export.section.{video,audio,gif,captions}` (+`.expand`), `export.title`, `export.folder`, `export.editCover`, `export.estimate`, `export.cancel`, `export.confirm`; progress view: `export.progress`, `export.stop`, `export.close`, `export.openFolder`, `export.share`; `titlebar.exportQueue` (UI-test exports go to a temp folder emptied per run)
- asset panel: `asset.tab.<tabID>`, `asset.tile.<itemID>`, `media.card.<index>`, `media.import`

### How it works / limits

`Montage --uitest script.json` (see `MontageApp/main.swift`) builds the normal editor in a `UITestWindow` at
(−30000, −30000) with the accessory activation policy. Events are `NSEvent`s posted to the app's own queue
(`NSApp.postEvent`), dispatched through the real `sendEvent` → hit-tested view path (SwiftUI via NSWindow, AppKit views
directly, because AppKit ignores clicks on an inactive app's window). NSSlider drags become a press at the final
position (the knob jumps there) through the real `NSSlider.mouseDown` — intermediate values are not replayed. Key
events go through the app's shortcut monitor and menu key equivalents; while a text field is editing they are
delivered to the field editor. Drag & drop calls the destination's
`NSDraggingDestination` methods with a private pasteboard (no WindowServer drag session). Snapshots use the offscreen
renderer (`SnapshotRegistry`: SwiftUI `cacheDisplay` + Metal views rendered offscreen).
SwiftUI `onTapGesture` / `DragGesture` / `Button`s work: AppKit only delivers a click into an inactive app's window
to views that accept "first mouse", so in the test process every SwiftUI hosting class is made to accept first mouse
(`UITestWindow.acceptFirstMouse`). Custom SwiftUI sliders built from `DragGesture` can be dragged; NSSlider drags are
replayed as described above. `"press": "id:x"` (in-process accessibility press) also exists.
Also not covered: real NSMenu popups (SwiftUI `Menu`/`Picker` menus open a modal tracking loop — use the menu bar `menu`
step or set the value via a setup step), NSOpenPanel/NSSavePanel, hover-only visuals that read the real cursor.
Autosave is disabled during tests; the language preference is restored on exit.

## 2. Screenshot tests

Add `"baseline": true` (or a baseline name) to a `snapshot` step. Baselines live in `app/Tests/Baselines/<name>.png`,
stored at 1 px per point (downscaled from Retina) to keep the repo small. Prefer cropping to an element
(`"element": "id:panel.inspector"`) over full-window baselines.

- First run: the baseline is created and the run warns "baseline created — LOOK at it and commit it".
- Later runs compare with tolerance: a pixel differs when a channel differs by more than `threshold` (0–255, default
  16); the step fails when more than `tolerance` (fraction, default 0.005 = 0.5 %) of pixels differ. The diff image
  (`<name>.diff.png`: differing pixels red over the dimmed baseline) is written next to the snapshot.
- Intentional UI change: `scripts/uitest.sh --update-baselines <script>`, look at the new PNGs, commit them.
- Video frames, thumbnails and fonts can vary slightly: use `threshold` 32–48 and `tolerance` 0.01–0.03 for regions
  with media; keep defaults for pure chrome.
- Standalone: `scripts/imgdiff.sh a.png b.png --diff d.png` prints `{"passed", "fraction", "differingPixels", …}`.

## 3. Perf tests

See `scripts/perf.sh --help`. Perf steps inside a UI script:

```json
{"project": "stress:500", "steps": [
  {"perf": "timeline_scroll", "frames": 300, "dx": -30, "alternate": true},
  {"perf": "timeline_zoom", "frames": 120, "dy": 6, "modifiers": ["cmd"], "alternate": true, "period": 20},
  {"metric": "memory"}
]}
```

`perf` delivers one scroll event per frame through the timeline's real `scrollWheel` path and measures the frame the
way `TimelineView.draw` builds it (CPU: Canvas2D build + encode; GPU: command buffer time). Metrics land in
`report.json` → `metrics`: `<name>_cpu_p50_ms`, `_cpu_p95_ms`, `_cpu_max_ms`, `_gpu_p95_ms`; `memory_mb`,
`memory_peak_mb` (physical footprint, lifetime peak).

`scripts/perf.sh` runs `app/Tests/PerfScripts/timeline_500.json` (release build; timeline scroll / zoom / zoomed-out
scroll with 500 clips, memory peak) plus the 4K perf smoke tests (`PerfSmokeTests`: playback fps, export, proxy; needs
`bench/media` from `bench/make_media.sh`, a worktree reuses the main checkout's), writes `build/perf/results.json`
(`{mode, machine, metrics, violations}`) and exits 1 when a metric breaks its threshold in `bench/perf_thresholds.json`.

- `--air`: MacBook Air approximation — runs under `taskpolicy -c background` (efficiency cores only, throttled I/O;
  pessimistic vs a real M1 Air) with `MONTAGE_SIMULATE_RAM_GB=8` (`MemoryBudget` 8 GB policies: 720p preview, forced
  proxies, smaller caches). Compared against the `air` thresholds.
- Add a metric: a `perf`/`metric` step in a perf script (or an `emit` line in `PerfSmokeTests`), then a threshold entry.
  Tighten thresholds when something gets faster; never loosen one to hide a regression without saying why.
