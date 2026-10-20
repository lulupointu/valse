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
| **MontageAI** | `app/Sources/MontageAI` | `AIToolDescriptor` + `AIRegistry`, model catalog/manager, speech (whisper.cpp sidecar, SpeechAnalyzer, SFSpeech), mattes (Vision), voice isolation, TTS, translation, frame interpolation, Foundation Models — see §17d | Core, Engine, Vision, Speech, Translation, VideoToolbox |
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
- **Compound clips** (`ClipContent.compound`, `Project.compounds`): `FrameEvaluator` evaluates the nested timeline at the clip's remapped time and emits `RenderItem.nested(container:items:)` with clip ids made unique by `nestedClipID(container, inner)`; the renderer composites the items on transparent and places the result as one layer with the compound's own transform/opacity/blend/mask/effects. `CompoundFlattening.decodeTracks` adds the nested media as retimed virtual tracks for the composition (video + audio). Depth ≤ 4. It also applies track **solo** (`Track.isSolo`, `Timeline.isAudible`): non-soloed tracks come out muted, so preview and export follow.
- **Multi-timeline** (TL-023, `MultiTimeline.swift`): `Project.timeline` / `settings` always hold the ACTIVE timeline (engines are unaware of the others); `Project.timelines` lists every `TimelineSlot` (name, timeline, per-timeline settings) in tab order, `activeTimelineID` marks the live one (its stored copy is stale, saved empty). Switch/new/duplicate/delete are `MultiTimelineOps` edits (one undo step each). Code that must see every timeline (e.g. "is this compound still used") uses `MultiTimelineOps.allTimelines`.
- **Edit inside a compound** (TL-021, `Editing/CompoundEditing.swift`): entering pushes a `CompoundEditFrame` (parent timeline) on `Project.compoundEdit` and puts the nested timeline in `Project.timeline`, so every tool and the preview work on it unchanged; exiting stores it back in `compounds`. `MultiTimelineOps.allTimelines` includes the parents; timeline switches exit first; export uses `store.rootProject`.
- **Track volume / clip markers / freeze links** (FIN): `Track.volume` is baked into the clips by `CompoundFlattening.decodeTracks`; `Clip.markers` are clip-local (split/trim/speed keep them); `Clip.freezeSource` freeze frames copy the original's look after every edit/gesture tick (`FreezeLinks.sync`, called by `EditSession`).
- **Timecode** (`Time/Timecode.swift`): `Timecode.display(t, rate:)` follows `TimecodeDisplay.current` (Settings ▸ Edit: frames / ms, drop-frame for 29.97/59.94); `Timecode.parse` reads typed timecodes (player timecode entry).
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
| Transition | `TransitionDescriptor` in `Builtin/Transitions.swift` (body only; see §17g) + name in `Transitions.strings` | Transitions tab (thumbnail rendered from the shader), timeline drop on a cut (main or overlay), renderer, inspector param rows |
| In/out/combo animation (video, text, sticker) | `AnimationDescriptor` in `Builtin/Animations.swift` | Animation inspector tab, renderer |
| Sticker / text style | `Builtin/Stickers.swift` (animated: a Bodymovin JSON in `Resources/Lottie` + `lottie("name")`) | Stickers / Text tabs |
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
- **Interaction tests** (UI test driver): `scripts/uitest.sh app/Tests/UIScripts/<name>.json` runs a ~10-line JSON
  script (clicks/drags/keys/menu/drop by test ID or timeline coordinates, `expect` on a JSON state dump, snapshots)
  inside the app in an offscreen, never-activated window (`Montage --uitest`, `MontageUI/Testing/`). Screenshot
  baselines with tolerance in `app/Tests/Baselines`; perf harness `scripts/perf.sh`. **How-to: docs/TESTING.md.**
  Give new views a `.testID("area.thing")`.
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
- **Bundled music + SFX library (MUS, AU-001/002/025)**: `ContentLibrary` (manifest model, install-folder resolution, license
  validation), `ContentSimilarity` + `AudioFeatures` (47-dim MFCC/chroma/spectral/rhythm descriptor, key estimate, z-scored cosine
  "similar sounds"), `ContentAnalyzer` (`Montage --analyze-content`: duration, loudness, beats/BPM via `AudioAnalysis`, key, peaks,
  features). Only CC0 / public-domain items (FreePD, Free Music Archive, Kenney, OpenGameArt, Wikimedia Commons). Pipeline:
  `scripts/fetch_music_pack.sh` (sources in `scripts/content/*_sources.json`, pinned SHA-256, license page checks, AAC encode,
  analysis) → committed `Resources/ContentLibrary/content_manifest.json` + audio cache (never committed) → `scripts/build_app.sh`
  copies it into `Montage.app/Contents/Resources/Content`. Runtime is offline: `ContentLibrary.directory` = bundle, else
  `MONTAGE_CONTENT_DIR`, else the developer cache. **Add a track**: one entry in `music_sources.json`, run the fetch with `--pin`,
  commit both JSON files; `ContentLibraryTests` validates licenses, provenance, analysis and the installed files.
- **Online music + SFX search (MUS, owner exception to local-only)**: `MontageEngine/Audio/Online/` — `OnlineAudioProvider`
  (`FreesoundProvider`, `JamendoProvider`: `request(query,key)` + `parse(data)`), `OnlineLicensePolicy` (CC0 / PDM = "Safe ✓",
  CC BY = "Credit", everything else dropped), `OnlineAudioHTTP` (the only network seam; `MockOnlineAudioHTTP` in tests / UI-test
  mode serves Freesound/Jamendo-shaped JSON + local tones), `OnlineAudioDownloads` (cache `<cache>/OnlineAudio`, then copied into
  `<project>/media` with a `<file>.license.json` sidecar), keys in the Keychain (`KeychainSecretStore`; `MemorySecretStore` in tests).
  UI: `AudioLibraryOnline.swift` (`OnlineAudioState`, Audio ▸ Online: For you / Trending / Moods / Genres / Sound effects,
  24 h query cache, streamed previews via `LibraryAudioPreview.stream`), Settings ▸ Music (`MusicSettings.swift`).
  Rule: nothing outside these types touches the network, and only when the user opens / searches Audio ▸ Online.
  **Add a provider**: implement `OnlineAudioProvider`, append it to `OnlineAudioProviders.all`, add
  `settings.music.provider.<id>` (en + fr) and a mock response in `MockOnlineAudioHTTP`.
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

## 17e. AI (W10) — MontageAI + MontageUI/AI

- **Models** (`MontageAI/Models`): `ModelCatalog` (spec: url, bytes, SHA-256, licence, runtime MB) and `ModelManager` (@MainActor
  @Observable: notInstalled / downloading(p) / verifying / installed / failed; download via URLSession with progress + cancel,
  streamed SHA-256 check, "Use an existing file…" import = verified APFS clone). Files live in
  `~/Library/Application Support/Montage/Models` (`MONTAGE_MODELS_DIR` overrides). Never bundled or committed. The download is the
  only network access and is always user-initiated. `WhisperRuntime.cliURL` finds `whisper-cli` (`MONTAGE_WHISPER_CLI`,
  `Contents/Helpers`, App Support/bin, Homebrew) — like FFmpeg it runs as a **sidecar process** (model unloaded when the job ends).
- **Speech** (`Transcriber`): `.automatic` = whisper.cpp large-v3-turbo (Metal, beam 5, `-ojf` token offsets merged into words,
  `-l auto` language ID, progress from `-pp`, cancel = terminate) → SpeechAnalyzer (SpeechTranscriber/DictationTranscriber) →
  SFSpeechRecognizer. Apple engines auto-detect by transcribing a 15 s excerpt in each candidate language (confidence +
  NLLanguageRecognizer). `AudioExtractor.wav16k` feeds them. Results are Core `Transcript`s (media-time words) cached in
  `TranscriptStore` (Caches/Montage/transcripts, key = hash + range + language + engine). bench/speech_fr.wav: whisper WER 3.1 %,
  RTF 0.11; Apple 12.6 %.
- **Captions** use the text team's model (§17d: `TextContent.caption`, `CaptionOps`). W10 adds `Captions/SpeechCaptions.swift`
  (Core): `SpeechSegmenter` (≤ 2 lines × 28 chars, breaks on sentence ends / pauses > 0.6 s / 6 s, filler tagging/removal),
  `SpeechCaptions.segments(transcript, for: mediaClip)` → `CaptionSegment`s in timeline seconds with word timings (inverse time
  remap `Clip.timelineTime(forSource:)`, speed curves included), `finish` (filler flags, linkage to the main clip), translations and
  keyword marks. `CaptionGenerator` (MontageAI) runs the job and ends with `CaptionOps.addCaptionTrack(…, origin: .auto/.lyrics,
  replacing:)`. `TranscriptEditing` (Core) maps transcript words to main-track pieces and ripple-deletes / restores them.
- **Speaker ID** (AI-005 / TX-038): `CaptionData.speaker` ("1", "2"…) + `Project.speakers` (`CaptionSpeaker`: name, colour;
  optional, old files decode). Core `Captions/Speakers.swift`: `SpeakerClustering` (average-linkage cosine, Auto threshold or
  fixed count, tiny clusters folded, subsample above 500 windows), `SpeakerCaptions` (split segments at speaker changes with
  one-word-flip smoothing, majority `assign` for existing captions, palette colours, rename, apply look to a speaker).
  MontageAI `SpeakerDiarizer`: windows from caption word timings (≤ 2 s, split at 0.5 s pauses) → audio of the clip playing
  then → `WeSpeakerEmbedder` (Core ML `wespeaker_v2.mlmodelc`, one window per prediction tiled to 10 s: batching windows
  collapses embeddings in this conversion) or `StatisticsEmbedder` (MFCC + pitch, z-scored) → `SpeakerTurn`s.
  `CaptionOptions.identifySpeakers` runs it inside `CaptionGenerator` (phase `.speakers`); `SpeakerIdentification` tags
  existing captions. Multi-file models: `AIModelSpec.parts` (each file SHA-256 checked into a directory). UI `SpeakersUI.swift`.
- **Cutout**: `MatteGenerator` writes mattes through the render team's `MatteVideoWriter` / `MatteStore.setStill`: `person`
  (VNGeneratePersonSegmentationRequest .balanced + temporal smoothing), `subject` (VNGenerateForegroundInstanceMaskRequest), and
  `custom.<id>` (brush strokes → instances on the painted frame, tracked frame to frame by overlap). Frames are decoded at ≤ 960 px.
  UI: `CutoutUI.swift` sections + `CutoutBrushTool` (a `PlayerUIState.canvasTool`, the generic modal-canvas-tool hook in
  `CanvasOverlayView`). Unticking or ⌘Z cancels the job (`aiProjectDidChange`).
- **Audio**: `VoiceIsolator` runs Apple's ML `AUSoundIsolation` offline (AVAudioEngine manual rendering, ~35× RT) into
  `AudioStemStore` stems (`voice`, `novoice`, 48 kHz stereo CAF aligned with the media). The app installs `AudioML.voiceStems`
  (Engine/AI): `ClipAudioPlan` then sets `RenderStageSpec.mlVoice` for Isolate voice / Reduce noise / Enhance voice and W8's
  rendered stage starts from the stem mix (voice + (1 − strength)·rest) instead of its DSP separation/denoiser (§17c). Tests install
  the provider without `usedByPlans` so DSP tests stay DSP. Separate audio ▸ Vocals / Background music adds a stem clip.
  `SpeechSynthesis` (AVSpeechSynthesizer.write, FR/EN voices) → content-addressed files in App Support/Montage/Generated/tts;
  `Clip.tts: TTSInfo` links the audio clip to its text clip (`TTSOps`, "Update speech according to script").
- **Video**: `VTFrameInterpolator` (VTFrameProcessor frame-rate conversion, macOS 15.4+) is installed as
  `FrameInterpolation.provider`: GPU-only (rgba16Float → IOSurface 64RGBAHalf → same command buffer). Session start (~0.4 s, ~12 s
  the very first time) happens in the background; until ready the frame falls back to blending. Call
  `AIEngineHooks.prepareOpticalFlow(width:height:wait: true)` before an export that must use optical flow.
- **Text**: `CaptionTranslator` (Translation framework: installed pairs in the background; otherwise `TranslationHost` view's
  `.translationTask` lets the OS download), `OnDeviceLLM` (Foundation Models when available, else callers fall back) and
  `KeywordExtractor` (LLM, fallback TF-IDF + NLTagger nouns).
- **Video**: `SceneDetector` (histogram + luma, adaptive peaks) → `SceneSplit` (right-click ▸ Split scenes); `SubjectAnalyzer`
  (Vision faces → humans → objectness saliency) → `ReframePath` (Core: dead zone, Gaussian path, fill scale, position keyframes) →
  `AutoReframe` (Video ▸ Basic ▸ Auto reframe, `Clip.reframe`).
- **Stabilization** (AI-059, W6's `StabilizationStore`): the analysis fits content-aware similarity motion per frame (5 × 4
  textured blocks, outlier rejection → shift + roll; cache `<hash>.v2.json`); `StabilizationTrack.dr` / `aspect` carry the roll
  correction that `FrameRenderer.uvTransform(stabilize: StabilizeCorrection)` applies with the shift and crop zoom.
- **Motion tracking** (AI-014): `ObjectTracker` (Vision `VNTrackObjectRequest`, ≤ 640 px, forward + 1 s-chunk backward) →
  `TrackSample`s in raw source coords → `MotionTracking.apply` (Core) maps them through the reference layer
  (`FrameEvaluator` layer geometry, crop/flip/rotation) into position (+ scale) keyframes on the follower; `Clip.tracking`
  remembers the request. UI: `TrackingUI.swift` (Tracking tab, `MotionTrackBoxTool` canvas tool).
- **Colour looks** (CL-007/008/009): `ColorTransfer` (Core: Lab stats, Reinhard match, auto adjust) → `ColorLooks` (MontageAI)
  bakes a 33³ LUT into `App Support/Montage/Generated/looks/<kind>.<hash>.cube`, registered unlisted in W6's `LUTLibrary` as
  effect `ai.look.<kind>.<hash>` (Strength param; `ColorLooks.loadAll()` at startup). UI: `ColorLookUI.swift` (Adjust ▸ Basic).
- **Video enhance** (CL-017/018/019): `VideoEnhancer` renders a processed copy (deflicker gains, temporal denoise, VT low-latency
  super resolution ×2; streaming reader → HEVC writer + audio passthrough) into `Caches/Montage/enhanced/<hash>-<key>.mov`;
  `VideoEnhanceJob` swaps the clip's media to it and records `Clip.enhance` (original media id) so unticking restores it.
- **Local LLM**: `OnDeviceLLM.respond` = Apple Foundation Models when Apple Intelligence is on, else `LlamaRuntime`
  (`llama-completion` sidecar from scripts/build_ai_runtimes.sh + `ModelCatalog.qwen3_4b`, ~3 GB while running, unloaded after).
  Users: `AIWriter` (Text ▸ AI writer → `.script` captions), `AIClipper` (+ Core `Highlights`: sentences, windows, heuristic score,
  `rebuildMainTrack`), `KeywordExtractor`.
- **Face mosaic / camera tracking**: `CutoutMode.faces` (Vision face boxes, `FaceMatte.Holder` keeps them through drop-outs) →
  `FaceCover` adds a linked copy of the clip above with Pixelate/Blur + `faces` matte. `CameraTracker` (faces / humans at 10 fps)
  → Core `CameraLock` (smoothed path → position/scale keyframes, `Clip.cameraLock`, excludes `Clip.reframe`).
  Hand target: `VNDetectHumanHandPoseRequest` → `CameraLock.handBox` (confident joints, ×1.3 square).
- **AI movement** (AI-025): `AIMovementJob` (SubjectAnalyzer samples at 2 fps / `SubjectAnalyzer.still` for photos, cached in
  memory per media range) → Core `AIMovement.apply` (preset poses: zoom / soft Ken Burns / dynamic segments / 12 Hz seeded shake,
  beats from `AIMovement.beats` = every clip's `beats` under the clip) → position / scale (/ rotation) keyframes clamped so the frame
  keeps covering the canvas; `Clip.aiMovement`; it, `Clip.reframe` and `Clip.cameraLock` exclude each other. UI `AIMovementUI.swift`.
- **AI remove**: `LaMaInpainter` (Core ML LaMa 800², zip from the model manager → compiled `Caches/Montage/models/LaMa.mlmodelc`;
  mask bbox ×2 crop → 800 px → feathered paste-back) → `ObjectRemover` (image PNG / per-frame video ≤ 30 s) → `ObjectRemovalJob`
  swaps the clip's media (`Clip.removal`, strokes = `RemovalStroke` raw source coords). UI `AIRemoveUI.swift` (`RemoveBrushTool`).
  Track object (AI2): `ObjectRemovalInfo.tracking` (`RemovalTracking`, media time of the brushed frame) → `ObjectRemover.trackedBoxes`
  (`ObjectTracker` on the strokes' bounds) → per frame `RemovalTracking.box(at:)` + `transform` (Core) move/scale the strokes
  before the mask is drawn; the cache key includes the tracking. Camera tracking ▸ Custom box: `CameraLockOptions.customBox/customTime`
  → `ObjectTracker` → `CameraLock.samples(fromTracked:)`; UI `LockBoxTool` (wraps `MotionTrackBoxTool` over the clip's own layer).
- **EditPilot** (AI-048, `MontageAI/Pilot`): `EditPilotPlanner` (Foundation Models → Qwen sidecar → `PilotRules` FR/EN
  keyword planner; UI tests on the sandboxed models folder always use the rules, `ModelCatalog.isSandboxed`) turns a chat
  request into `PilotAction`s — a closed, typed, validated command set (`PilotCallParser` drops unknown tools, clamps numbers,
  resolves transition/filter names in en+fr via `PilotCatalog`). `EditPilotExecutor` orders them (cuts → timing → structure
  → looks → audio → fades → captions → titles), gathers what they need into a `PilotContext` (Core `ActivityProfile` per
  media from `ActivityAnalyzer`: 50 ms dBFS + 0.25 s motion, cached in `Caches/Montage/activity`; `PilotTranscripts` with
  disfluencies via `TranscriptStore`; loudness) and applies the pure `PilotOps` to a project copy → `PilotExecution`
  (before/after + per-step results) and `PilotDiff`. UI: `EditPilotPanel` (replaces the asset panel), `EditorStore+EditPilot`
  (`store.ai.pilot`): plan/prepare run in `JobQueue`; Preview = a store gesture showing `after` (any other `perform` /
  `beginGesture` cancels it first, so an unapplied preview is never committed); Apply = ONE undo step `cmd.editPilot`.
- **Long video to shorts** (AI-031, Home): Core `ShortsPlanner` (validation, `ShortsDuration` buckets, one 9:16 project per
  `Highlight`) + `Highlights.pick(range:)`; MontageAI `LongToShorts.run` (AIClipper transcript + LLM boost → picks →
  `AutoReframe` + captions from the same transcript); UI `Home/ShortsWizard.swift` (`ShortsWizardState`, overlay on HomeView,
  feature card), projects saved with `ProjectLibrary.create`.
- **Dictate** (TX-034): `Dictation` (AVAudioEngine tap → `SFSpeechAudioBufferRecognitionRequest`, on-device only, partial
  results) + `DictateButton` (text inspector, AI writer, EditPilot); text clips wrap a dictation in one gesture.
- **Quit**: `AppShutdown.stopBackgroundWork` (applicationShouldTerminate / end of a UI test) cancels exports and every
  `JobQueue` job and waits (`JobQueue.shutdown(timeout:)`, refuses new jobs) for the bodies to return; exiting under live
  Core ML/Metal work crashed in the frameworks' atexit teardown, a timeout leaves through `_exit`.
- **Relight** (AI-024 / CL-020, AI2): `Clip.relight: RelightSettings` (Core `AI/Relight.swift`: presets, target, ≤ 4 lights,
  animations resolved per frame into `LayerDescription.relight`). `RelightDepth` (MontageAI) writes the `depth` matte (≤ 518 px,
  ≤ 12 fps, near = white) with Depth Anything V2 Small (`ModelCatalog.depthAnything`, an `.mlpackage` = main weights file +
  `companions`, compiled to Caches/Montage/models) or a person-matte + luma pseudo-depth, plus the `person` matte for People /
  Background. `CompositionBuilder.auxInputs` adds aux lanes `.depth` / `.relightMask`; `FrameRenderer+Relight` (own Metal
  library) derives normals from smoothed depth differences and shades after the matte pass (flat until the depth lands). UI:
  `RelightUI.swift` (section, `RelightLightTool` canvas tool, `setRelight` / `ensureRelightPass` jobs).
- **UI** (`MontageUI/AI`): `store.ai` (`AIUIState`), `EditorStore+AI.swift` (jobs: captions, cutout, translation, stems),
  `AutoCaptionsPanel` (Text ▸ Auto captions), `TranscriptPanel` (replaces the asset panel), `TTSInspector`, `VideoAIUI`,
  `ModelManagerSheet`, translate / LLM-keyword entries in W7's Captions tab,
  `AIInspector` (tabs/sections appended to `BuiltinInspector`). All AI work runs in `JobQueue` (progress, cancel; subject = clip id
  → progress overlay on the clip). Tests: `MontageAITests` (WER, segmentation on generated frames, compositor, TTS round trip,
  voice isolation SNR, optical flow, scenes, reframe) + `AIUITests` (flows, snapshots with `MONTAGE_SNAPSHOT_DIR`).
  GPU/ANE-heavy tests and real-time probes (PlaybackTests) run inside `HeavyWorkGate.run` (MontageEngine/Jobs; ML `JobQueue` jobs with `heavy: true` take it too in test processes) so they never overlap.

## 17f. Effects, filters, colour & stickers content (W4)

- **Effects library** = `FXBase` (one MSL source in `Builtin/FX+*.swift`, `FXKit.msl` helpers prefixed `kit_`) × presets
  (`base.preset("name", group:, constants, defaults:, tags:)` → `montage.effect.<name>`). Presets differ only by
  `EffectDescriptor.constants` (appended to `p[]` after the params, never stored/keyframed), so `EffectPipelines` caches
  pipelines **by source** and a base compiles once. Multi-pass effects that need the untouched input declare
  `inputs: [.original]` (shader gets a trailing `texture2d<float> orig`). Pixel-scaled features use `ctx.size.y / 1080`.
  Body effects (`effect.group.body`) work on the layer alpha (cut-outs, stickers, text).
- **Filters** = one parametric grade shader (`BuiltinFilters.Grade` → constants: exposure, WB, filmic/contrast,
  highlights/shadows, sat/vibrance, hue, split tone, cross-process, bleach, channel-mixer B&W, fade/matte, grain,
  vignette, skin protect). Add a look with `look("name", "group") { $0.… }` + its name in `FilterLibrary.strings`.
- **Names**: `EffectLibrary.strings` / `FilterLibrary.strings` / `StickerLibrary.strings` (en+fr) are generated tables
  (one key per preset); `EffectLibraryTests.libraryIsLargeAndNamed` checks both languages.
- **Colour**: Curves are free points (`<ch>.n`, `x0…7`, `y0…7`; `ColorCurveMath` = CPU mirror), wheels have a `mode`
  (Primary/Log), Basic gained hue/whites/blacks/sharpen/clarity/grain/fade (append-only p[] order). `AutoColor.descriptor`
  (parametric auto grade from `AutoAdjustAnalyzer`) stays in the registry, but the Adjust ▸ Basic ▸ ☐ Auto adjust UI is
  W10's LUT look (§17e). Inspector: `ColorGradingInspector` (Adjust ▸ HSL / Curves / Color wheel sub-tabs).
- **Previews**: `EffectPreviewRenderer` (engine) renders any effect stack on a procedural sample scene through
  `FrameRenderer.applyEffects` (same shaders as export) — asset thumbnails/hover loops (`EffectThumbnails`, off-main,
  LRU), render tests (`EffectLibraryTests`, `EffectBehaviourTests`) and the 1080p GPU budget test (`EffectsPerfTests`,
  3.5 ms per effect on M1 Pro ≈ 7 ms on a base Air; `MONTAGE_PERF=1` strict). `MONTAGE_FX_SHEET=dir` writes contact sheets.
- **Stickers**: `StickerDescriptor.Source.vector([VectorLayer])` (shapes, callouts, arrows, decorations) drawn by
  `VectorStickerRenderer` (Core Graphics at output resolution, cached in `TextRasterizer`); emoji via Core Text.
- **Asset tabs** (`AssetPanel/EffectLibraryTab.swift`, `StickerLibraryTab.swift`): `EffectLibraryCatalog` /
  `StickerCatalog` (groups, curated Trending/Featured, search), `EffectFavorites` (UserDefaults).

## 17g. Transitions, animations, keyframes, Lottie (W5)

- **Transitions** (`Builtin/Transitions.swift`): 121 descriptors in 12 groups. Bodies are wrapped by `TransitionShaderLib.wrap`
  (helpers: `FA/FB` sample, `GA/GB` transparent outside, `MA/MB` mirrored, `tr_sweep` reveal mask exact at 0/1, `tr_bump`,
  blurs, noise, shape gauges, `tr_quad` ray–quad hits for 3D). `from`/`to` are premultiplied canvas textures. Contract,
  tested for every entry (`TransitionRenderTests`): progress 0 = A exactly, 1 = B exactly, 0.5 differs, < 8 ms at 1080p.
  Params (`ParamSpec`) show as rows under Duration (`TransitionParamRows`); no keyframes. Ids are persisted: append only.
- **Overlay (PiP) transitions**: `TimelineOps+Transitions.swift`. On any track clip i may overlap clip i+1 by exactly its
  `transitionOut.duration` (`validate`). Overlay tracks: setting slides the right clip left, removing slides it back (pushing
  contiguous followers); `clampTransitions` → `normalizeOverlayTransitions` keeps overlaps in sync and drops transitions whose
  clips no longer touch. `CompositionBuilder` gives A/B lanes to any track with a transition; the evaluator renders
  transitions on every visual track. `transitionIssue(after:)` (TR-007 toasts), `transitionCut(near:track:)` (drops).
- **Previews**: `PresetPreviewRenderer` (Engine) renders transition frames between two procedural sample pictures and frame
  descriptions synchronously (off-main only); `TransitionThumbnails` (UI) caches stills + hover loops. `EffectPipelines.prewarm`
  compiles a project's transitions/effects in the background (called from `PlaybackEngine.update`), so the first frame of a
  transition never stalls on a runtime compile (~0.15 s each).
- **Animations** (`Builtin/Animations.swift`): presets are generated from motions `m(k, &state)` (k = 0 rest … 1 away) with
  `AnimEase` curves: In = `m(1 − ease(p))`, Out = `m(easeIn(p))`, video Combos play in/out motions over the whole clip
  (`AnimationPickerSection` sets duration = clip), sticker/text Loops are periodic. `AnimatedLayerState.blur` (gaussian sigma in
  canvas heights) becomes stacked `montage.effect.blur` passes and `reveal` (wipe insets) composes with the crop
  (`CropRect.revealing`) in `FrameRenderer.prepareLayer`. Text: W7 registers per-glyph descriptors in the same registry.
- **Keyframes**: `KeyframeTools.swift` (Core): `EasingPreset.all` (CapCut 14 + extras; `Easing` gained `.bounceOut/.elasticOut`),
  `Easing.controlPoints/speedSamples`, `Clip.copyKeyframes/pasteKeyframes/resetKeyframes/setEasing`, `MotionPath.path`.
  UI `MontageUI/Keyframes`: `store.keyframeUI` (clipboard, panel), ⌘C on a selected keyframe / ⌘V at the playhead, ⌥K keyframe
  panel (NSPanel: dope sheet + bezier/speed curve editor), ⇧⌥K add keyframe, `MotionPathDrawing` (called from
  `CanvasOverlayView.draw`). Text-style `ParamKey`s (`text.fontSize`, stroke, background, shadow, spacing) are animatable.
- **Lottie** (`MontageEngine/Lottie`): `LottieAnimation` parses a Bodymovin subset; `LottieRenderer` draws frames with Core
  Graphics; `LottieLibrary` caches animations and per-frame textures. `StickerDescriptor.Source.lottie` stickers loop from the
  clip start (`TextRasterizer.sticker(time:)`). Bundled JSON: `MontageEffects/Resources/Lottie`, generated by
  `scripts/make_lottie_stickers.py`.
- UI tests: `app/Tests/UIScripts/w5_*.json` (drop / duration / apply to all, Transitions tab, In/Out/Combo, keyframe add + ease);
  under `--uitest` the keyframe panel is an overlay in the test window (`EditorView`), never an on-screen NSPanel.
- `--player-state` (screenshots) also takes `transition=<name>`, `anim=in|out|combo:<name>`, `kfdemo`, `kfpanel`.

## 18. Known gaps (foundation)

Speed-curve editor UI, on-canvas crop handles, home screen and settings window, audio effects chain, editing inside compound clips (UI), pen/text/brush masks, rotation in stabilization, auto beat detection, and the Templates/Library content.
