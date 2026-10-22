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
| feature-agent gate, once on the final commit: incremental build + unit tests + the UI scripts relevant to your diff | `scripts/check_fast.sh` (`--list` = what/why) |
| full gate, orchestrator, once per batch branch: clean checkout, everything | `scripts/check_clean.sh --ui` |
| stop your own stuck test runs (Montage test processes of this checkout only) | `scripts/kill_tests.sh --dry-run`, then `scripts/kill_tests.sh` |
| who holds the test slots / reclaim dead or hung ones | `scripts/slots.sh status` / `scripts/slots.sh reclaim` |
| free disk (merged worktrees' .build, `$TMPDIR/montage-*` > 3 h) | `scripts/cleanup.sh --dry-run`, then `scripts/cleanup.sh` |
| merge a batch branch that passed the full gate (orchestrator) | `scripts/merge_agent.sh <branch>` (`--check-only`, `--docs-delta-ok`) |
| regenerate the real-like fixtures | `scripts/make_fixtures.sh` |
| just look at the UI | `scripts/screenshot.sh --demo --offscreen` |

**Machine-wide test slots.** `test.sh`, `uitest.sh`, `check_fast.sh` and `check_clean.sh` take one slot shared by every
checkout (mkdir locks in `/tmp/montage-locks` holding PID, start time, command, cwd); `perf.sh` takes all of them
(exclusive, and new runs queue behind it). A blocked run prints "waiting for test slot…". Nested scripts reuse their
parent's slot. Count: `MONTAGE_SLOTS`, default min(max(2, cores / 5), max(1, RAM GB / 6)); slots beyond the first are
only handed out while the 1-min load is below `MONTAGE_SLOT_MAX_LOAD` (3 × cores). Waiters queue **FIFO** (oldest
first; `scripts/slots.sh status` lists the queue). A slot is **reclaimed** (and the reclaim printed) when its
holder is dead / its PID reused, or its whole process tree used < 2 CPU-seconds and started no process for
`MONTAGE_SLOT_IDLE_MIN` (20) minutes of continuous observation: a hung run, its tree is killed. A hung build / test is
killed sooner by the hang watchdog below, and the script's exit frees its slot. The cap is for throughput only: the
tests must pass under any load. `MONTAGE_NO_SLOTS=1` disables locking (`scripts/slots.sh`).

**Retries, flaky tests, quarantine.** `test.sh` re-runs every failed test once, alone (`--filter Suite/test()`; the
`--xunit-output` report names it); `uitest.sh` re-runs a failed script once (first attempt kept in
`<out>/<name>.attempt1`; before the retry it waits ≤ 60 s, `MONTAGE_RETRY_WAIT`, for the 1-min load to drop below the
core count). A pass on the retry is reported **"flaky (passed on retry)"** and does not fail the run; two
failures in a row fail it — unless the test is listed in `app/Tests/quarantine.txt` (`<unit|ui> <id> <date> <reason>`,
validated by `python3 scripts/testlib.py check-quarantine`): quarantined tests still run and are reported, but don't
gate. `--no-retry` disables retries. A crash (no test summary) or a hang is never retried.

**Hang watchdog.** `swift build`/`swift test` in test.sh, uitest.sh and check_clean.sh run under a watchdog: no new log
output AND < 1 % CPU (whole process tree) for `MONTAGE_HANG_MINUTES` (default 10) → the process tree, then `sample`
stacks of its processes are appended to the log (`build/test.log`), the tree is killed and the run fails with
**"HUNG"**. A UI script's `--timeout` (default 120 s) is a hang detector too, not a total limit: the driver touches
`<out>/<name>/.heartbeat` when a step starts and while it polls (every driver wait has its own progress-based bound), and
an app whose heartbeat is older than `--timeout` is `sample`d into `<out>/<name>/hang-sample.txt` and killed
("TIMEOUT (HUNG): no driver progress for 120s"); a slow script that keeps progressing is not (sanity ceiling
`MONTAGE_UITEST_MAX_SECONDS`, 1800 s). With `--jobs`, **heavy** scripts (`"requires": {"models": …}` = real ML inference,
or `"heavy": true`) are started first and run one at a time (the other workers take light scripts meanwhile): three of
them at once each ran ~3× slower.

**Temp files and disk.** test.sh and uitest.sh run tests / apps with a private `TMPDIR`
(`$TMPDIR/montage-run-*`) deleted on exit, even on failure or Ctrl-C, so sandboxes (`montage-sandbox-*`), exports, project
copies and mock downloads never pile up; the synthetic media cache stays shared (`MONTAGE_TEST_MEDIA_DIR`, default
`$TMPDIR/montage-test-media-v1`). check_clean reuses a persistent clean worktree
(`<main checkout>/build/check_clean-cache/wt0|wt1`, ~1.5 GB each: reset to exactly HEAD with `checkout --force` +
`clean -ffdx` except `.build`, verified pristine, resource bundles rebuilt) for an incremental build. The `.build`
is wiped (printed as `cold: <reason>`) when the package graph or toolchain changed (Package.swift, Package.resolved,
target folders, `swift --version`: a removed target's leftover module would let a stale `import` compile), after 20
gates or 24 h (`MONTAGE_WARM_MAX_GATES` / `MONTAGE_WARM_MAX_HOURS`). Locks are kernel `flock`s (no stale locks).
`--cold` uses a temp `montage-clean.*` worktree removed on exit. `uitest.sh --jobs K` runs K apps at once: each UI-test app has a private
settings domain and pasteboard (MontageCore `AppDefaults`, `AppPasteboard`), sandbox, cache folder
(`montage-test-cache/run-<pid>`, compiled models shared and installed atomically: `AtomicInstall`) and TMPDIR, so
scripts can't interact; check_clean runs the UI suite with `--jobs 4` while the unit suite runs. check_fast / check_clean
fail fast with "DISK FULL" below 5 GB free (`MONTAGE_MIN_FREE_GB`). `MONTAGE_KEEP_TMP=1` keeps the temp dirs to debug.

**Real-like fixtures (T1).** `app/Tests/UIScripts/fixtures/real/` (`RealLikeMedia` in Swift), made by
`scripts/make_fixtures.sh`, fully synthetic:
- `iphone_hlg_portrait.mov`: HEVC Main10, BT.2020 HLG, coded 1920×1080 with an iPhone −90° matrix (1080×1920
  upright), 30 fps, B-frames, a drawn face (Vision detects it), a highlight above SDR white, AAC 44.1 kHz speech.
- `speech_en.m4a`: speech with a ~0.9 s pause.
- `music_120bpm.m4a`: kick / hat / chords.

`RealLikeFootageTests` cover probe, the player, export, thumbnails, Vision face, waveform and beats.
`ColorSpaceLookTests.realFootageMatchesApple` runs on the clip in every project space; UI script `real_footage_import`.
Owner footage stays opt-in and uncommitted: `MONTAGE_REAL_FOOTAGE="/path/a.MOV@2|/path/b.MOV"`. These clips are added
to the colour tests and `RealLikeFootageTests.ownerFootageProbesAndPlays`, as are `MONTAGE_C1_FOOTAGE`,
`MONTAGE_QA_PROJECT` (playback stress on a real project) and `MONTAGE_QA_VIDEO` (AI QA).

**Stage-1 UI selection.** `scripts/ui_select.py --explain [--files …]` prints what `check_fast.sh` would run and WHY
(one line per script: the changed declaration → the test ID / l10n key / dump key that links it).
The diff base (`--base auto`, default) is the nearest of `main` / the local `batch-*` branches the branch is based on
(the most recent merge-base with HEAD; a batch that already contains HEAD doesn't count), printed as `diff base: …`; so a
branch made from `batch-3` is not diffed against main. `--base <ref>` overrides it (`check_fast.sh --base HEAD~1` = the
last commit only); `ui_select.py --commit <sha>` replays one commit. The selection is derived from the changed LINES:
- a Swift change → the test IDs / l10n keys / command names of the changed declaration, else of the code using it
  (up to 3 levels, nearest hook wins; `"transition.duration"` also matches `id:transition.duration.field`) → scripts
  using them; plus scripts reading a state-dump key fed by an identifier on a changed line (`.editingGuide`);
- `UITestDriver.swift` / `SyntheticEvents.swift` → only the scripts using the changed step action / target kind /
  project kind (driver core → all); `StateDump.swift` → scripts whose `expect` / `waitFor` paths use the changed keys;
- `Resources/<lang>.lproj/*.strings` → scripts in that language using the key / its text, or with a baseline snapshot
  of a view rendering the key.
`app/Tests/ui_map.txt` keeps the 5-script smoke set, `always` rules (app entry, theme, render / playback engine) and
directory FALLBACK rules used only when a changed declaration reaches no test hook. If check_fast misses your script,
give the UI you test a `.testID` the script uses (that is what links code to scripts). Specificity rule (`hub_limit`): a link
shared by more than max(12, 10 %) of the scripts — a script string (`panel.inspector`, `undo.name`), an interpolated ID
prefix (`asset.tile.`), a dump key an identifier bridges to (`undoNameKey` → `name`) — selects nothing by itself; a
type's header line / one-line stored property changed along with other members of that type is covered by them. `scripts/test_ui_select.py`
(run by `scripts/test.sh`) keeps the selector honest; stage 2 / the batch gate still run every script.

**Load-independent tests (DX-C).** Every suite must pass with `--no-retry` on a machine loaded by other gates or CPU
hogs; a quiet machine is never assumed. So:
- **Budgets in CPU / GPU time, wall clock only in the perf gate.** A cost measurable as thread CPU time
  (`TimingBudget.threadCPUms`) or GPU command-buffer time keeps a gross bound in every run: `TimingBudget.cpuLimit(budget)`
  (× 4, `MONTAGE_CPU_TIMING_FACTOR`). `TimingBudget.limit(budget, what)` (wall clock) returns nil — nothing asserted —
  except in perf runs (`MONTAGE_PERF=1`: `scripts/perf.sh`, which holds every slot, or
  `scripts/test.sh --perf`; `MONTAGE_TIMING_ASSERT=1` forces it). Emit the measurement with
  `TimingBudget.metric("unit_…", value, "ms")`, add the test to `UNIT_TIMING` in `scripts/perf.sh` (a failed timing test
  there is a perf violation; it runs even with `--no-smoke`) and the precise budget to `bench/perf_thresholds.json`.
  `scripts/check_clean.sh --ui` runs `perf.sh --no-smoke` with the exclusive slot, after its concurrent unit + UI phases
  and after releasing its own slot (perf.sh queues for every slot), so the batch gate checks them.
- **perf.sh load rule.** Taking every slot does not stop load from outside the slot system (VMs, other builds), so
  wall-clock and GPU-time metrics (`launch_ms`, timeline / asset `_wall_` / `_gpu_` numbers, the unit tests' wall-clock
  and strict GPU budgets) gate only when the 1-min load average stays ≤ the core count across the measurement (sampled
  before / after each part, max taken; `MONTAGE_PERF_CORES` overrides the core count, also for TimingBudget). Above it,
  perf.sh waits ≤ 5 min and measures once more; if still loaded it reports each as `UNRELIABLE (load X > cores Y)` with
  its value and does not gate on them; check_clean prints "perf: N metrics unverified due to load" and appends
  `perf-unverified=N` to `build/check_clean.ok`. Thread-CPU (`_cpu_`) metrics follow the same rule (they inflate 3-4×
  above load = cores; owner decision 2026-10-22). Memory and the gross ×4 GPU-time bounds always gate. `launch_ms` is measured after one untimed warm-up launch (app launch, not the first launch after a build).
- **Waits are for state, timeouts only detect hangs.** Await the job / poll a condition (`waitUntil`, `job.value`); a
  timeout must be generous (≥ 30 s for anything that can queue behind other work) and never encode a speed budget.
  Freeze / deadlock checks measure *work*, not wall time: e.g. `PlaybackStressTests` calls a preview frozen when no new
  frame arrives while the video pipeline does no work (no composition request, nothing composed) for 4 s — a slow,
  loaded pipeline still works — or after 30 s without a frame at all. The exporter itself restarts a pass that read
  nothing and composed nothing for 30 s (an AVFoundation stall seen under load), once, then fails it ("export
  stalled") — a stalled export never hangs a test (`MONTAGE_EXPORT_STALL_SECONDS`).
- **UI scripts** (§1): `expect` is re-checked until it holds (≤ 10 s), `waitFor` timeouts are at least 30 s and count
  from the last observed progress (job progress, the waited value), mouse
  targets are awaited (≤ 10 s), every input step waits for the UI to settle (below), animations are off, snapshots wait
  for stable pixels. Don't add `wait` steps to "let things settle": `waitFor` the state, or rely on the above.

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
**Open the PNGs and look at them.** Exit code 0 = pass (3 = skipped; `uitest.sh` exits 1 if any script failed or timed out twice and is not quarantined). `MONTAGE_UITEST_DEBUG=1` logs every event and its hit view.

Examples (copy one): `split_undo`, `trim_undo`, `drag_media_to_timeline`, `inspector_field`, `zoom_slider`, `swiftui_taps`, `language_fr`; per area: `timeline_edit` (move, ⌫, W, magnet), `canvas_drag` (select + drag on the preview), `inspector_tabs` (Scale + Speed fields), `audio_volume`, `text_add`, `ai_tts`.

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
  `"requires": {"minOS": 14}` SKIPS the whole script below that macOS major version (a feature that only exists there).
- **OS / environment conditions on a step** (macOS 13 support): `"minOS": 14` runs the step only on macOS 14+, `"maxOS": 13`
  only up to 13, `"ffmpeg": true|false` only when the FFmpeg sidecar is / isn't installed (MP3 export). A skipped step is
  logged `⏭` and reported `"skipped"`. Use them for **expected** differences only (an API that doesn't exist on the older
  system), asserting the older system's behaviour in a `maxOS` twin step, so the newer system's assertions stay intact —
  e.g. `ai_relight` (no depth model on 13), `f4_cl_smart_brush` (no instance segmentation on 13), `ai_enhance_quality`
  (VT super resolution is 26+).
  `MONTAGE_UITEST_OS_MAJOR=13` fakes the version to check a script's 13 branch on a newer host.
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
| any view's context menu (SwiftUI `.contextMenu`, AppKit `menu(for:)`) | `{"contextMenu": "id:asset.preset.0", "item": "adjust.preset.delete"}` (item: l10n key, title or NSMenuItem identifier, `a/b` for a submenu; the menu the hit view (or an ancestor) returns from `menu(for:)` is built and its item performed, never popped up) |
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
| VoiceOver label audit (SE-017) | `{"a11yAudit": "inspector", "max": 0}` — walks the real AX tree; fails when more than `max` buttons / checkboxes / sliders / images / fields have no spoken name; writes `<name>.a11y.json`. `"element": "id:switcher.popover"` audits only that element (its subtree, or the elements inside its frame); a scoped audit that finds nothing fails |
| setup shortcuts (not UI) | `{"seek": 2.5}` · `{"select": ["clip:main/0", "clip:1/0"]}` |
| perf / metric | see §3 |

After every input step the driver waits until all posted events were dispatched, `settle` seconds (default 0.25), then
until the UI is **quiescent**: the on-screen test-ID frames, edit revision, selection, tabs, toast, first responder and
app screen / modal unchanged over two main-loop round trips (≤ 10 s, counted as `quiesce_timeouts` in report.json
metrics when it never settles; `"settle": 0` skips this, for checks right after
dispatch such as a tooltip's pending delay). In UI tests SwiftUI animations and transitions are off (`uitestNoMotion()` at
every hosting root), so nothing is caught mid-fade.

**Load-independent waits** (a loaded machine only makes them take longer; the bounds only end a wait that never ends):
`expect` is re-checked every 50 ms until it holds, ≤ 10 s (`MONTAGE_UITEST_EXPECT_LIMIT`) — so assert the end state;
`"now": true` checks once, immediately (asserts whose point is immediacy: "hidden at once"), and an expect right after a
`"settle": 0` step is `now` by default. Each expect's wait is in report.json (`waitMs`, `expect_wait_ms_max`); uitest.sh
warns "slow expect" when one waited > 2 s although the UI had settled (a latency regression); `waitFor` uses
max(its `timeout`, 30 s) (`MONTAGE_UITEST_WAIT_FLOOR`) as a **no-progress** bound: it fails only when the condition
does not hold and none of the progress signals changed for that long — `ui.jobs` (progress / state), `ui.activeJobs`,
`ui.audioStage` (incl. `progress`), `ui.export.jobs`, `ui.models.progress`, the waited path's own value, plus the step's
`"progress": ["path", …]` — so an AI job a loaded machine makes 3× slower is waited for and a stuck one fails
(`MONTAGE_UITEST_WAIT_CEILING`, 1800 s, ends a wait whose signals never stop changing); before a click / drag / hover the UI is quiesced (a `waitFor`
can return before the layout its state change causes: the target's frame would be stale) and the target (`id:`,
`clip:`) is awaited until it resolves, ≤ 10 s; the quiescence check also renders the window (SwiftUI hit-tests
against what it last drew); an `id:` click is delivered exactly (UITestDriver `ClickProbe`) — when NSWindow
dispatches the press, the window is laid out and drawn and the element located again, and the press / release go to
where it is then (`click_retargets` in report.json when it moved after resolution: checking the frame only after
dispatch gave false "landed outside" misses for AppKit targets such as `id:timeline` and under load); an element not
on screen at that moment gets nothing and is clicked again when it is (`click_redeliveries`, ≤ 3; a dispatched press is
never repeated, an element rebuilt between press and release is a warning, `click_release_anomalies`); a `snapshot` is re-rendered until two consecutive renders are identical and, with a baseline,
it matches it, ≤ 30 s (`MONTAGE_UITEST_SNAPSHOT_LIMIT`, a hang bound; a real difference fails with the last diff, and so does a match
that never renders the same twice). A script FAILS when an export pass stalled (`Exporter.stallRestarts` moved).

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
- project switcher (P1): `titlebar.projectSwitcher`, `switcher.popover`, `switcher.search`, `switcher.row.<i>` (+`.newWindow` on hover),
  `switcher.newProject`, `switcher.home`, `switcher.empty`; state `app.switcher.{isOpen, query, selected, rows[{name, status
  (current/normal/otherWindow/offline), current}]}`. Fixtures: `home:3:heldelsewhere` (newest project held by a registered
  Montage-like pid), `home:N:offlinedrive` (also puts the oldest project on the disconnected drive)
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
  inspector `transition.duration(.field)`, `transition.param.<key>(.field)`, footer `transition.applyAll`; state `ui.transitionThumbsMissing` (on-screen tiles whose still
  is not rendered yet: `waitFor` 0 before a snapshot)
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
step or set the value via a setup step; right-click menus: the `contextMenu` step), NSOpenPanel/NSSavePanel, hover-only visuals that read the real cursor.
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
- **Machine-independent pixels.** The test process pins what changes pixels but not behaviour (`UITestDriver.prepareProcess`):
  overlay scroll bars (a Mac with a mouse, or a VM, has legacy 15 pt scrollers that narrow every scroll view) and the
  time zone `Europe/Paris` (`MONTAGE_UITEST_TZ`; the Home / switcher dates come from a fixed UTC clock). On a non-Retina
  display (the macOS 13 VM is 1x) an element crop gets the size the Retina path would give (no ±1 px size mismatch).
- **Per-OS baselines (macOS 13).** `app/Tests/Baselines/macos<N>/<name>.png`, when it exists, replaces `<name>.png` on
  macOS N only, so the host gate never sees it. Use it for rendering-only differences of the older system (text
  rasterised at 1x in the VM, native slider / segmented control / link-button looks, inactive-window tints, a missing
  newer-OS-only card) — never for a layout bug (fix it) or a behaviour difference (`minOS` / `maxOS` steps). Record them
  in the macOS 13 VM: run the script with `--update-baselines --baselines <copy of Baselines>`, LOOK at each PNG next to the
  host baseline, copy only the snapshots that fail on 13 into `Baselines/macos13/`. Against such a baseline the tolerance
  is at least 1 % (1x text shifts by a sub-pixel from run to run: 0.7 % measured). Inventory and reasons: STATUS.md
  ("macOS 13 UI results").

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
