# Qt 6 (QML / Qt Quick) + C++ + FFmpeg — prototype report

Stack: Qt 6.12 (Homebrew), QML/Qt Quick on the Metal RHI backend, C++20/Objective-C++, FFmpeg 9 (libav*) + VideoToolbox,
ONNX Runtime 1.31 (CoreML EP), whisper.cpp 1.9.5 (ggml Metal), Rubber Band 4 + miniaudio, Qt Linguist. CMake + Ninja.

## What is implemented (production code paths, not mock-ups)

| Spec | Implementation |
|---|---|
| P1 Preview | `ClipDecoder` (one thread per clip): FFmpeg demux + **VideoToolbox hwaccel**; frames stay `CVPixelBuffer`s (`AV_PIX_FMT_VIDEOTOOLBOX`) in a bounded queue (4). `Compositor` wraps each NV12/P010 plane **zero-copy** (`CVMetalTextureCache` → `MTLTexture` → `QRhiTexture::createFrom`), one QRhi pipeline (YCbCr→RGB BT.709, brightness, saturation, opacity, premultiplied over), one draw per layer. Hosted in a `QQuickRhiItem` with a fixed 1920×1080 colour buffer inside a QML window. |
| P2 Scrub | GOP-aware exact seek per decoder (previous keyframe, decode-and-discard), seek generations so stale frames are never shown; latency = seek request → `frameSwapped` of the frame containing all 4 exact layers. |
| P3 Export | Same `Compositor` on a standalone offscreen **Metal QRhi**; render targets are IOSurface `CVPixelBuffer`s (BGRA pool) handed **directly** to `h264_videotoolbox` as VT frames: decode → composite → encode never touches CPU pixels. libavformat MP4; bench verifies with ffprobe (h264 1920×1080, 300 frames). |
| P4 Timeline | `TimelineCanvas` (C++ `QQuickItem`, scene-graph, **no QML item per clip**): per-track binary search → only visible clips produce geometry; 1 vertex-coloured node (lanes/ruler/clips), 1 textured node for all filmstrip tiles (1 atlas → 1 draw call), pooled `QSGTextNode` labels (glyphs reused, only transforms change). 500 clips/6 tracks; QML `ParallelAnimation` scroll+zoom 5 s; fps = swaps/s. |
| P5a Segmentation | VT decode → `sws_scale` NV12→RGB 512×288 (CPU) → **ORT CoreML EP** (MLProgram, units ALL, free dims pinned → static shapes, compiled-model cache) running **MODNet** (25 MB). E2E fps over 300 frames after 3 warm-up. |
| P5b STT | whisper.cpp **large-v3-turbo q5_0** (547 MB), Metal + flash-attn, beam 5, fr, token timestamps merged to word timestamps (`screenshots/stt_words.json`); WER in C++ vs `bench/speech_fr.txt`. |
| P6 Audio | AAC → swresample → **Rubber Band R3 real-time** on a feeder thread → lock-free SPSC ring → **miniaudio** CoreAudio callback (no locks/allocs). Video clock derived from samples played (audio-master sync). Auto-verified: ratio 1.49 (target 1.5), 440 Hz tone → 439.9 Hz. |
| i18n | `qsTr` everywhere in QML, `qt_add_translations` → embedded `.qm`, French `.ts` with plural forms. `--lang fr` or system locale; verified by screenshot ("Lecteur", "4 calques · aperçu 1080p"). |
| Metrics | In-process `proc_pid_rusage` sampling of the app **plus VTDecoderXPCService / VTEncoderXPCService / MTLCompilerService helpers spawned after launch** (HW decode runs out-of-process). cold_start = kernel process start → first composited frame swapped. |

Single binary: `Montage --mode preview|timeline|export|seg|stt|audio [--lang fr] [--screenshot x.png]`.

## Smoke-test numbers (NOT benchmark results: 1–3 s runs on an M1 Pro loaded by other agents' builds)

| metric | smoke value |
|---|---|
| preview_fps / dropped | 29.5–29.7 / 0 (one early run under heavy load: 4.7 fps, 75 drops — see risk 2) |
| preview_cpu_pct | 24–29 % of one core (app + VT helpers) |
| preview_rss_mb | 235–480 MB mean, ~500 MB peak |
| scrub_ms p50 / p95 | 82–102 / 125–131 ms |
| export_seconds | 0.68–0.73 s for 1 s of output incl. setup (~3× realtime) |
| timeline_fps | 116–119 (120 Hz display; updatePaintNode 0.03–0.16 ms) |
| seg_fps | 40–45 E2E, 21 ms inference (CPU EP 6.9 fps; ANE-only 26 fps) |
| stt_rtf | 0.12–0.17 on a 10 s excerpt (perfect text); model load 0.45 s warm, 15 s first run (Metal kernel compile) |
| audio_stretch_ok | 1 (0 underruns) |
| cold_start_ms | 440–810 to first composited 4×4K frame |
| app_size_mb | 242.8 (macdeployqt, untrimmed) |

## Strengths
- **Native fast paths inside the framework**: RHI exposes the `MTLDevice` and imports foreign `MTLTexture`s, so VT → compositor is truly zero-copy in preview *and* export with one shared compositor. `.mm` files live in the same target: Vision, Core ML, AVFoundation, ScreenCaptureKit, SpeechAnalyzer are one `#import` away.
- **Same renderer offscreen** (`QRhi::create(Metal)` + offscreen frames) → export, preset thumbnails and CI pixel tests share code (req. 11).
- **Timeline at display rate for ~0.1 ms CPU/frame**; design scales to 30+ tracks, waveforms, keyframes.
- **C/C++ ecosystem** covers most of the 434 features natively: FFmpeg, HarfBuzz, libass, OCIO, OTIO, RNNoise/DeepFilterNet, libebur128, OpenCV, rlottie, ORT, whisper.cpp. Real-time audio thread with no GC.
- **i18n first-class**: Linguist, plurals, lupdate from QML/C++, runtime retranslate, RTL, accessibility on custom items.
- **Cross-platform**: same RHI code on D3D12/Vulkan; only decode-import and encoder names are per-OS.
- **Agent-friendly**: CLI build (configure 10 s, full build 7–30 s, incremental <5 s), headless modes, `grabWindow()` screenshots (includes RHI content), QTest/Qt Quick Test, logging categories. All metrics here produced from the terminal.

## Weaknesses / risks
1. **Scrub misses <50 ms** for exact seeks on 4 simultaneous 4K HEVC streams (~90–100 ms p50). Hardware-bound: FFmpeg's VT hwaccel is synchronous (~8 ms/4K frame, 1 in flight per decoder; 121 fps single-stream) and a seek decodes ~6 P-frames × 4 streams (GOP 12). Needed in production anyway: keyframe-first then refine, proxy/all-intra scrub cache, and a native async `VTDecompressionSession` decoder (~400 LOC Obj-C++).
2. **Video presentation goes through the Qt Quick render loop** (vsync-throttled, threaded). A render-thread stall delays video; one smoke run under load gave 4.7 fps before stabilising at 29.6/0. Must be validated on an 8 GB Air; fallback is a dedicated `CAMetalLayer` presenter.
3. **No mipmaps on downscale** (aliasing) and **no colour pipeline** out of the box: HDR/10-bit/OCIO/EDR is hand-written shader + metadata work (RGBA16F/RGB10A2 targets exist).
4. **QRhi is semi-public** (`Qt6::GuiPrivate`), compatibility only within a minor series.
5. **Deployment**: macdeployqt on Homebrew Qt gives 243 MB in 4 min (unused Controls styles, Widgets, Multimedia, 32 MB ICU data, GPL x265, full brew FFmpeg tree). Curated build estimated 80–110 MB + models. Licences: brew FFmpeg is GPL → need LGPL build; **Rubber Band is GPL** (commercial licence or SoundTouch LGPL); Qt LGPLv3/commercial.
6. **ORT CoreML EP is not zero-copy** (CPU tensors, CPU preprocessing). For real-time cutout, Vision/Core ML direct (CVPixelBuffer in/out) via Obj-C++ is better and easy here. RVM failed CoreML compile (dynamic recurrent shapes) and ran mostly on CPU (~20 fps).
7. Two skill sets needed: QML for panels (CapCut-like UI is very doable) and C++ scene-graph/RHI for every hot view (player, timeline, scopes, waveforms, curves).
8. Environment: Homebrew Qt 6.7 was broken (linked to a removed ICU); upgraded to 6.12 and installed cmake, ninja, onnxruntime, rubberband. Product should pin Qt (aqtinstall/vcpkg).

## Fit vs FEATURES.md §23
1 compositor **strong** · 2 HW codecs **strong** · 3 scrubbing **medium** (risk 1) · 4 timeline **strong** · 5 ML breadth **strong** · 6 RT segmentation **medium/strong** · 7 pro audio **strong** · 8 time remap neutral · 9 text strong-ish (HarfBuzz, distance-field glyphs; per-glyph export animation custom) · 10 colour medium (manual) · 11 keyframes neutral (shared C++ model) · 12 jobs **strong** · 13 memory **strong** (no browser runtime) · 14 undo neutral (QUndoStack) · 15 desktop/i18n **strong** · 16 interchange strong (OTIO, libass, Lottie).

## Numbers
- LOC: ~2,470 (C++/Obj-C++ ~2,150, QML 124, GLSL 40) + bench.sh 83 + CMake 65.
- Build: configure 10 s, full release 7–30 s, incremental <5 s; macdeployqt 4 min (bench.sh redeploys only when the binary changed; prebuilt `deploy/` present).
- Models: MODNet 25 MB, whisper large-v3-turbo q5_0 547 MB (in `models/`, re-downloaded by bench.sh if missing).
- Effort: ~1 engineer-day; first export was correct on first run. Debugging limited to QML object lookup (Loader items aren't QObject children) and ggml backend plugin loading.
- bench.sh: full run estimated ~2–3 min; `SMOKE=1 ./bench.sh` = 45 s mini run.

## Files
`CMakeLists.txt`, `bench.sh`, `src/ClipDecoder.*`, `src/Compositor.mm`, `src/PreviewItem.mm`, `src/Exporter.mm`, `src/TimelineCanvas.*`, `src/AudioEngine.*`, `src/Segmenter.*`, `src/Transcriber.*`, `src/Metrics.*`, `src/Engine.*`, `src/main.cpp`, `qml/`, `shaders/`, `i18n/montage_fr.ts`, `screenshots/` (from bench).
