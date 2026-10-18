# ARCHITECTURE.md — Montage

Read before coding (BRIEF.md rule). Covers the foundation in `app/` (SwiftPM package rooted at the repo's `Package.swift`).
The prototypes in `prototypes/` are reference only. If you change a contract described here, update this file in the same commit.

## 1. Modules and dependencies

```
MontageCore  ◀── MontageEffects ◀── MontageEngine ◀── MontageAI
     ▲                ▲                  ▲                ▲
     └────────────────┴──────── MontageUI ┘────────────────┘ ◀── MontageApp (executable "Montage")
MontageTestSupport → Core, Effects, Engine          (test helpers, never linked into the app)
```

| Module | Path | Owns | May import |
|---|---|---|---|
| **MontageCore** | `app/Sources/MontageCore` | Time, model (Project/Timeline/Track/Clip), keyframes & easing, speed & time remap, `TimelineOps`, commands + `EditSession` (undo), persistence (`.montage`, migrations, session lock, paths), `FrameEvaluator` → `FrameDescription`, `LayerGeometry`, `L10n` | Foundation only (no AVFoundation/Metal/AppKit) |
| **MontageEffects** | `app/Sources/MontageEffects` | Content registries (`Registries.effects/transitions/animations/stickers/textStyles`), descriptors, MSL prelude, built-in reference content | Core |
| **MontageEngine** | `app/Sources/MontageEngine` | Metal context & texture pool, `FrameRenderer` (THE compositor), `MontageCompositor` (AVVideoCompositing), `CompositionBuilder`, `PlaybackEngine`, `Exporter`, `MediaProbe`, `ProxyManager`, `ThumbnailCache`, `WaveformCache`, `JobQueue`, `MemoryBudget`, `SyntheticMedia`, `OfflineRenderer` | Core, Effects, AVFoundation, Metal, VideoToolbox, CoreText. **No AppKit/SwiftUI.** |
| **MontageAI** | `app/Sources/MontageAI` | `AIToolDescriptor` + `AIRegistry`, Vision `PersonSegmenter`, `Transcriber` (SpeechAnalyzer → SFSpeech → whisper.cpp pack), built-in tools | Core, Engine, Vision, Speech |
| **MontageUI** | `app/Sources/MontageUI` | `EditorStore`, theme, shell, asset panel, player view, inspector, timeline canvas, export sheet, shortcuts, UI registries, snapshots, demo project | everything above, SwiftUI, AppKit |
| **MontageApp** | `app/Sources/MontageApp` | `main.swift`: NSApplication, window, menu bar, CLI options | UI |

Swift 6 language mode everywhere. UI and App use `defaultIsolation(MainActor)`. Core, Effects, Engine and AI are nonisolated by default.

## 2. Data model (MontageCore/Model)

- `Project` (value type, Codable, Equatable): `schemaVersion`, `id`, `name`, `settings` (canvas size, `FrameRate`, background, aspect preset), `media: [MediaAsset]` (the bin), `timeline`.
- `MediaAsset`: url plus a relative path (for relinking), probed metadata (duration, display pixel size, fps, rotation, codec) and **`contentHash`** (size + mtime + head/tail SHA-256). The hash keys every cache.
- `Timeline`: `tracks` in **compositing order, bottom → top** (audio tracks are ignored by the compositor), and the `mainTrackMagnet` / `linkage` / `snapping` flags, plus `markers`. There is exactly one main track (`isMain`).
- `Track`: `kind` (video, audio, text, sticker, effect, filter, adjustment), mute/hide/lock flags, and `clips` sorted by start with no overlaps. The one exception: main-track neighbours joined by a transition overlap by the transition duration.
- `Clip`: `content` (`.media(MediaID)`, `.text`, `.solid`, `.sticker(id)` or `.adjustment`), `start`/`duration` (timeline), `sourceStart` (media), `speed`, `reversed`, `transform` (canvas-normalized; scale 1 = aspect-fit), `opacity`, `blendMode` (13 modes), `crop`, `mask`, `effects: [EffectInstance]` (registry id + params, defaults filled on creation), `transitionOut`, `animations` (in/out/combo), `audio` (gain, fades, pitch), `keyframes: [ParamKey.raw: KeyframeTrack]`, `linkedTo`.
- **Animatable properties**: `ParamKey` strings. Built-ins are listed in `AnimatableProperties.all` (position, scale, rotation, opacity, volume, mask…). Effect parameters are animatable automatically through `ParamKey.effect(instanceID, param)`. `clip.resolved(at:)` returns a copy with every keyframed value applied. Renderer, inspector and audio mix all read resolved values. CapCut semantics: `setValue` adds or updates a keyframe at the playhead if the property has keyframes, otherwise it edits the static value.
- **Easing**: linear, hold, easeIn/Out/InOut and CSS cubic-bezier (`Easing.bezier`), solved by `CubicBezier`.

## 3. Time model

- `Time` = Int64 **flicks** (1/705,600,000 s). Every common frame rate and sample rate divides it exactly, so edits never drift. It converts losslessly to `CMTime` (timescale 705,600,000) with `Time(cmTime:)` and `.cmTime`.
- `FrameRate` is rational (30000/1001…) and provides `frame(containing:)`, `time(ofFrame:)` and `snap`. `TimeRange` is half-open.
- Clip-local time = timeline time − `clip.start`. Keyframe times are clip-local.
- **Speed / time remap** (`Speed`): `.constant(v)` or `.curve(SpeedCurve)`. A curve is piecewise-linear speed over normalized output x ∈ [0,1]. Source offset = D·∫₀ˣ v (exact). `sourceDuration(forOutput:)` and `outputDuration(forSource:)` follow from it, and changing speed keeps the source extent (the clip changes length). The AVComposition uses `Speed.frameAccurateSegments`: piecewise-linear chords whose boundaries sit on the build's output frame grid, grown greedily while every composed frame lands in the **same source frame** as the exact integral (constant speed = 1 segment, curves = a few dozen). Audio is inserted with the same segments, so it follows the identical remap. Splitting a curve clip uses `SpeedCurve.subcurve`, which preserves the source extent. **Reverse** (`reversed`): `ReverseManager` renders the media backwards once in the background (`Caches/Montage/reversed/<hash>.mov`, H.264 GOP 15 + reversed 16-bit LPCM, chunked so memory stays bounded); the builder then plays that file forwards from the mirrored in-point `D − sourceStart − sourceDuration` with the same remap (frame exact, audio reversed). Preview falls back to forwards until it is ready (progress shows on the clip); export waits for it.

## 4. Rendering pipeline: one Metal compositor for everything

```
Project ──FrameEvaluator(t)──▶ FrameDescription (pure, Sendable)
                                   │  layers / transitions / adjustment layers, keyframes resolved,
                                   │  animation progress, source times
CVPixelBuffers (decoder) ─────────┐ ▼
                                 FrameRenderer.encode(frame, sources, output)   ← Metal, rgba16Float working space
                                   ▲
   preview: AVPlayer → MontageCompositor (AVVideoCompositing) ─┐
   export:  AVAssetReaderVideoCompositionOutput → MontageCompositor ─┤ same code path ⇒ identical pixels
   thumbnails/tests: AVAssetImageGenerator → MontageCompositor ─┘
   paused edits: PlaybackEngine.renderCurrentFrame (last decoded sources, no decode)
```

- `CompositionBuilder` turns a project into an `AVMutableComposition`: one composition track per timeline track that has video media, and two for the main track (A/B lanes for transition overlaps). Each speed segment is inserted and then `scaleTimeRange`d. The same is done for audio, plus an `AVAudioMix` (gain, fades and volume keyframes become ramps, and the pitch algorithm is chosen per lane). A 1 s black base track scaled to the timeline length keeps text-only regions rendering. There is **one instruction** for the whole timeline, and it carries a shared `RenderState` (latest project, clip→track map, recent decoded sources).
- `FrameRenderer` steps, all on pooled textures:
  1. Per layer: source → straight RGBA at the displayed resolution. This covers YUV 8/10-bit or BGRA, crop, flip and rotation (`uvTransform`). The size is capped by the source resolution and quantized to 16 px.
  2. The effect stack, as ping-pong passes, with one Metal library per effect.
  3. Placement onto the premultiplied accumulation texture (cleared to the background): transform quad, opacity, mask (linear/mirror/circle/rectangle with feather/invert/roundness) and blend mode. Blending is programmable via **framebuffer fetch**, which Apple-silicon GPUs support.
  4. Transitions render both sides to canvas-size textures, run the transition shader and composite with premultiplied-over.
  5. Adjustment clips unpremultiply → effects → premultiply → mix by opacity.
  6. An output pass writes BGRA8.

  Animations (registry closures) adjust transform/opacity before placement. Text and emoji stickers are rasterized with Core Text (`TextRasterizer`, LRU cache keyed by content and pixel size). Still images come through `ImageTextureCache`.
- Shaders are compiled from source at runtime (the offline Metal toolchain is an optional Xcode download). Core passes live in `Engine/Metal/CoreShaders.swift`. Effect and transition sources are compiled lazily and separately, so **a broken effect only disables itself** (`EffectPipelines.validateAll()` is tested).
- Colour: `ProjectSettings.colorSpace` (SDR Rec.709 default, HDR Rec.2020 HLG/PQ). Working values are encoded in the project space (rgba16Float). The convert pass turns each source into it from the asset's probed tags (`MediaAsset.transferFunction/colorPrimaries/yCbCrMatrix`; buffer attachments are NOT trusted: AVFoundation stamps frames with the composition tags) using `ColorMath` (Core, CPU mirror of the MSL; linear 1.0 = 203-nit reference white; HDR→SDR via a hue-preserving soft shoulder). Solids/text/background are SDR and converted too. Compositors declare `supportsHDRSourceFrames`, so preview and export convert identically. SDR projects compose into BGRA8 (`MontageCompositor`); HDR projects into 64RGBAHalf (`MontageHDRCompositor`) and export as HEVC Main10 (H.264 is upgraded, `ExportSettings.effectiveCodec`) or ProRes, with Rec.2020 + HLG/PQ tags (`ColorTags`). No EDR preview yet.

### 4.1 Per-layer features, aux lanes, nested timelines, render cache (W6/W9)

- **Aux lanes**: a clip can ask the composition for extra decoded frames in sync with its main lane — same output layout and remap, shifted source or another file (`AuxRole`: `.nextFrame` for smooth slow-mo, `.previousFrame(k)` for motion blur, `.matte` for AI mattes). `RenderState.auxMap` maps clip → role → track; `FrameSourceProvider.auxPixelBuffer` hands them to the renderer. Each lane is one more hardware decoder (counted by `DecoderBudget`).
- `FrameRenderer.applyLayerFeatures` runs right after source conversion, before the effect stack: frame blending (weight `LayerDescription.frameBlend` = fractional source-frame position; `.opticalFlow` calls `FrameInterpolation.provider` when MontageAI installs one), motion-blur accumulation, **chroma key** (`Clip.chromaKey`: luma-normalised CbCr distance, strength, shadow, feather, clean-up, despill), **AI matte** (`Clip.matte`: grey matte video from `MatteStore`/`MatteVideoWriter`, aligned with media time and the decoded (raw) orientation, or a still for images; expand/feather/invert). **Stabilization** (`Clip.stabilization`) is a shift + zoom inside the source uv transform, from `StabilizationStore` (background block-matching analysis, smoothed per level). These passes live in `Metal/FeatureShaders.swift` (own library).
- **Blend modes**: 27 (13 originals + linear burn/dodge, vivid/linear/pin light, hard mix, subtract, divide, hue, saturation, color, luminosity, darker/lighter colour). Raw values are persisted and `allCases` index = shader index, so only ever append. **Masks**: linear, mirror, circle, rectangle, heart, star (SDFs, feather in layer units).
- **Compound clips** (`ClipContent.compound`, `Project.compounds`): `FrameEvaluator` evaluates the nested timeline at the clip's remapped time and emits `RenderItem.nested(container:items:)` with clip ids made unique by `nestedClipID(container, inner)`; the renderer composites the items on transparent and places the result as one layer with the compound's own transform/opacity/blend/mask/effects. `CompoundFlattening.decodeTracks` adds the nested media as retimed virtual tracks for the composition (video + audio). Depth ≤ 4.
- **Preview render cache** (`RenderCache`): requested ranges are exported (same compositor) to ProRes 422 at preview size, keyed by a SHA-256 of everything visible in the range. Preview builds add valid segments as passthrough lanes; `RenderState` re-validates keys on every project update, so stale segments are bypassed instantly and the compositor composes live. Export never uses it.

## 5. Playback clock & A/V sync

- `PlaybackEngine` (@MainActor) owns an `AVPlayer`. AVPlayer is the master clock, driven by the audio device. `PlayerView` (a CAMetalLayer) pulls the frame for each vsync with `pixelBuffer(forHostTime: displayLink.targetTimestamp)` (`AVPlayerItemVideoOutput.itemTime(forHostTime:)`) and presents it zero-copy. Video therefore follows audio, and a dropped frame never shifts the clock. J/K/L sets `rate` (reverse only if `canPlayReverse`).
- `update(project:)` runs after every edit. It compares a **structure key** (media clips, timing, speed, audio, sources, canvas, preview size):
  - When the key changes, the composition is rebuilt off-main (debounced 40 ms, builds serialized) and the item is swapped at the same time position.
  - When it doesn't change (opacity, transform, effects, text, masks…), there is no rebuild. The compositor reads the new project, and when paused `onRedrawNeeded` → `renderCurrentFrame` re-renders the last decoded frame within the same display refresh.
- Seeking: at most one seek in flight, and the latest request wins. While dragging, seeks are keyframe-tolerant (`exact: false`); on mouse-up an exact seek follows (STACK.md lesson 1).

### 5.1 Player canvas (W2, `MontageUI/Player`)

- `PlayerContainerView` = `PlayerView` (Metal) + `CanvasOverlayView` (transparent AppKit, flipped). The overlay owns the
  `PlayerViewport` (canvas px ↔ view pt, 16 pt padding, zoom/pan from `store.playerUI`) and pushes the frame rect to
  `PlayerView.contentRect` → `Presenter.encode(contentRect:)` (target-pixel rect, may exceed the target when zoomed).
- Pure geometry lives in `CanvasMath.swift` (`CanvasLayers.at` sizes text/stickers with `MontageEngine.TextMetrics`,
  which mirrors `TextRasterizer` layout — keep them in sync; `CanvasHandles`, `CanvasSnapper`, `CanvasDrag`, align/fit,
  safe zones). Canvas drags are store gestures (one undo step) using `Clip.setValue` (keyframe semantics).
- `PlayerUIState` (`store.playerUI`): zoom/pan, rulers/guides (session only), safe zone, loop, full screen,
  `editingTextClip` (inline `NSTextView` over the text layer; the engine keeps rendering the real text live), canvas focus
  (arrows nudge instead of stepping frames — `Shortcut.isEnabled` lets a binding fall through).
- Engine: `loopRange` (boundary observer + item-end), emulated reverse shuttle when `canPlayReverse` is false
  (`shuttleRate`), `previewHover(_:)` (show a frame without moving the playhead — for the timeline preview axis, TL-031),
  `usesProxies` toggle.
- Canvas background (CV-002) is W3's `Clip.canvas` (`FrameEvaluator.canvasItems`); its fill layers carry
  `LayerDescription.isCanvasBackground = true`, which `CanvasLayers` skips so clicks in the filled letterbox never select them.
- `--player-state <spec>` (see `PlayerDebugState`) puts the player in a state for screenshots.

## 6. Proxies, preview cache and the memory budget (8 GB)

- `ProxyManager`: background job (`JobQueue`, priority −1) per video that needs one. The **auto** policy: long side > 1920, or > 30 fps above 1280, or any > 1280 on ≤ 8 GB machines. Proxies are H.264, short side 720, GOP 10, no B-frames, video only, stored in `~/Library/Caches/Montage/proxies/<contentHash>.mp4`, and shared across projects.
- **Auto-switch**: `PlaybackEngine.sourceChooser` picks the proxy when it is ready. When a proxy finishes, `onProxyReady` → `forceRebuild()`. Export always uses originals. Proxy files carry the source rotation, and since the model works in normalized coordinates a proxy swap is invisible.
- `MemoryBudget`: decoder budget = 15 % of RAM (max 2 GB), costed at ~300 MB per 4K stream. It sets preview size (`PreviewQuality.auto`: 720p on ≤ 8 GB, 1080p otherwise; half/quarter manual), thumbnail cache size and proxy policy. Compositor work is bounded: 3 frames in flight and a texture pool. **Decoder limiter** (`DecoderBudget`): the peak simultaneous decode cost over the timeline (one stream per lane incl. aux lanes, at proxy size when proxied) is checked on every update; above the budget the heaviest originals get proxies queued (`PlaybackEngine.requestDerivedMedia`, which also queues reversed renders and stabilization analysis). Heavy segments can be pre-rendered with the render cache (§4.1).

### 6.1 Import breadth, conversion cache, FFmpeg sidecar, bin (W9)

- `MediaProbe` reads AVFoundation media (incl. ProRes 4444 / HEVC alpha, VFR, multiple audio streams → `MediaAsset.techInfo`) and
  ImageIO stills. Animated GIF/APNG/WebP/HEICS and numbered image sequences (`MediaProbe.detectSequences`: ≥ 10 contiguous frames,
  JPEG ≥ 24 and no camera prefix) become `.video` assets with `conversion` set. Anything AVFoundation can't open is probed with
  `ffprobe` (`conversion = .ffmpeg`).
- `PlayableMediaCache` converts those once (JobQueue, priority 1) to `Caches/Montage/converted/<contentHash>.mov` (ProRes 4444 with
  straight alpha when the source has alpha, else H.264; FFmpeg → ProRes + PCM). **Every engine path resolves files through
  `PlayableMediaCache.shared.resolvedURL(for:)`** (composition default sources, preview `sourceChooser`, thumbnails, waveforms,
  proxies); `onReady` → store `forceRebuild()`.
- **FFmpeg licensing decision**: FFmpeg is only ever run as a separate executable (`FFmpegSidecar`), never linked. A bundled
  binary must be an LGPL build (no `--enable-gpl` / `--enable-nonfree`: no x264/x265/fdk-aac); the mezzanine uses only the LGPL
  `prores_ks` encoder and PCM. Ship FFmpeg's LICENSE + a written source offer. Lookup: `$MONTAGE_FFMPEG`,
  `Contents/Resources/ffmpeg`, `/opt/homebrew/bin`, `/usr/local/bin`. Without it, those formats are reported as unsupported.
- Bin folders: `Project.mediaFolders` (optional, use `project.folders`) + `MediaAsset.folderID`; pure `BinOps` (depth ≤ 10) +
  `BinCommand`. Folder imports keep their structure (`MediaProbe.expandWithFolders`). `MediaRelinker` (hash, then name+size),
  `MediaConsolidator` (copy into `<package>/media/`), `LivePhoto.pair`, `FontLibrary` (App Support/Montage/Fonts, process
  registration at launch), `CaptionFile` (Core: SRT/VTT/LRC/ASS, charset detection) — store flows in `EditorStore+Media.swift`.
- `Clip.audioStreamIndex` picks the audio stream of multi-track media (`AssetCache.Entry.audioStream`).

## 7. Thumbnails & waveforms

- `ThumbnailCache`: memory (NSCache, cost-bounded) + disk JPEG `Caches/Montage/thumbs/<hash>/<q>-<h>.jpg`. Times are quantized to 0.25 s so every zoom level reuses tiles. It uses proxies when ready, runs at most 3 concurrent generations, and provides `cached()` (sync, for drawing) and `thumbnail()` (async).
- `WaveformCache`: 100 peaks/s (UInt8), computed once per media from an 8 kHz mono decode, stored at `Caches/Montage/waveforms/<hash>.peaks`. `peak(from:to:)` downsamples for any zoom.

## 8. Export

`Exporter.export(project:settings:to:range:progress:)` builds the composition from originals at the export size → `AVAssetReaderVideoCompositionOutput` (same compositor) + `AVAssetReaderAudioMixOutput` (spectral time-pitch) → `AVAssetWriter`. Codecs: H.264/HEVC (hardware encoder preferred, bitrate presets lower/recommended/higher/custom), ProRes 422/4444 (.mov). Resolution 480p–4K by short side (even dimensions), any common fps, BT.709 tags. Cancelling the calling Task stops the reader and deletes the partial file. `ExportSettings.estimatedBytes` feeds the dialog.

## 9. Undo / redo (command pattern)

- Every edit is an `EditCommand` (`nameKey` + `apply(to: inout Project) throws`): `InsertClip`, `MoveClip`, `TrimClip`, `SplitClips`, `DeleteClips`, `SetSpeed`, `SetTransition`, `UpdateClip`, `AddMedia`, `UpdateSettings`, `SetTimelineOption`, or the ad-hoc `Edit("cmd.x") { p in … }`. Commands delegate to `TimelineOps`, which are pure and invariant-checked (`TimelineOps.validate`).
- `EditSession` keeps **whole-project snapshots**. Copy-on-write arrays mean a step costs only the arrays it touched. There are no inverse functions to get wrong. A failing command leaves no trace. Gestures (`beginGesture` / `updateGesture` / `endGesture`) turn a slider or clip drag into **one** undo step while the preview updates live (`updateGesture` re-applies to the gesture base, so updates are idempotent). The undo toast shows `tr(nameKey)`.

## 10. Persistence, autosave, crash recovery

- `.montage` package = directory with `project.json` (sorted-keys JSON; `schemaVersion` at the top) plus optional `media/` and `cover.jpg`. Saves are atomic (temp + rename). Media relative paths are refreshed on save and used to relink on load.
- **Versioning**: bump `Project.currentSchemaVersion` and add a step to `ProjectMigrator.steps[n]` (n → n+1 on raw JSON). Never edit an existing step. A file from a newer schema is refused (`PersistenceError.newerSchema`).
- **Autosave**: every project lives in a package from its first edit (drafts folder `~/Movies/Montage`). The editor writes it off-main from an immutable snapshot after 2 s idle, or at most every 30 s while edits continue (`AutosavePolicy`). The title bar shows "Auto saved: HH:MM:SS".
- **Crash recovery**: `SessionLock` writes `<package>/.session.lock` (pid). On open, a lock held by a dead pid means the last session crashed. The project reopens from the autosave (≤ 2 s old) with a "restored" toast. A lock held by a live pid means the project is open elsewhere.

## 11. Localization (en + fr)

- Mechanism (works with plain `swift build`): each module has `Resources/{en,fr}.lproj/<Table>.strings`. SwiftPM copies them into `Montage_<Module>.bundle`. `ResourceBundleLocator` finds bundles in `.app/Contents/Resources` (copied by `build_app.sh`) or next to the binary, so `Bundle.module` is never touched in the packaged app. `MontageBootstrap.registerResources()` registers every module.
- `L10n` merges all tables of the active language into one dictionary. Fallback order: language → en → key. Use `tr("key", args…)` and `Text(loc: "key")`. Plurals: `.stringsdict` + `L10n.plural`. **No hard-coded UI strings**, and SwiftUI `Text("literal")` is banned (use `Text(verbatim:)` only for data).
- **In-app override**: `L10n.shared.setLanguagePreference("system"|"en"|"fr")` is persisted in UserDefaults and posts `L10n.didChange`. `LocaleState.revision` is the root view's identity, so the UI rebuilds instantly and the menu bar is rebuilt. `--lang fr` sets the language for one session. `Info.plist` declares `CFBundleLocalizations` = en, fr.
- **Completeness**: `scripts/l10n_check.py` (run by `scripts/test.sh`) fails on any key missing in fr or en, empty values, and literal keys used in code that are missing from en. `LocalizationCoverageTests` checks dynamic keys (registries, enums) in both languages.
- One table per feature (e.g. `Resources/en.lproj/Captions.strings`) avoids merge conflicts. French register: **vous**. Terminology follows UX.md §10.

## 12. Extension registries: add ONE thing in ONE place

| Add a… | Where | Picked up by |
|---|---|---|
| Filter / video effect / adjustment | `EffectDescriptor` in `MontageEffects/Builtin/*.swift` (+ one line in that file's `all`) or `Registries.effects.register` | asset tab grid, drag & drop, inspector sliders (generated from `ParamSpec`), keyframes, renderer, export |
| Transition | `TransitionDescriptor` in `Builtin/Transitions.swift` | Transitions tab, timeline drop on a cut, renderer |
| In/out/combo animation (video, text, sticker) | `AnimationDescriptor` in `Builtin/Animations.swift` | Animation inspector tab, renderer |
| Sticker / text style | `Builtin/Stickers.swift` | Stickers / Text tabs |
| AI tool | `AIToolDescriptor` in `MontageAI/BuiltinAITools.swift` | job queue, progress, undoable result (`.edit`) |
| Inspector section / tab / sub-tab | `InspectorSection(id:tab:subTab:order:titleKey:appliesTo:chrome:content:)` / `InspectorTab` in `MontageUI/Inspector/BuiltinInspector.swift`, or `InspectorRegistry.register(_:)` / `register(_:in:)` for sub-tabs | inspector panel (tabs appear only when they have applicable sections; sub-tabs show as a segmented control when ≥ 2 have sections; `chrome` gives the CapCut header: checkbox, ↺, group ‹◇›, accessory, disabled reason) |
| Asset-panel tab | `AssetTab` in `BuiltinAssetTabs.all` or `AssetTabRegistry.register` | asset panel |
| Keyboard shortcut | `Shortcut` in `ShortcutRegistry.builtins` | key monitor (menu items for ⌘Z/⌘S/… are in `MontageApp/main.swift`) |
| Keyframeable clip property | `AnimatableProperties.all` + `ParamKey` constant | keyframes, resolved clips, inspector `Bind.slider` |
| Edit operation | `TimelineOps` function + `EditCommand` struct | undo, store |

Effect shader contract (see `EffectDescriptor` docs): `float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx)`, with straight RGBA in and out and `p[]` in `ParamSpec` order (colour = 4 floats). `ctx.time` is in clip seconds; `ctx.pass` is for multi-pass effects. Transitions: `float4 transition(uv, from, to, s, progress, p, ctx)`. Effects can declare `inputs: [EffectInput]` (e.g. `.lut3D(id:)`): the shader then takes extra trailing args (`texture3d<float> lut, sampler s3`, helper `fx_lut3d`), resolved by `EffectInputs` (engine); a missing resource skips the effect. Imported LUTs: `LUTLibrary` (`~/Library/Application Support/Montage/LUTs`, one `user.lut.<hash>` adjustment descriptor each, loaded at bootstrap). Colour grading descriptors: `Builtin/Color.swift` (HSL, curves, wheels, white balance).

## 13. Concurrency model

- Core types are immutable values and `Sendable`. Pass `Project` snapshots across threads freely.
- **Main actor**: `EditorStore`, all views, `PlaybackEngine` (AVPlayer control), display-link callbacks (cheap: they only encode Metal work).
- **Off-main**: composition builds (serialized by `CompositionBuilder.buildLock`), compositor rendering (`montage.compositor` queue, userInteractive, 3 in flight), export pumps (dedicated queues), proxy and AI jobs (`JobQueue` actor, detached tasks, priority-ordered, max 2 concurrent), thumbnail and waveform generation, autosave writes.
- Shared mutable engine state is lock-protected classes marked `@unchecked Sendable` with documented invariants (`RenderState`, `TexturePool`, `EffectPipelines`, caches). Non-Sendable AVFoundation objects cross boundaries only through `UncheckedSendable` where exclusive use is guaranteed. `@preconcurrency import AVFoundation/Metal`.
- Never block the main thread: no `waitUntilCompleted`, sync file I/O or decoding on main. The only exception is snapshots/tests.

## 14. Performance budgets (base M1 Air 8 GB is the target; measured numbers are from the M1 Pro)

| Path | Budget | Measured now (M1 Pro) |
|---|---|---|
| Preview 4×4K HEVC, 1080p preview | 30 fps, 0 drops | 29.2 fps composed (`PerfSmokeTests.playback4x4K`, originals, no proxies) |
| Paused property edit → new frame | ≤ 1 display frame | re-render from cached sources, no decode |
| Scrub (proxy) | < 50 ms p95 | to measure (bench hook TODO) |
| Structural edit → preview updated | < 150 ms | debounced rebuild 40 ms + item swap |
| Timeline draw | < 2 ms CPU/frame, 60–120 fps | instanced Canvas2D (prototype measured < 0.2 ms) |
| Export 10 s 1080p H.264 from 4×4K | ≤ 2.5 s | 2.15 s (release) |
| Proxy 60 s 4K HEVC → 720p | ≤ 10 s | 8.0 s |
| Cold start to editor | < 500 ms | — |
| App memory (UI + engine + 1 model) | < 3 GB on 8 GB | — |

## 15. Testing strategy

- `scripts/test.sh` runs `l10n_check.py`, then `swift test` (Swift Testing, about 2 s warm). `--perf` adds the 4K smoke tests (`MONTAGE_PERF=1`, needs `bench/make_media.sh`).
- **Core** (`MontageCoreTests`): time math, speed remap and segments, keyframes and easing, split/trim/move/delete/magnet/linkage/transitions (always followed by `TimelineOps.validate`), undo and gestures, persistence round-trip, migrations and relinking, session lock, localization, evaluator, geometry.
- **Engine render tests** (`MontageEngineTests`): synthetic media is generated on demand and cached in the temp dir (`TestMedia`). A test takes about 5 lines:
  ```swift
  var p = TestProject()                                  // 320×180 canvas
  let id = try await p.addVideo(.solid(.white))          // also .frameIndex, .split, .movingBox, addImage/addText/addSolid/addAdjustment
  p[id].opacity = 0.5
  #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0.5, 0.5, 0.5)))
  ```
  `.frameIndex` media encodes the frame number as a grey level, for frame-exact speed/trim checks. Export checks: `try await p.export(seconds: 1, settings:)` returns `MediaInfo` (ffprobe if installed: codec, size, fps, frame count, audio). Playback: `PlaybackProbe.measure(engine, seconds:)`.
- **UI** (`MontageUITests`): store flows (split/undo/gesture/apply effect/save-open), timeline layout hit-testing and snapping, localization coverage of dynamic keys.
- **Visual**: `scripts/screenshot.sh [--demo] [--open p.montage] [--lang fr] [-o out.png]` launches the app in the background without activating it (accessory policy, window ordered behind everything), captures it with `screencapture -l` and falls back to the app's offscreen `--snapshot` (SwiftUI chrome via `cacheDisplay` plus Metal views rendered offscreen; no Screen Recording permission needed), then quits.
- Every feature PR adds unit tests, plus render/export asserts when pixels change.

## 16. How to add X (recipes)

- **A filter**: in `Builtin/Filters.swift`, add `filter("name", group: "life", "o = …;")` to `all`, then add `filter.name` to `Effects.strings` (en + fr). Add a render test (`p[id].effects = [Registries.effects["montage.filter.name"]!.makeInstance()]`).
- **An effect with parameters**: write an `EffectDescriptor` with `ParamSpec`s and a shader that reads `p[i]`. The inspector UI is generated automatically and the parameters are keyframeable.
- **A transition**: add an entry to `BuiltinTransitions.all` and its strings. Test with `TimelineOps.setTransition` + render at the midpoint.
- **An inspector feature** (e.g. Chroma key): model fields on `Clip` (or an `EffectInstance`), a renderer step if needed, then an `InspectorSection(id:tab:order:titleKey:appliesTo:content:)` using `Bind.slider` / `Bind.value` (gesture coalescing and keyframes are built in).
- **An AI tool**: an `AIToolDescriptor` whose `run` returns `.edit(Edit("cmd.x") { … })`. The store runs it in `JobQueue`, shows progress, and applies the result as one undo step.
- **A timeline clip decoration**: in `TimelineView.drawClip`, use `Canvas2D.rect/image/text` only (GPU). Keep per-clip work O(visible tiles).
- **A model field**: add it with a default, bump the schema only if old files can't decode (prefer an optional or a default in a custom `init(from:)`), add a migration step, and extend the persistence round-trip test.
- **A project-level command**: `TimelineOps` (pure) + an `EditCommand` + a store method + a menu or shortcut entry + strings + tests.

## 17. Parallel work map (owners touch only their directories, plus additive strings tables and registry entries)

| Workstream | Owns (directories / files) | Notes |
|---|---|---|
| W1 Timeline editing UX | `MontageUI/Timeline/*`, `MontageCore/Editing/TimelineOps.swift` (new funcs) | marquee, split mode, ripple variants, markers, keyframe drag, transition handles, copy/paste, groups/compound |
| W2 Player canvas | `MontageUI/Player/*` (new `CanvasOverlayView`) | on-canvas handles (uses `LayerGeometry`), snap guides, zoom, safe areas, fullscreen |
| W3 Inspector panels | `MontageUI/Inspector/*` (one file per section) | Speed curves editor, Canvas bg, Crop, Audio voice changer… |
| W4 Effects & filters content | `MontageEffects/Builtin/*`, `Resources/*/Effects*.strings` | many presets; HSL/curves/LUT/colour wheels as descriptors |
| W5 Transitions & animations content | `Builtin/Transitions.swift`, `Builtin/Animations.swift` | per-glyph text animations need W7 |
| W6 Render engine | `MontageEngine/Render/*`, `Metal/*` | HDR/10-bit, LUT 3D textures, motion blur, matte inputs (AI), chroma key, mip downsampling |
| W7 Text engine | `MontageEngine/Render/TextRasterizer.swift`, new `Text/` | rich text, SDF glyph atlas, text on path, bubbles; captions styling |
| W8 Audio engine | new `MontageEngine/Audio/*` | MTAudioProcessingTap effect chain (EQ, denoise, voice changer) in preview and export, loudness, beats, recording |
| W9 Media pipeline | `MontageEngine/Media/*`, `Composition/*` | decoder limiter, preview render cache, reverse/freeze renders, FFmpeg fallback, folders/bin |
| W10 AI | `MontageAI/*` | matte → compositor (with W6), captions editor, denoise, auto reframe, scene split, whisper pack manager |
| W11 Export & interchange | `MontageEngine/Export/*`, `MontageUI/Export/*` | GIF, audio-only, ranges, FCPXML, SRT, presets |
| W12 Project mgmt & home | `MontageUI/Home/*` (new), `MontageCore/Persistence/*` | home screen, recents, templates, settings window, shortcut editor |
| W13 Asset library content | `MontageUI/AssetPanel/*` | search, favourites, hover previews, stock/local libraries, audio library |
| W14 QA / perf | `app/Tests/*`, `bench/`, `scripts/*` | perf harness, screenshot diffs, Air runs |

Shared hotspots (coordinate, keep edits small and additive): `Clip`/`Project` model fields, `CoreShaders.swift`, `EditorStore.swift`, `BuiltinInspector.swift` `sections` list, `Package.swift`.

## 17b. Timeline editing (W1)

- **Ops**: `MontageCore/Editing/TimelineOps+Editing.swift` (groups, `moveClips`/`trimClips` for multi-selection, clipboard `copyItems`/`paste`/`duplicate`, `pasteAttributes`, `freezeFrame`, `toggleReverse`, gaps, `roll`/`slip`, markers, beats, `extractAudio`/`restoreAudio`, `replaceMedia`, `arrange`, `reorderTrack`, in/out). Linkage follows `Timeline.linkageExcluded` (`followsMain`); deleting a main clip deletes the clips linked to it.
- **Model fields** (all optional, old files decode unchanged, no schema bump): `Clip.groupID / freezeFrame / beats / extractedFrom / colorLabel`, `Track.heightPreset / waveformScale`, `Timeline.linkageExcluded / inPoint / outPoint`, `Marker.note`. A freeze clip is a media clip whose speed maps a one-frame source extent to its duration (renders with the existing pipeline; trimming keeps the extent).
- **UI**: `TimelineUIState` (`store.timelineUI`: tool, scroll, clipboard, selected transition/marker/keyframe, preview axis), `EditorStore+Timeline.swift` (every toolbar/shortcut/menu command), `TimelineLayout` (hit-testing incl. transitions/keyframes/markers, insertion slots, marquee, `SnapIndex`), `TimelineView` (drawing) + `TimelineView+Input.swift` (gestures) + `TimelineMenus.swift`, `TimelineShortcuts.swift` (appended to `ShortcutRegistry.builtins`). Gestures: ⌥ edge = roll, ⌘⌥ body = slip, ⌥ body = duplicate, ⌘ = no snapping.

## 17c. Inspector (W3) — how panels are built

- Tabs per selection come from `InspectorContext.kind` (`InspectorSelectionKind`: none, video, image, audio, text, sticker,
  effect, filter, adjustment, transition, multiple). `EditorStore.selectedTransition` (clip owning `transitionOut`) is the
  transition selection; `applyTransition` selects the new transition like CapCut.
- Rows: `ClipParamRow` / `Bind.row` / `Bind.field` (one undo step per drag via begin/updateGesture/end, one per field commit or
  stepper click, live preview; CapCut keyframe semantics via `Clip.setValue`/`modifyValue`). `KeyframeTriplet` works on a key
  *group* (`Clip.toggleKeyframes/previousKeyframe/nextKeyframe`, MontageCore `KeyframeNavigation.swift`). Rows observe the playhead
  only when keyframed. `EffectParamRows` generates rows from any `EffectDescriptor`.
- Canvas (`Clip.canvas`) and chroma key (`EffectCategory.key`, `BuiltinKeying`) need no renderer code: the evaluator emits extra
  layers / the key is a normal effect. Canvas styles are `EffectCategory.canvas` shaders on a full-res `.solid` layer.
- Speed curves: `SpeedCurve.interpolation = .smooth` (monotone cubic, exact integral) + `SpeedCurvePreset.all`.
- Visual check: `MONTAGE_SNAPSHOT_DIR=… [MONTAGE_SNAPSHOT_LANG=fr] swift test --filter InspectorTests` writes a PNG per panel.
- Cutout sections are disabled until `CutoutAvailability.matteCompositingAvailable` is set by the AI/render teams.

## 17c. Audio pipeline (W8, `MontageEngine/Audio`)

- **Model**: `AudioProps` (Clip.audio) gained `pitch`, `voice: VoiceEffect?` (registry id + 0…100 params), `noiseReduction`, `enhanceVoice`,
  `separation`, `loudness` (target + measured LUFS), `eq` (10-band), `channels`, `ducking`. All optional/neutral and decoded with defaults
  (no schema bump). Beat markers are W1's `Clip.beats` (clip-local); auto beats (`AudioAnalysis.clipBeats`) write there.
- **Per clip, `ClipAudioPlan.make(clip)`** splits the settings into three stages, identical in preview and export (same composition):
  1. **Rendered stage** (`RenderStageSpec`: pitch/formant phase vocoder, harmony, robot, whisper, denoise, enhance, vocal separation, and
     "Change pitch" with speed): latency-bearing DSP rendered OFFLINE over the whole media file, latency-compensated, cached as lossless CAF
     in `Caches/Montage/audio/<hash>-<spec>.caf` (`AudioRenderCache`). The composition inserts the rendered file instead of the original.
     Export awaits it; preview plays the original until ready, then `onReady` → rebuild (structure key includes readiness).
  2. **Live stage** (`[LiveNode]`: EQ, voice-filter colour — filters, echo, chorus, Freeverb, tremolo, ring-mod, bitcrush, distortion, noise,
     compressor, limiter — and channel matrix): one `MTAudioProcessingTap` per composition audio lane (`LaneProcessor`, post-effects),
     reading `AudioMixState` each buffer, so edits are heard without a rebuild (not part of the structure key).
  3. **Gains** (volume/keyframes, fades, loudness gain, ducking envelope) → AVAudioMix ramps.
  Speed/time remap = the shared segments + AVFoundation spectral time-pitch. Never use `.varispeed`: it stalls
  `AVAssetReaderAudioMixOutput` on sped-up segments (pitch-follows-speed is done in the rendered stage).
- **Analysis**: `AudioAnalysis` (BS.1770 loudness meter, onset envelope, tempo + DP beat tracker, onset cross-correlation sync),
  `Ducking` (waveform-envelope trigger). **I/O**: `AudioFileIO` (streaming decode to 48 kHz float, writer for ALAC/WAV/AAC/FLAC),
  `AudioMixdown` (the export mix as samples: audio-only export `AudioExporter`, tests), `AudioExtractor` (video file → .m4a),
  `VoiceRecorder` (AVAudioEngine input, devices, voice processing), `SoundEffects` (procedural SFX pack).
- **Add a voice preset**: one entry in `VoiceEffects.filters`/`characters` (design = pitch/formant/robot + live nodes) + `voice.<id>` in
  MontageUI `Audio.strings` (en + fr). `AudioDSPTests.everyVoicePresetProducesSaneOutput` checks it automatically.
- **UI**: `MontageUI/Audio/*` — inspector sections registered via `AudioInspector.sections/tabs` (video ▸ Audio [Basic · Voice changer];
  audio clip ▸ Basic · Voice changer · Speed), Audio asset tab (`AudioLibraryView`: Yours · Sound FX · Extracted), recorder popover,
  toolbar ♥ beats menu, store actions in `EditorStore+Audio.swift`. Screenshot keys: `--player-state "select=audio,tab=audioVoice,voice=helium,
  sub=audio:voice,assets=audio,audiolib=sfx"`.
- **Tests**: `AudioDSPTests` (filters, EQ, STFT transparency, pitch/formant, echo, reverb, compressor, denoise, separation, robot, all
  presets), `AudioAnalysisTests` (LUFS reference, tempo/beats, sync), `AudioPipelineTests` (mixdown through the export path: volume, fades,
  keyframes, live EQ, voice changer, pitch vs speed, speed curves, loudness, ducking, denoise, taps present, live-edit structure key,
  A/V sync through speed + export), `AudioUITests`.

## 17d. Text engine (W7)

- **Model** (`MontageCore/Text/`): `TextContent` (all distances in **em** = font px; new fields decode with defaults): case, vertical
  orientation, extra strokes, background (block/line/letter), shadow (+3D extrude), glow, gradient/texture fill, curve, path,
  `boxWidth`, per-range `runs` (UTF-16 `TextSpan`; `setString` keeps runs on their characters, `applyStyle`, `commonStyle`),
  bubble, `caption: CaptionData` (word timings in *content time* = clip-local + `sourceStart`; the evaluator shifts them to
  clip-local), `karaoke: KaraokeStyle`, `template: TextTemplateInstance`. `TextTokenizer` = the one word segmentation shared by
  captions and renderer. `CaptionOps` (pure): add caption track from `CaptionSegment`s (the AI hand-off), split/merge/nudge/setText,
  find & replace, apply look to all, line wrap, script → captions, keyword picker. `CaptionFiles`: SRT/VTT/ASS/LRC/TXT parse +
  serialize (word timings round-trip via VTT `<t>`, ASS `\k`, enhanced LRC).
- **Content** (`MontageEffects`): `GlyphAnimationSpec` on `AnimationDescriptor.glyph` (unit char/word/line/all, stagger order,
  span, loop wave) — `BuiltinTextAnimations` (targets `.text`); `Registries.textStyles` (procedural presets + word art, `kind`),
  `textBubbles`, `textTemplates` (layers = text slots / shapes with time window + glyph anims, `fitSlot`), `captionTemplates`.
- **Engine** (`MontageEngine/Text/`, `Render/TextRasterizer.swift`): Core Text layout → `LaidCluster`s (shaping, bidi, fallback;
  curve/path/vertical transforms) → `TextScene` (blocks: main, bilingual sub line, template layers; items: bubble, backgrounds,
  karaoke word boxes, per-glyph back = shadow/glow/outlines, front = fill/underline) → `TextPainter` (CG glyph outlines).
  Static text: one cached CG image. Animated / karaoke / template text: every item rasterized once into a `TextAtlas`; per frame
  `TextAnimator` computes glyph instances and `TextGPU` draws them with one instanced pass into a pool texture. Images are padded to
  16 px and margins to 8 px so the compositor draws them 1:1 (rest pose == static image, no pop). Raster scale follows the layer
  scale (√2 buckets). Bounds are symmetric around the text box (effects never move the text). `measure` / `textBox` /
  `TextMetrics.size` give canvas sizes for handles. 50 animated karaoke captions at 1080p ≈ 13–16 ms/frame (debug, M1 Pro).
- **UI** (`MontageUI/Text/`): `TextInspector` (tabs/sections registered from `BuiltinInspector`), `FontPicker` (+ `FontCatalog`
  over W9's `FontLibrary`), `ClipTextEditor` (typing = one undo step per burst), `CaptionEditor`, `TextAssetTab`, previews rendered
  with the real engine (`TextPreviewCache`). Inline canvas editing is W2's `InlineTextEditor`; `store.beginInlineTextEdit(id)`.
- **Add a text style / animation / bubble / template / caption template**: one entry in the matching `Builtin/Text*.swift` /
  `CaptionTemplates.swift` list + keys in `MontageEffects/Resources/*/Text.strings`. `TextRenderTests` renders every registry entry.

## 18. Known gaps (foundation)

Speed-curve editor UI, on-canvas crop handles, home screen and settings window, audio effects chain, editing inside compound clips (UI), pen/text/brush masks, rotation in stabilization, auto beat detection, and the Templates/Library content.
