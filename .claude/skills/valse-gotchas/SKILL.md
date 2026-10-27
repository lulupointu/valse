---
name: valse-gotchas
description: Known Valse engineering traps by topic (async tests and AVFoundation pool deadlock, playback/seek freezes, composition timing, Perception on macOS 13, Intel Float16, UI test driver/a11yAudit quirks, session locks, background jobs and quit, colour/HDR, inspector multi-select, tooltips, l10n, memory/re-render). Use before writing tests or code touching media, playback, async, SwiftUI state, persistence or the UI test driver, and when a test hangs or flakes. Distilled from docs/STATUS.md "Engineering gotchas" - read that section only for more detail.
---

# Valse gotchas (1-3 lines each; source: docs/STATUS.md "Engineering gotchas", docs/ARCHITECTURE.md)

## Async tests, AVFoundation, load
- **Cooperative-pool deadlock**: blocking AVFoundation reads (`copyNextSampleBuffer`, `AudioFileIO.read`, semaphores
  around async loads) inside `async` tests exhaust Swift's pool when ~10 overlap → whole suite hangs at 0 % CPU (only
  under the full parallel suite). Do blocking media work through `OffPool.run` / `await OffPool.next(output)`
  (ValseEngine/Media/OffPool.swift: its own threads), in tests too. Stress tests: ValseAITests/BlockingReadStressTests,
  ValseEngineTests/EncoderLoadStressTests (opt-in `VALSE_ENCODER_STRESS=<n>`).
  A watchdog for such a hang needs its own `Thread` (GCD gets no new workers either). No in-process `OSLogStore` enumeration.
- **GCD soft limit (64 threads)**: blocking reads parked on GCD plus export pumps reach "Dispatch Thread Soft Limit 64" →
  AVFoundation gets no workers, process hangs (FLAKY-SYS-UNIT). Never park blocking calls on `DispatchQueue.global()`;
  exports / reverse renders go through `ExportGate` (≤ cores/2 each, `VALSE_EXPORT_CONCURRENCY`).
- **Writers under load**: AVAssetWriter adaptor pools vanish and HEVC VideoToolbox fails transiently (-12902) when the
  machine is busy: allocate frames from your own CVPixelBufferPool, throw the writer's real error, retry transient VT codes
  (Export/VideoToolboxErrors.swift); never spin on `isReadyForMoreMediaData` of a failed writer.
- **Shared test-media cache**: write to a temp file + atomic rename, regenerate empty files, check ffmpeg's exit status;
  never write in place (a 0-byte cached movie crashes every later run).
- Heavy work from main-actor code/tests starves PlaybackTests: run it `Task.detached`.
- ML jobs via `JobQueue` pass `heavy: true` (runs inside `HeavyWorkGate`, ValseEngine/Jobs/). Tests await the task a
  store flow returns (`setCutout`, `autoBeats`) instead of polling with a time budget.
- No wall-clock asserts in correctness tests: `TimingBudget.limit` returns nil (nothing asserted) unless `VALSE_PERF=1`
  (scripts/perf.sh, `scripts/test.sh --perf`). Emit `TimingBudget.metric(...)`, add the test to perf.sh's `UNIT_TIMING` and
  the budget to bench/perf_thresholds.json (wall-clock budgets gate only while load ≤ cores, run-gates skill). Freeze/deadlock checks measure work (no frame while nothing is composed), not time.
- Tests run in a private TMPDIR deleted on exit: caches that must survive go to `VALSE_TEST_MEDIA_DIR` / `ValsePaths`
  (unit tests: `ValsePaths.testRunCacheDirectory`), never `FileManager.default.temporaryDirectory`.
- **L10n in tests**: never flip `L10n.shared`'s language from a test that runs off the main actor (main-actor UI suites
  read it concurrently: stale / partial tables, DX-L). Use a private instance `L10n(bundles: [CoreResources.bundle],
  language: "fr")` (see LocalizationTests, L10nConcurrencyTests). L10n swaps language + tables atomically (one State).
- **Export cancel / AVAssetReader**: never call `cancelReading` while a pump may be inside `copyNextSampleBuffer`
  (use-after-free crash under load). Cancel handlers / stall monitors only `ReaderCancel.request()`; the pumps stop at
  the next sample; a cancelled export whose read is stuck is PARKED (`ParkedReaders`) and cancelled + released only after
  its pumps return (ValseEngine/Export/ReaderCancel.swift, Exporter.swift). Keep this for any new reader loop.
- Use `RealLikeMedia` (iPhone HEVC HLG portrait, speech, 120 BPM music) for media features, not only testsrc: rotation,
  10-bit HLG and 44.1 kHz AAC are what real footage breaks.

## Playback, composition, audio
- Never seek `PlaybackEngine.player` directly while playing: use `seek` / `performSeek`; start with `resume(atRate:)`
  (seeking with the clock running froze the preview). Stress: ValseEngineTests/PlaybackStressTests.swift.
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
  (ValseUI/Support/Compat13.swift). A miss is silent on 13 (view stops updating); debug builds report "not being tracked".
- macOS 14+ APIs behind `if #available(macOS 14, *)` with the 13 fallback next to it (Compat13.swift).
- macOS 13: `.onChange(of: text)` can miss a keystroke during a re-render → commit debounced queries from the
  TextField binding's setter (`AssetSearchField`, ValseUI/AssetPanel/Library/LibraryBrowser.swift).
- SF Symbols newer than SF Symbols 4 render as nothing on 13: `python3 scripts/check_sf_symbols.py`.
- `Float16` does not exist on x86_64: use `Half` (ValseCore/Render/Half.swift) behind `#if arch(arm64)`;
  verify with `scripts/test_x86.sh --filter X`.
- Always-visible views read store slices (`store.mediaBin`, `store.usedMediaIDs`), never `store.project` (re-render storm);
  new panels live in their own `IsolatedHost` (ValseUI/Shell/IsolatedHost.swift).
- **Swift -O miscompile (6.3.3)**: in a task-group child, `do { return (i, .success(try await f())) } catch { return (i, .failure(e)) }`
  returned i = 0 from every child in release builds only (debug fine) → build the `Result` first, `return (i, r)` after the
  do/catch (OnlineAudioState.load). Host UI gates run debug: check such code with `scripts/uitest.sh --release`.

## UI test driver
- Keys while a text field edits go straight to the window, bypassing the app key monitor: fields needing ↑ ↓ Return Esc
  handle them in the field (`control(_:textView:doCommandBy:)`, `SwitcherSearchField` in ValseUI/Home/ProjectSwitcher.swift).
- `a11yAudit`: AppKit leaves windows off the active Space out of AXWindows ("AXWindows empty" → in-process fallback,
  which misses SwiftUI Menu names: FLAKY-UI3). The test window joins all Spaces and `UITestApplication` lists the
  visible windows when AppKit's list is empty; the step re-reads ≤ 12 s (UITestDriver.swift, Testing/AccessibilityAuditAX.swift). Audit with the step, never by
  walking NSView accessibility children (SwiftUI builds its AX tree only for real AX clients).
- Text clip editor (ValseUI/Text/RichTextEditor.swift): typing is ONE gesture `cmd.text` (each keystroke updates it);
  it is committed to undo only after 900 ms without typing, or when editing ends. A script that types then checks
  `undo.name` / `undo.depth` must `waitFor` them (or `undo.inGesture` false), never `expect` right after the `type`.
- Tooltips: `.help(tr(…))` inside ValseUI is Valse's own tooltip (Support/Tooltips.swift); don't set AppKit `toolTip`.
  Owner policy (FB-10): only on symbol-only controls or when the visible text is not clear on its own (explains an
  action, full truncated path / file name); never a tooltip that repeats the visible label (`.help("")` = none).
- In-window modals (Settings, dialogs, export / crop / cover / recorder) put `.modalHoverShield()` on their card: views
  underneath then must not change the cursor; set cursors with `NSCursor.setUnlessCovered(at:in:)` or guard hover
  handlers with `ModalHoverGate.isBlocked` (FB-07, Support/ModalHoverGate.swift).
- UI tests are environment-independent: AI models sandboxed (`requires.models` else SKIP), fixed cache sizes / clock,
  overlay scroll bars, Europe/Paris TZ. Tests never make sound (`VALSE_MUTE_AUDIO=1`, `AudioOutput.isSilenced`).

## Persistence, jobs, editing
- Session locks: only a live Valse process holds `.session.lock` (`SessionLock.isValseHolder`,
  ValseCore/Persistence/Autosave.swift); tests faking "open elsewhere" call `SessionLock.registerTestHolder(pid)`.
- New background work goes through `JobQueue` (or checks `Task.isCancelled`): quit / end of a UI test runs
  `AppShutdown.stopBackgroundWork()` (ValseUI/AI/AppShutdown.swift); exiting under live Core ML/Metal crashed in MPSGraph.
- `EditSession.postProcess` runs after every command and gesture tick: keep additions cheap (`CaptionStyleSync`).
- Transcript ripple cuts move caption tracks themselves: don't also shift captions by linkage.
- Inspector writes go through `Bind.apply` / `ClipParamRow` / `store.performInspector(...)` so they apply to every selected
  same-kind clip; single-clip sections → `InspectorMultiEdit.singleOnlyIDs`. Row commit closures must start from the
  CURRENT value, not one captured at render time (transition Softness reset Duration).
- Render passes recycle dead inputs (`scratch.recycle`, `FrameScratch` in ValseEngine/Render/FrameRenderer.swift);
  caches size from `MemoryBudget`.
- l10n: no hard-coded UI strings, `Text("literal")` banned (use `tr("key")`, `Text(loc:)`, `Text(verbatim:)` for data);
  one `.strings` table per feature in en + fr (French register "vous", glossary UX.md §10); `scripts/l10n_check.py`.
