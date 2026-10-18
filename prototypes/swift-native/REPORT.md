# Swift-native prototype — report

Stack: SwiftUI shell + AppKit/Metal views, AVFoundation/VideoToolbox, a custom Metal `AVVideoCompositing`,
AVAssetReader→AVAssetWriter export, Vision, SpeechAnalyzer (macOS 26) with whisper.cpp as the fallback, and
AVAudioEngine/AVAudioUnitTimePitch. Built with SwiftPM only (`swift build`, `swift test`), no Xcode project.
Toolchain: Xcode 26.6 / Swift 6.3.3 (Swift 5 language mode), macOS 26.4.1, M1 Pro 16 GB.

## Layout
```
Package.swift                 MontageEngine (library, no UI) + MontageBench (app executable "Montage") + tests
Sources/MontageEngine/        Compositor.swift (Metal AVVideoCompositing), MetalContext, Shaders (runtime-compiled MSL),
                              ProjectBuilder (AVComposition), Exporter (reader→writer, HW H.264), Segmenter (Vision),
                              Transcriber (SpeechAnalyzer / SFSpeechRecognizer / whisper.cpp), AudioStretch, WER, Metrics
Sources/MontageBench/         main.swift (bench modes), PlayerView (CAMetalLayer + display link + AVPlayerItemVideoOutput),
                              TimelineView (instanced Metal canvas + Core Text glyph atlas), Shell.swift (SwiftUI editor shell)
Resources/                    Info.plist, en.lproj / fr.lproj Localizable.strings
Tests/MontageEngineTests/     WER unit test, render test (0.5 s export + pixel assert), time-stretch pitch test
bundle.sh                     release build + assemble build/Montage.app (ad-hoc signed)
bench.sh                      build + P1–P6, JSON lines → stdout + results.jsonl. `BENCH_SMOKE=1` gives tiny sizes for testing the script.
models/                       ggml-large-v3-turbo-q5_0.bin (whisper.cpp model, 547 MB, downloaded at dev time, not bundled)
```
LOC: about 1,520 lines of Swift (engine about 800, app/bench about 600, tests about 60), plus about 70 lines of shell.
Build: clean release build 11 s; incremental build 2 s; `swift test` 17 s (includes a debug build).

## What each benchmark exercises (production code paths)
- **P1 preview.** AVMutableComposition (4 × 4K HEVC tracks) + `AVMutableVideoComposition` with
  `customVideoCompositorClass = MetalCompositor`. VideoToolbox decodes into IOSurface-backed 4:2:0 buffers.
  The compositor wraps the Y and CbCr planes as `MTLTexture` through `CVMetalTextureCache` (zero-copy, no BGRA
  conversion) and draws one quad per layer. Each quad applies the transform, BT.709 YUV→RGB, saturation and
  brightness, and opacity 0.8 with alpha blending. Frames come out of `AVPlayerItemVideoOutput`, are pulled on
  `NSView.displayLink` (vsync) and drawn into a `CAMetalLayer`. **Frames are counted only when
  `MTLDrawable.addPresentedHandler` reports a real on-screen presentation time.** Dropped frames =
  wall-clock-expected frames − frames presented. CPU and RSS come from `ps` sampling of the app plus any
  `VTDecoderXPCService`/`VTEncoderXPCService` instances spawned during the run (one VT decoder helper is counted).
  CPU% includes the composition, decode orchestration and the audio pipeline.
- **P2 scrub.** `seek(to:toleranceBefore:.zero,toleranceAfter:.zero)` to 50 seeded random frame-aligned times.
  Latency runs from the seek call to the presentation of a frame whose display time is within half a frame of the
  target. Extra metric `scrub_keyframe_ms_*` uses infinite tolerance, which is what you would use during a fast
  drag before refining.
- **P3 export.** `AVAssetReaderVideoCompositionOutput` (same MetalCompositor, so preview and export share one
  renderer) + `AVAudioMixOutput` → `AVAssetWriter`. H.264 High at 12 Mbps with
  `RequireHardwareAcceleratedVideoEncoder`, plus AAC, BT.709 tags. bench.sh checks the output with ffprobe
  (h264, 1920x1080, frame count).
- **P4 timeline.** SwiftUI editor shell with the Metal timeline bridged through NSViewRepresentable. The timeline
  has 500 clips on 6 tracks and draws in **one instanced draw call per frame**. Clips are virtualized by binary
  search per track. Each clip gets a rounded body (SDF), a striped thumbnail placeholder, and a label from a Core
  Text–rendered glyph atlas. A ruler with adaptive ticks and a playhead are also drawn. The animation runs an
  exponential zoom from 8 to 200 px/s (2 cycles) plus a scroll across the whole timeline for 5 s. Fps comes from
  presented handlers. The display is 120 Hz ProMotion, so expect about 120 fps. Extras: `timeline_frame_cpu_ms_p95`
  (CPU time to build and encode a frame) and `timeline_display_hz`. `--snapshot x.png` re-renders the last frame
  offscreen into a PNG, so an agent can verify visually without the Screen Recording permission.
- **P5a segmentation.** `VNGeneratePersonSegmentationRequest` with `VNSequenceRequestHandler` on 420f
  IOSurface frames from AVAssetReader. The OneComponent8 mask is a CVPixelBuffer that can be wrapped as a
  texture for the compositor without a copy. `seg_fps` = `.balanced` (300 frames). Extras: `.fast` (300 frames),
  `.accurate` (30 frames) and first-frame (model load) latency. Decode and inference run sequentially, not
  pipelined. Quality is not assessed (there is no person footage).
- **P5b STT.** `SpeechAnalyzer` (macOS 26) with word-level `audioTimeRange`. It prefers `SpeechTranscriber` and
  falls back to `DictationTranscriber`. On this machine the fr-FR SpeechTranscriber asset is **not installed**:
  installing it means an OS-managed download through `AssetInventory`, which I did not trigger because of the
  no-network rule. So the bench uses DictationTranscriber, whose fr-FR model is already installed.
  **SpeechAnalyzer needed no TCC prompt from the CLI.** Next in line is SFSpeechRecognizer on-device; its
  authorization request is time-boxed to 3 s so it never blocks. The last fallback is whisper.cpp. Bench also
  reports whisper.cpp large-v3-turbo-q5_0 (Metal) as `stt_rtf_whisper` / `stt_wer_whisper`, for comparison.
  WER is a rough Levenshtein over normalized words against bench/speech_fr.txt.
- **P6 audio.** Live check: AVPlayer on the same composition with `audioTimePitchAlgorithm = .spectral`, played
  at rate 1.5 while video renders. It checks the item-time rate (1.5) and that video keeps presenting about 45
  fps. Offline proof: `AVAudioEngine` manual rendering through `AVAudioUnitTimePitch(rate: 1.5)`. On the 440 Hz
  tone, output pitch is still 440 Hz (zero-crossing estimate) and the input-consumed / output ratio is about 1.5.
  `audio_stretch_ok` = 1 only if all of these hold.
- **cold_start_ms.** Measured from process start (`sysctl` `p_starttime`) to the first presented frame of the
  SwiftUI shell with the 500-clip timeline. Median of 3 runs; the runs are warm on disk.
- **app_size_mb.** Size of the .app bundle. All frameworks are system frameworks; the whisper model is excluded.

## Smoke-test numbers (NOT benchmark results — short runs, other prototypes building concurrently, on battery)
| metric | smoke value |
|---|---|
| preview_fps / dropped | 29.9 fps / 0 (3 s) — compositor 1.0–1.3 ms/frame CPU+GPU latency |
| preview_cpu_pct / rss | 8–22 % / ~205 MB |
| scrub p50 / p95 (exact) | ~41 / ~91 ms (5–8 seeks); keyframe-tolerant ~33 / ~41 ms |
| export 1 s | 0.66–1.7 s (includes 4× HEVC decoder spin-up; 10 s run will show steady state) |
| timeline_fps | 119–120 fps on 120 Hz; frame build+encode < 0.2 ms CPU |
| seg_fps balanced / fast / accurate | ~45–54 / ~100 / ~16 fps (20 frames) |
| stt_rtf / WER (DictationTranscriber) | 0.05–0.06 / 0.126 |
| stt_rtf / WER (whisper.cpp large-v3-turbo q5) | 0.08–0.10 / 0.031 |
| audio_stretch_ok | 1 |
| cold_start_ms | ~355–420 ms |
| app_size_mb | 0.69 MB |

In one smoke run during heavy concurrent load (another agent's rustc, CrowdStrike, battery at 19%), preview
dropped to 10 fps, the timeline to 64 fps and P6 video to 20 fps. Standalone re-runs were back to 30 / 120 / 45.
The bench now counts frames by on-screen presentation timestamp, and emits `*_window_visible`, because an
occluded window gets throttled by macOS and would make the numbers meaningless.

## Fit for the stack-sensitive requirements (FEATURES.md §23)
1. **GPU compositor.** Best possible fit. Decode→texture is zero-copy by construction (IOSurface/CVMetalTextureCache)
   and the compositor is plain Metal. Blend modes, masks, LUTs, half-float/EDR, and compute scopes all go through
   the same API. The same compositor serves AVPlayer, export and thumbnails, so preview and export are
   deterministic and identical.
2. **HW codecs.** VideoToolbox is native: H.264/HEVC 8/10-bit, ProRes incl. 4444/alpha, HDR tags. FFmpeg is still
   needed for exotic formats, either through a C target in SwiftPM or a remux/transcode-to-proxy job.
3. **Scrubbing.** Exact seeks across 4 × 4K HEVC are already about 40 ms p50 with AVPlayer. For 30+ track
   projects, decoder pools on AVAssetReader/VTDecompressionSession plus thumbnail and proxy caches are
   standard engineering.
4. **Timeline.** The Metal instanced canvas runs at display rate with near-zero CPU. The cost: everything is custom
   (hit-testing, text, accessibility). SwiftUI/AppKit widget trees would not scale to 500+ clips and were not used.
5. **ML breadth.** Strongest of any stack: Vision, SpeechAnalyzer, CoreML/ANE, MLX, MPSGraph, Translation,
   Foundation Models and VTFrameProcessor are first-party Swift APIs. ONNX Runtime and whisper.cpp link as C.
   Segmentation masks are CVPixelBuffers that go straight into Metal.
6. **Real-time segmentation.** `.balanced` already reaches about 45–54 fps at 1080p and `.fast` about 100 fps, even
   unpipelined, on M1 Pro. A base Air with fewer GPU cores will be lower; temporal smoothing is our own Metal
   pass.
7. **Audio.** AVAudioEngine plus AUTimePitch; curve speeds work by automating `rate` or through
   `AVMutableComposition.scaleTimeRange`. A sample-accurate, real-time-safe mixer is feasible in Swift (with care:
   no allocation or locks in render blocks) or as a small C++ core. AVPlayer's built-in stretch covers simple
   cases in both preview and export.
8. **Time remap.** `scaleTimeRange` plus the compositor handles freeze, reverse and curve speeds.
   VTFrameRateConversion (macOS 15.4+/26) is available for optical-flow slow motion.
9. **Text.** Core Text gives shaping, bidi, CJK and emoji for free. GPU rendering needs our own SDF atlas
   (the prototype already uses a Core Text glyph atlas).
10–16. Native: EDR/HDR (CAMetalLayer EDR, 10-bit CVPixelBuffers), menu bar, multi-window, ScreenCaptureKit,
    sandbox bookmarks, VoiceOver through NSAccessibility on custom views, and String Catalogs/`.strings` with ICU
    plurals. I'd estimate the large majority of the 434 features map directly onto Apple frameworks.

## French localization
Standard `.lproj/Localizable.strings` (a String Catalog `.xcstrings` would be used in production; SwiftPM-CLI support
for compiling catalogs into the bundle needs checking, so `.strings` is the safe CLI path). SwiftUI `Text("key")` and
`NSLocalizedString` resolve from the main bundle. The language follows the system and can be overridden per launch
(`-AppleLanguages "(fr)"`, verified: "Médias / Lecteur / Détails / Plan 445…"). Runtime switching without a relaunch
needs an app-level locale environment, which is standard but has to be designed in.

## Cross-platform
None. This is a macOS-only stack (the engine could reach iPadOS/iOS cheaply). A Windows/Linux port would mean
rewriting the UI and the media and ML layers. The only realistic mitigation is to keep the project model,
keyframe evaluation and timeline logic in portable Swift or C++. Swift on Windows exists, but AVFoundation,
Metal and Vision do not.

## AI-agent buildability and verification
- Fully CLI-driven: `swift build`, `swift test` (Swift Testing), `bundle.sh` to produce an .app. No .xcodeproj
  needed for this scope; a real app would still want Xcode for signing, entitlements, asset catalogs and String
  Catalogs (all doable through `xcodebuild`).
- Headless render tests work well: export a few frames, then pixel-assert them in `swift test`
  (`exportRendersComposedFrames`).
- Screenshots: `screencapture` fails without the Screen Recording permission. Instead the Metal views render
  offscreen to PNG (`--snapshot`), and `NSView.cacheDisplay` captures the SwiftUI chrome (Metal areas come out
  blank). An agent can verify the UI by reading these PNGs; I did this to check the FR labels and the timeline.
- Friction: Swift 6 strict concurrency conflicts with AVFoundation, Metal and display-link callbacks, so I used
  Swift 5 language mode. The Metal offline compiler is a separate Xcode 26 download (not installed here), so
  shaders are compiled at runtime from source; the system shader cache makes this about 1 ms after the first
  run. API-availability churn (macOS 26-only SpeechAnalyzer) needs `#available` fallbacks.

## Risks and weaknesses (honest)
- **No cross-platform path.** This is the main strategic cost.
- **Custom-drawn UI is a lot of work.** Timeline, canvas handles and the thumbnail and waveform LOD caches need
  their own hit-testing and NSAccessibility work. SwiftUI only helps for panels and inspectors, and it has
  performance cliffs with large lists and frequent updates (use AppKit or Metal where it matters).
- **AVFoundation is a black box in places.** AVPlayer decides its own decode-ahead and preroll. Frame-exact
  scrubbing across many long-GOP 4K streams on a base Air may need proxies and our own VTDecompressionSession
  pool. The AVVideoCompositing request model limits some things, such as multi-frame effects that need
  neighbouring frames; that would mean our own AVAssetReader-based render loop.
- **Downscaling without mipmaps.** Sampling 4K sources straight to 1080p aliases on high-frequency content (visible
  on the "life" layer). Production needs a mip or box-downsample pass, a small extra GPU cost.
- **The best fr-FR STT model needs an asset download.** SpeechTranscriber's fr-FR asset is an OS-managed download;
  the DictationTranscriber fallback has a WER of about 13% here vs about 3% for whisper large-v3-turbo. Whisper
  adds a 547 MB model to the app or to a first-run download. SpeechAnalyzer requires macOS 26, so older systems
  need the SFSpeechRecognizer path, which has a TCC prompt.
- **Swift 6 concurrency.** Language mode 5 hides data races that strict mode would catch. The engine will need a
  deliberate actor and queue design before it can move to Swift 6 mode.
- **Smoke numbers only.** Everything above came from a 16 GB M1 Pro under concurrent load. The 8 GB Air will have
  fewer GPU cores, a slower ANE path and a 60 Hz display, so the timeline will be capped at 60.
