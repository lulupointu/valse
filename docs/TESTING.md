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

**Machine-wide test slots.** `test.sh`, `uitest.sh` and `check_clean.sh` take one of 2 slots shared by every checkout
(mkdir locks in `/tmp/montage-locks`, stale ones reclaimed by PID); `perf.sh` takes all of them (exclusive, and new
runs queue behind it). A blocked run prints "waiting for test slot…". Nested scripts reuse their parent's slot.
`MONTAGE_SLOTS=<n>` changes the count, `MONTAGE_NO_SLOTS=1` disables locking (`scripts/slots.sh`).

**No exact timing budgets in the unit suite.** Wall-clock checks in `scripts/test.sh` use `TimingBudget`
(MontageTestSupport): they assert only gross regressions (3× the budget, `MONTAGE_TIMING_FACTOR`) and are skipped with a
"⚠️ timing check … skipped" line when the 1-min load average exceeds the core count. Emit the measurement with
`TimingBudget.metric("unit_…", value, "ms")`, add the test to the `--filter` in `scripts/perf.sh` and the precise
budget to `bench/perf_thresholds.json` — perf.sh runs exclusively, so its numbers are trustworthy.

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
**Open the PNGs and look at them.** Exit code 0 = pass (3 = skipped; `uitest.sh` exits 1 if any script failed or timed out). `MONTAGE_UITEST_DEBUG=1` logs every event and its hit view.

Examples (copy one): `split_undo`, `trim_undo`, `drag_media_to_timeline`, `inspector_field`, `zoom_slider`, `swiftui_taps`, `language_fr`; per area: `timeline_edit` (move, ⌫, W, magnet), `canvas_drag` (select + drag on the preview), `inspector_tabs` (Scale + Speed fields), `audio_volume`, `text_add`, `ai_tts`, `ai_transcript_panel`.

### Script keys

- `project`: `"empty"` (default) · `"demo"` (synthetic demo project, playhead 0, nothing selected) · `"demo-bin"` (demo
  media in the bin, empty timeline) · `"stress:500"` (500 clips on 3 tracks) · a path to a `.montage` (relative to the script, opened as a temp copy so the fixture is never modified; e.g. `fixtures/speakers.montage`).
- `lang`: `"en"` (default) or `"fr"`. `size`: `[w, h]` window points (default 1687×983). `settle`: seconds to wait after
  loading (default 1.5).
- `requires`: `{"models": ["coreml.lama-800"]}` — the script needs real AI models (ids from `ModelCatalog`). Without it
  every script sees an **empty, sandboxed models folder**, so AI features are "not installed" on every machine and AI
  scripts assert the Download UX (`model.download.<modelID>`, e.g. `ai_remove`). With it the user's models folder
  (`MONTAGE_MODELS_DIR` or ~/Library/Application Support/Montage/Models) is used and the script is **SKIPPED** (exit
  code 3, reported separately by `uitest.sh`) when a model is missing (e.g. `ai_remove_inference`).
  Sidecar runtimes (`whisper-cli`, `demucs`, `llama-completion`) are looked up in the user's real
  `~/Library/Application Support/Montage/bin` even though UI tests sandbox the support folder.
- Caption word timing: `CaptionOnsetTests` builds FR / EN speech with known word onsets, silences and noise
  (`bench/speech_onsets.swift`, cached in ~/Library/Caches/MontageDev/fixtures; bump `fixtureVersion` when the script
  changes) and asserts median onset error < 80 ms, max < 200 ms; `MONTAGE_U2_FOOTAGE=/copy/of/IMG_7251.mov` adds the
  owner clip. Changing word timing → bump `TranscriptStore.version` (stale cached transcripts are then ignored).
- Opt-in AI tests: `MONTAGE_SLOW_TESTS=1 scripts/test.sh --filter MontageAITests` (demucs, LLM writer/clipper);
  `MONTAGE_QA_VIDEO=/path/to/talking-person.mp4 scripts/test.sh --filter RealMediaQATests` runs every engine on real
  footage and prints real-time factors + quality metrics (transcript, stems RMS, scenes, speakers, shorts, TTS round
  trip, super resolution). `--filter RealMediaQA` also runs `RealMediaQA2Tests`: captions on a 9:16 project, cutout,
  reframe, camera / motion tracking, AI movement, face mosaic, relight, AI remove, auto colour (SDR + HLG project), smart
  search, AI writer, EditPilot, clipper / shorts (`MONTAGE_QA_LONG_VIDEO`, ≥ 60 s), audio clean-up levels through the export
  mix, stabilize, slow-mo; rendered frames / WAVs go to `MONTAGE_QA_OUT` (default a temp folder) — look at them. Use COPIES
  of real footage; results of the 2026-10-19 pass are in docs/STATUS.md ("AI QA results").
  `MONTAGE_ENHANCE_LOG=1` (tests or the app) prints where an Enhance quality / denoise / deflicker pass spent its time
  (decode / filter / scale / encode, real-time factor).

**Environment-independent results.** Settings/library are sandboxed; in UI tests the cache-size readouts are fixed
(`SettingsView.uitestCacheSizes`, "clear" only zeroes them) and the `home` sample projects use a fixed clock. For other
volatile pixels add `"mask": ["id:x", …]` to a `snapshot` step (those elements are painted grey in the snapshot and its baseline).

### Targets (where a mouse step happens)

| Target | Meaning |
|---|---|
| `"id:toolbar.split"` | element with that test ID, centre; `"at": [fx, fy]` (0…1, top-left) picks another point |
| `"clip:main/1"` | clip 1 of the main track (`clip:<model track index>/<clip index>`, negative index = from the end) |
| `"clip:0/0:trailing"` | its right edge (`:leading`, `:body`, or `:0.25` = fraction of its width) |
| `"clip:selected"` | the (first) selected clip |
| `"time:7.5@ruler"` / `"time:3@main"` / `"time:3@2"` | a time on the ruler / on a track row |
| `"header:main/lock"` · `"header:2/more"` · `"header:main/cover"` | a track-header control (`type`, `lock`, `eye`, `mute`, `more`; `cover` = the main track's Cover button) |
| `"player:0.5,0.5"` | a point in the preview (0…1, top-left) |

| `"point:100,200"` | window content coordinates (points, top-left) |

Any step may add `"offset": [dx, dy]` (points, +y down) and `"modifiers": ["cmd", "shift", "opt", "ctrl"]`.

### Steps

| Step | Example |
|---|---|
| click / doubleClick / rightClick | `{"click": "id:inspector.tab.speed"}` · `{"click": "clip:main/0", "modifiers": ["shift"]}` |
| timeline context-menu item | `{"rightClick": "clip:main/0", "menuItem": "tlmenu.separateAudio/stem.vocals"}` (l10n keys or titles; the menu is captured, not popped up) |
| drag (press, N moves, release) | `{"drag": "clip:main/0:trailing", "by": [-60, 0]}` · `{"drag": "id:slider.opacity", "at": [0.9, 0.5], "to": "id:slider.opacity", "toAt": [0.2, 0.5], "steps": 12}` |
| scroll | `{"scroll": "id:timeline", "dx": -200, "dy": 0}` · zoom: `{"scroll": "id:timeline", "dy": 10, "modifiers": ["cmd"]}` · trackpad gesture (U1): `"phase": "began" \| "changed" \| "ended"` (continuous events, rubber-band checks; `u1_settings_no_hscroll.json`) |
| hover | `{"hover": "clip:main/0"}` |
| key (with modifiers) | `{"key": "cmd+b"}` `{"key": "space"}` `{"key": "shift+left", "repeat": 3}` `{"key": "delete"}` |
| type text (first responder) | `{"type": "Hello"}` · `{"type": "30", "replace": true}` (select all first) |
| menu bar command (by l10n key or title) | `{"menu": "menu.edit/menu.undo"}` |
| drag & drop from a panel | `{"drop": {"media": 0}, "on": "time:0@main"}` — also `{"effect": id}`, `{"transition": id}`, `{"sticker": id}`, `{"text": styleID}`, `{"files": ["a.mp4"]}` |
| assert on the state dump | `{"expect": {"path": "selectedClips.0.opacity", "lt": 0.6}}` or a list of them |
| wait for async work | `{"waitFor": {"path": "media.count", "equals": 2, "timeout": 10}}` · `{"wait": 0.5}` · `{"idle": 1}` |
| snapshot / screenshot test | `{"snapshot": "name", "element": "id:panel.inspector", "baseline": true, "tolerance": 0.01, "mask": ["id:clock"]}` |
| dump state | `{"dump": "before-drop"}` → `build/uitest/<name>/before-drop.json` |
| VoiceOver label audit (SE-017) | `{"a11yAudit": "inspector", "max": 0}` — walks the real AX tree; fails when more than `max` buttons / checkboxes / sliders / images / fields have no spoken name; writes `<name>.a11y.json` |
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
keyframes, selected, transitionDuration, animIn, animOut, animCombo, keyframeCounts.<key>, keyframeEasings.<key>}` (keys with
`_` for `.`: `transform_position`; easings are preset ids: `linear`, `easeIn`, `quadOut`…) · `media` · `canvas.{width,height,aspect}` · `ui.{inspectorTab, inspectorTabs, assetTab,
exportSheet, export, language, toast, pixelsPerSecond, scrollTime, scrollY, menu, anchors, selectedKeyframe.{key,time}, keyframePanel}` (`ui.export.dialog.{scope, duration, video, audio, gif, captions, codec, container, outputs, canExport, footer, burnCaptionsRow, coverReady, …}`, `ui.export.jobs` / `ui.export.shown` = `{title, state, progress, written, outputs}`) · `ui.jobs` (background jobs `{title, progress, state}`) and `ui.activeJobs` (queued + running count: `{"waitFor": {"path": "ui.activeJobs", "equals": 0, "timeout": 600}}` waits for AI jobs) · `ui.models.<model id with "." → "_">` (`notInstalled` / `downloading` / `verifying` / `installed` / `failed: …`, progress in `ui.models.progress.<id>`) · `project` (full project JSON).
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
- Home (W12, `"project": "home"` / `"home:12"` = sandboxed library with N sample projects, `"home:3:crash:missing"` adds a
  crashed session + a missing media file): `home.nav.{home,recents,templates,trash,settings,folder.<i>}`, `home.newProject`,
  `home.newProject.custom`, `home.top.{import,shortcuts,settings}`, `home.search(.field|.clear)`, `home.view.{grid,list}`,
  `home.col.<sort>`, `home.card.<i>` / `home.row.<i>`, `home.selection.{duplicate,delete,restore,deleteForever}`, `home.trash.empty`,
  `home.empty`; dialogs `dialog.{ok,cancel,close,field}`, `newProject.name`, `version.{row.<i>,saveNow,restore}`, `relink.close`;
  Settings `settings.tab.<tab>`, `settings.{check,switch,field,radio,button,language}.<id>`; shortcuts `keymap.binding.<cmd>`,
  `keymap.preset.<preset>`, `keymap.conflict(.override|.cancel)`, `keymap.reset`. State: `app.{screen, modal, scope, projects,
  selected, settings, keymap.bindings, renderedRanges…}` (StateDump.appHook).
- asset panel: `asset.tab.<tabID>`, `asset.tile.<itemID>`, `media.card.<index>` (grid tile or list filmstrip row; `"at": [fx, fy]` clicks at a source time, C6), `media.import`, `media.layout`; state `ui.assets.media.{layout, columns}`, `ui.assets.preview.{kind, time}`
- tooltips (C6, custom: `Support/Tooltips.swift`): `{"hover": "id:toolbar.split", "settle": 0}` then `ui.tooltipPending` (waiting for the 0.2 s delay) / `ui.tooltip` (visible text, null when none) — see `c6_tooltips.json`. The driver resolves the hovered `.help()` element itself (tracking areas only fire for real moves)
- U1: Settings sideways scroll `ui.settings.{overflow, innerOverflow, scrollX, innerScrollX, horizontallyElastic}` (Settings open only);
  playback follow `ui.followManual` (the user scrolled during playback: no auto follow, `u1_playhead_follow.json`); splitters
  `ui.layout.{left,right,top}` after a `drag` on the gutter (`u1_splitter_drag.json`). Record a real on-screen run (behind other
  windows, never activated, in-process events only): `MONTAGE_UITEST_ORIGIN=0,40 MONTAGE_UITEST_VISIBLE=1 Montage --uitest …`
  + `screencapture -v -l <windowID>`
- animation search field: `anim.search`
- inspector sub-tabs: `inspector.sub.<subTabID>` (e.g. `inspector.sub.out`); asset sub-nav: `asset.nav.<itemID>`
- transitions (W5): `transitions.search`, `transition.tile.<id>` / `transition.add.<id>` (id without `montage.transition.`),
  inspector `transition.duration(.field)`, `transition.param.<key>(.field)`, footer `transition.applyAll`
- animations: `anim.none`, `anim.<phase>.<name>` (e.g. `anim.in.bounce`, `anim.combo.zoomInOut`); grid tiles are lazy, so
  only tiles near the top are reachable without scrolling
- keyframe panel (⌥K): `panel.keyframes` — during UI tests it is hosted inside the test window (normally a floating NSPanel),
  `keyframes.preset.<presetID>`, `keyframes.applyAll`, `keyframes.reset`. Select a timeline keyframe by clicking the
  bottom band of the selected clip (`"clip:main/2:0.08", "offset": [0, 32]`, see `w5_keyframe_ease.json`)
- EditPilot (AI2): `titlebar.pilot` (or ⌘J), `pilot.panel`, `pilot.input`, `pilot.send`, `pilot.dictate`, `pilot.suggestion.<i>`,
  `pilot.card`, `pilot.step.<i>` (checkbox; steps are shown in execution order), `pilot.diff`, `pilot.progress`, `pilot.preview`,
  `pilot.apply`, `pilot.discard`, `pilot.undo`, `pilot.new`, `pilot.close`; state `ui.pilot.{open, messages, busy, previewing,
  engine, state (planning/preparing/ready/applied/discarded/failed/empty), steps, results, diff}`. Without `requires.models` the
  rule-based planner is used (deterministic); `ai_editpilot_llm.json` requires the Qwen model. Dictate buttons: `text.dictate`,
  `writer.dictate`. The app cancels and waits for every background job before exiting (`ai_quit_mid_job.json`).
- Long video to shorts (Home): `home.feature.shorts`, `shorts.dialog`, `shorts.import`, `shorts.problem`, `shorts.change`,
  `shorts.duration.<auto|under60|from60to90|from90to180>`, `shorts.captions`, `shorts.get`, `shorts.progress`, `shorts.result.<i>`;
  project specs `"home:0:shorts"` (wizard on a synthetic 4 s video → too short) and `"home:0:shorts-ok"` (valid 70 s video).
- audio library: `asset.nav.<section>` (yours / music / sfx / extracted), `audio.import`, `audio.row.<index>` (+`.add`), `audio.music.<trackID>` (+`.add`)
- bundled CC0 music/SFX library (MUS): rail `asset.nav.music.cat.<category>` / `asset.nav.sfx.cat.<category>` /
  `asset.nav.similar`; rows `asset.tile.lib.<itemID>` (+`.add`, `.favorite`, `.similar`, `.license`),
  `audio.license.card` / `audio.license.close`, `audio.similar` / `audio.similar.close`, header `audio.similar.clip` (similar to the
  selected clip); About `about.content.toggle` / `about.content.list`. State: `ui.assets.library.{music,sfx}` (installed counts),
  `ui.assets.similar.{seed, title, kind, computing, results}`, `ui.assets.licenseCard`. Scripts needing the library audio declare
  `"requires": {"content": true}` (SKIPPED when scripts/fetch_music_pack.sh was never run)
- online music search (MUS): rail `asset.nav.online.{forYou,trending,moods,genres,sfx}`, chips `online.mood.<id>` /
  `online.genre.<id>` / `online.sfxcat.<id|popular>`, rows `asset.tile.online.<provider>.<remoteID>`, states
  `online.state.{noKey,offline,invalidKey,disabled,rate,failed}` (+`.primary` / `.secondary`), Settings ▸ Music
  `settings.music.key.<provider>` / `.save.` / `.remove.` / `.status.`, `audio.license.copyCredit`. State: `ui.assets.online.{phase,
  results, count, keys, saved, mood, genre, sfxCategory, downloading, requests}`. UI-test mode ALWAYS uses `MockOnlineAudioHTTP`
  + an in-memory key store (no network, no Keychain); mock key `offline` = no connection, `bad` = rejected key. Live check:
  `MONTAGE_LIVE_FREESOUND_KEY=… MONTAGE_LIVE_JAMENDO_KEY=… swift test --filter liveSearch` (skipped otherwise)

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

`scripts/perf.sh` runs `app/Tests/PerfScripts/timeline_500.json` (release build, 500 clips / 300 media: timeline scroll /
zoom / zoomed-out scroll, inspector slider drag, ruler scrub, asset grid scroll — main-thread CPU per event —, launch,
project open, memory peak) plus `PerfAuditTests` (complex 1080p/4K playback with effects: compositor cost + dropped %,
scrub latency proxy/original, paused live-edit re-render, 4K + 3 effects + title with automatic proxies, engine memory
peak), `PerfMemoryTests` in its own process (typical 1080p project: play, scrub, live edits, 10 s export →
`engine_memory_1080p_peak_mb`, lifetime peak footprint; `MEMDIAG` lines in `memory.log` break it down), the timing unit tests (`unit_*`) and the
4K perf smoke tests (`PerfSmokeTests`: playback fps, export, proxy; needs
`bench/media` from `bench/make_media.sh`, a worktree reuses the main checkout's), writes `build/perf/results.json`
(`{mode, machine, metrics, violations}`) and exits 1 when a metric breaks its threshold in `bench/perf_thresholds.json`.

- `--air`: MacBook Air approximation — runs under `taskpolicy -c background` (efficiency cores only, throttled I/O;
  pessimistic vs a real M1 Air) with `MONTAGE_SIMULATE_RAM_GB=8` (`MemoryBudget` 8 GB policies: 720p preview, forced
  proxies, smaller caches). Compared against the `air` thresholds.
- Add a metric: a `perf`/`metric` step in a perf script (or an `emit` line in `PerfSmokeTests`/`PerfAuditTests`, or
  `TimingBudget.metric` in a unit test listed in perf.sh's `--filter`), then a threshold entry for both modes.
- Profiling a UI interaction: run the app with a one-step perf script and attach `xcrun xctrace record --template
  'Time Profiler' --attach <pid>`; SwiftUI layout of the hosting view usually dominates. Editor panels live in separate
  hosting views (`IsolatedHost`) so one panel's updates don't lay out the window — keep new panels inside one.
  Tighten thresholds when something gets faster; never loosen one to hide a regression without saying why.
- Asset panels / other always-visible views must read observation slices (`store.mediaBin`, `store.usedMediaIDs`…),
  never `store.project`: reading it in a body re-renders that view on every edit tick (an inspector drag re-rendered the
  300-item media bin: 5.6 → 19 ms/event).
- Engine memory: frame textures come from `FrameScratch` (dead ones are reused within the frame — call
  `scratch.recycle` when you add a pass whose input is not needed afterwards); caches take their size from
  `MemoryBudget` and shrink in `MemoryPressure.apply`.
