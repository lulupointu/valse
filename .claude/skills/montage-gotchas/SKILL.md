---
name: montage-gotchas
description: Known Montage engineering traps by topic (async tests and AVFoundation pool deadlock, playback/seek freezes, composition timing, Perception on macOS 13, Intel Float16, UI test driver/a11yAudit quirks, session locks, background jobs and quit, colour/HDR, inspector multi-select, tooltips, l10n, memory/re-render). Use before writing tests or code touching media, playback, async, SwiftUI state, persistence or the UI test driver, and when a test hangs or flakes. Distilled from docs/STATUS.md "Engineering gotchas" - read that section only for more detail.
---

# Montage gotchas (1-3 lines each; source: docs/STATUS.md "Engineering gotchas", docs/ARCHITECTURE.md)

## Async tests, AVFoundation, load
- **Cooperative-pool deadlock**: blocking AVFoundation reads (`copyNextSampleBuffer`, `AudioFileIO.read`, semaphores
  around async loads) inside `async` tests exhaust Swift's pool when ~10 overlap → whole suite hangs at 0 % CPU (only
  under the full parallel suite). Do blocking media work through `OffPool.run` / `await OffPool.next(output)`
  (MontageEngine/Media/OffPool.swift: its own threads), in tests too. Stress tests: MontageAITests/BlockingReadStressTests,
  MontageEngineTests/EncoderLoadStressTests (opt-in `MONTAGE_ENCODER_STRESS=<n>`).
  A watchdog for such a hang needs its own `Thread` (GCD gets no new workers either). No in-process `OSLogStore` enumeration.
- **GCD soft limit (64 threads)**: blocking reads parked on GCD plus export pumps reach "Dispatch Thread Soft Limit 64" →
  AVFoundation gets no workers, process hangs (FLAKY-SYS-UNIT). Never park blocking calls on `DispatchQueue.global()`;
  exports / reverse renders go through `ExportGate` (≤ cores/2 each, `MONTAGE_EXPORT_CONCURRENCY`).
- **Writers under load**: AVAssetWriter adaptor pools vanish and HEVC VideoToolbox fails transiently (-12902) when the
  machine is busy: allocate frames from your own CVPixelBufferPool, throw the writer's real error, retry transient VT codes
  (Export/VideoToolboxErrors.swift); never spin on `isReadyForMoreMediaData` of a failed writer.
- **Shared test-media cache**: write to a temp file + atomic rename, regenerate empty files, check ffmpeg's exit status;
  never write in place (a 0-byte cached movie crashes every later run).
- Heavy work from main-actor code/tests starves PlaybackTests: run it `Task.detached`.
- ML jobs via `JobQueue` pass `heavy: true` (runs inside `HeavyWorkGate`, MontageEngine/Jobs/). Tests await the task a
  store flow returns (`setCutout`, `autoBeats`) instead of polling with a time budget.
- No wall-clock asserts in correctness tests: `TimingBudget.limit` returns nil (nothing asserted) unless `MONTAGE_PERF=1`
  (scripts/perf.sh, `scripts/test.sh --perf`). Emit `TimingBudget.metric(...)`, add the test to perf.sh's `UNIT_TIMING` and
  the budget to bench/perf_thresholds.json (wall-clock budgets gate only while load ≤ cores, run-gates skill). Freeze/deadlock checks measure work (no frame while nothing is composed), not time.
- Tests run in a private TMPDIR deleted on exit: caches that must survive go to `MONTAGE_TEST_MEDIA_DIR` / `MontagePaths`
  (unit tests: `MontagePaths.testRunCacheDirectory`), never `FileManager.default.temporaryDirectory`.
- **L10n in tests**: never flip `L10n.shared`'s language from a test that runs off the main actor (main-actor UI suites
  read it concurrently: stale / partial tables, DX-L). Use a private instance `L10n(bundles: [CoreResources.bundle],
  language: "fr")` (see LocalizationTests, L10nConcurrencyTests). L10n swaps language + tables atomically (one State).
- **Export cancel / AVAssetReader**: never call `cancelReading` while a pump may be inside `copyNextSampleBuffer`
  (use-after-free crash under load). Cancel handlers / stall monitors only `ReaderCancel.request()`; the pumps stop at
  the next sample; a cancelled export whose read is stuck is PARKED (`ParkedReaders`) and cancelled + released only after
  its pumps return (MontageEngine/Export/ReaderCancel.swift, Exporter.swift). Keep this for any new reader loop.
- Use `RealLikeMedia` (iPhone HEVC HLG portrait, speech, 120 BPM music) for media features, not only testsrc: rotation,
  10-bit HLG and 44.1 kHz AAC are what real footage breaks.

## Playback, composition, audio
- Never seek `PlaybackEngine.player` directly while playing: use `seek` / `performSeek`; start with `resume(atRate:)`
  (seeking with the clock running froze the preview). Stress: MontageEngineTests/PlaybackStressTests.swift.
- Never `scaleTimeRange` a composition track to an arbitrary duration: reads inside stretched samples can stall forever
  (`CompositionBuilder.addBase` tiles a 60 s blank unscaled).
- Never use `AVAudioTimePitchAlgorithm.varispeed`: hangs the audio reader during export of sped-up clips.
- MP3 export needs the FFmpeg sidecar (libmp3lame), absent on a fresh Mac: option disabled with a hint; audio format only
  matters when audio is exported.
- `AVVideoCompositing` must keep `canConformColorOfSourceFrames = true`: without it AVFoundation converts + retags source
  frames to a common space (mixed HDR+SDR → SDR frames arrive as HLG) and the renderer converts them twice. "Correct"
  colour = Apple's rendering (Core Image EDR / AVAssetImageGenerator) matches the original: `ColorScience.appleDisplay`;
  Apple shows Rec.709 video as v^1.961, not 2.4 (BUG-SDR-IN-HDR).
- Generated media keeps the source colour: copy primaries / transfer / matrix (`AVVideoColorPropertiesKey`); HDR = HEVC
  Main10 with 10-bit buffers carrying the same attachments. SDR stats → `ColorLooks.inProjectSpace` before HDR use.
  Vision on portrait iPhone footage: pass `SubjectAnalyzer.orientation(asset.sourceRotation)`, map back to raw.

## SwiftUI state, macOS 13, Intel
- **Perception** (swift-perception, macOS 13 target): every `body` reading perceptible state is wrapped in
  `WithPerceptionTracking { }`, and so is every escaping view-builder closure (ForEach rows, GeometryReader, List rows,
  sheet/popover content). Custom Bindings: `Binding.perceived(get:set:)`; representables: `RepresentableTracking`
  (MontageUI/Support/Compat13.swift). A miss is silent on 13 (view stops updating); debug builds report "not being tracked".
- macOS 14+ APIs behind `if #available(macOS 14, *)` with the 13 fallback next to it (Compat13.swift).
- macOS 13: `.onChange(of: text)` can miss a keystroke during a re-render → commit debounced queries from the
  TextField binding's setter (`AssetSearchField`, MontageUI/AssetPanel/Library/LibraryBrowser.swift).
- SF Symbols newer than SF Symbols 4 render as nothing on 13: `python3 scripts/check_sf_symbols.py`.
- `Float16` does not exist on x86_64: use `Half` (MontageCore/Render/Half.swift) behind `#if arch(arm64)`;
  verify with `scripts/test_x86.sh --filter X`.
- Always-visible views read store slices (`store.mediaBin`, `store.usedMediaIDs`), never `store.project` (re-render storm);
  new panels live in their own `IsolatedHost` (MontageUI/Shell/IsolatedHost.swift).

## UI test driver
- Keys while a text field edits go straight to the window, bypassing the app key monitor: fields needing ↑ ↓ Return Esc
  handle them in the field (`control(_:textView:doCommandBy:)`, `SwitcherSearchField` in MontageUI/Home/ProjectSwitcher.swift).
- `a11yAudit`: AppKit leaves windows off the active Space out of AXWindows ("AXWindows empty" → in-process fallback,
  which misses SwiftUI Menu names: FLAKY-UI3). The test window joins all Spaces and `UITestApplication` lists the
  visible windows when AppKit's list is empty; the step re-reads ≤ 12 s (UITestDriver.swift, Testing/AccessibilityAuditAX.swift). Audit with the step, never by
  walking NSView accessibility children (SwiftUI builds its AX tree only for real AX clients).
- Text clip editor (MontageUI/Text/RichTextEditor.swift): typing is ONE gesture `cmd.text` (each keystroke updates it);
  it is committed to undo only after 900 ms without typing, or when editing ends. A script that types then checks
  `undo.name` / `undo.depth` must `waitFor` them (or `undo.inGesture` false), never `expect` right after the `type`.
- Tooltips: `.help(tr(…))` inside MontageUI is Montage's own tooltip (Support/Tooltips.swift); don't set AppKit `toolTip`.
  Owner policy (FB-10): only on symbol-only controls or when the visible text is not clear on its own (explains an
  action, full truncated path / file name); never a tooltip that repeats the visible label (`.help("")` = none).
- In-window modals (Settings, dialogs, export / crop / cover / recorder) put `.modalHoverShield()` on their card: views
  underneath then must not change the cursor; set cursors with `NSCursor.setUnlessCovered(at:in:)` or guard hover
  handlers with `ModalHoverGate.isBlocked` (FB-07, Support/ModalHoverGate.swift).
- UI tests are environment-independent: AI models sandboxed (`requires.models` else SKIP), fixed cache sizes / clock,
  overlay scroll bars, Europe/Paris TZ. Tests never make sound (`MONTAGE_MUTE_AUDIO=1`, `AudioOutput.isSilenced`).

## Persistence, jobs, editing
- Session locks: only a live Montage process holds `.session.lock` (`SessionLock.isMontageHolder`,
  MontageCore/Persistence/Autosave.swift); tests faking "open elsewhere" call `SessionLock.registerTestHolder(pid)`.
- New background work goes through `JobQueue` (or checks `Task.isCancelled`): quit / end of a UI test runs
  `AppShutdown.stopBackgroundWork()` (MontageUI/AI/AppShutdown.swift); exiting under live Core ML/Metal crashed in MPSGraph.
- `EditSession.postProcess` runs after every command and gesture tick: keep additions cheap (`CaptionStyleSync`).
- Transcript ripple cuts move caption tracks themselves: don't also shift captions by linkage.
- Inspector writes go through `Bind.apply` / `ClipParamRow` / `store.performInspector(...)` so they apply to every selected
  same-kind clip; single-clip sections → `InspectorMultiEdit.singleOnlyIDs`. Row commit closures must start from the
  CURRENT value, not one captured at render time (transition Softness reset Duration).
- Render passes recycle dead inputs (`scratch.recycle`, `FrameScratch` in MontageEngine/Render/FrameRenderer.swift);
  caches size from `MemoryBudget`.
- l10n: no hard-coded UI strings, `Text("literal")` banned (use `tr("key")`, `Text(loc:)`, `Text(verbatim:)` for data);
  one `.strings` table per feature in en + fr (French register "vous", glossary UX.md §10); `scripts/l10n_check.py`.
