# Prototype report: Rust engine + Tauri 2 web UI (`tauri-rust`)

Run `./bench.sh` for the full benchmark or `SMOKE=1 ./bench.sh` for a short smoke run.
- Output: JSON lines on stdout, also written to `results.jsonl`.
- Logs: `out/bench.log`.

## 1. What was built

| Spec | Implementation (the code paths a production app would use) |
|---|---|
| P1 Preview | **Decode:** AVFoundation `AVAssetReader`, which uses VideoToolbox hardware HEVC decode. It outputs IOSurface-backed **NV12** `CVPixelBuffer`s with no conversion and no copy (`engine/src/decode.rs`). **GPU import:** `CVMetalTextureCache` → `MTLTexture` → `wgpu::Texture` via `create_texture_from_hal`, with zero copy (`gpu.rs`). **Compositor:** a WGSL pass that converts YUV to RGB (BT.709) and applies per-layer transform, rotation, opacity 0.8 and saturation/brightness, blended as premultiplied "over". It renders a 1920x1080 comp offscreen, then letterbox-blits it to the surface (`compositor.rs`). **Playback:** one decode-ahead thread per clip with a bounded queue of 4 frames. A player thread paces output at 30 fps and counts late layers or skipped slots as dropped frames (`source.rs`, `player.rs`). |
| Presentation | A **native layer-backed `NSView` with a `CAMetalLayer`** sits in the window *below* a transparent WKWebView (`transparent:true` + `macOSPrivateApi`). The web UI leaves a transparent hole for the player and sends only its rectangle over IPC (`set_player_rect`). The render thread draws straight into the layer's drawables. **No frames cross IPC.** HTML can draw on top of the video (the transport bar does). I checked the hierarchy with `MONTAGE_DEBUG=1`: `[NSView(metal), WryWebView]` inside `WryWebViewParent`, `_drawsBackground=false` (`present.rs`). |
| P2 Scrub | Each clip has a second, dedicated **random-access decoder** (`supportsRandomAccess` + `resetForReadingTimeRanges`), so seeking never tears down the playback decoder. All 4 clips seek in parallel. The measurement runs until composite, present and GPU completion. |
| P3 Export | The same compositor renders into IOSurface BGRA buffers from the `AVAssetWriterInputPixelBufferAdaptor` pool. AVAssetWriter encodes H.264 on the VideoToolbox hardware encoder into MP4. A 2-deep pipeline overlaps GPU and encoder work (`export.rs`). ffprobe confirms the output is h264, 1920x1080, with the expected frame count. |
| P4 Timeline | Tauri 2 + TypeScript (Vite, no framework). One canvas 2D draws 500 clips on 6 tracks (rects, thumbnail placeholder, clipped labels, ruler, playhead). Virtualization uses a binary search per track over clips sorted by start time. The bench runs a 5 s scroll+zoom animation and counts rAF frames (`app/src/timeline.ts`). |
| P5a Segmentation | **ort 2.0.0-rc.14 + CoreML EP** running Robust Video Matting (MobileNetV3; recurrent, so masks are temporally stable). Input is full 1080p from the same decoder as BGRA; NCHW conversion takes 0.6 ms/frame. **Problem with the stock model:** RVM ships with dynamic shapes. CoreML rejects parts of it (E5RT errors), and the output silently *differed* from the CPU EP. **Fix:** `tools/models/fix_rvm.py` freezes it to static shapes (src 1920x1080, baked downsample_ratio=0.25, fixed recurrent-state shapes) and runs onnxsim. After that, CoreML output matches CPU output. |
| P5b STT | **whisper-rs 0.16** (whisper.cpp, Metal + flash-attn) with `ggml-large-v3-turbo-q5_0` (547 MB). Greedy decoding, language fr. Token timestamps are grouped into words. WER is measured against `bench/speech_fr.txt`. |
| P6 Audio | **cpal + Signalsmith Stretch** (`signalsmith-stretch` crate, header-only C++). It runs **inside the real-time callback** with no locks or allocation. Rate is an atomic, so curve speed works by changing the input/output ratio per block. Check: 440 Hz source tone → output **440.0 Hz**, consumed/produced ratio **1.500**, while the 4-layer video plays at 1.5x. |
| CPU/RSS | `tools/procstat` (Rust, `proc_pidinfo`). It sums the app, its descendants, and the **XPC helpers launched for it**: WebKit WebContent/GPU/Networking, `VTDecoderXPCService` and the audio helper. These helpers are children of launchd, so procstat identifies them as "new since launch" plus a known name. `responsibility_get_pid_responsible_for_pid` would not work: it attributes everything to the terminal. |
| Cold start | Time from process launch by bench.sh until both `ui_ready` from JS **and** the first composited 4x4K frame presented. Median of 3 runs. |
| i18n | en/fr catalogs with interpolation and `Intl.PluralRules`. Language follows the system or `MONTAGE_LANG`, and can be switched live from a dropdown. |

How the runs are split:
- **Headless engine CLI** (`target/release/montage-cli export|seg|stt`): same engine crates as the app. Export and AI would run as background jobs this way.
- **App bench modes** (env var `MONTAGE_BENCH=preview|scrub|timeline|audio|cold`): the app itself runs preview, scrub, timeline, audio and cold start.

## 2. Smoke-test numbers (NOT benchmark numbers)

Measured on an M1 Pro with other prototypes compiling at the same time, using `SMOKE=1` (3 s preview, 10 seeks, 1 s export, 20 seg frames).

| metric | value | note |
|---|---|---|
| preview_fps | 29.98 | |
| preview_dropped_frames | 0 | |
| preview_cpu_pct | 12–26 % | Sum of 6 processes: app 8–18 %, VTDecoderXPCService 4–7 %, WebKit ~0.5 %. Noisy because of concurrent load. |
| preview_rss_mb | ~300 | App ~130, VTDecoder 80, three WebKit processes ~75. Part of the IOSurface memory is probably accounted elsewhere (GPU). |
| scrub_ms_p50 / p95 | 45 / 72–76 | 4K HEVC, GOP 12 |
| export_seconds (1 s clip) | 0.48–0.70 | includes opening 4 assets |
| timeline_fps | 60.4 | Capped: WKWebView rAF is 60 Hz even on the 120 Hz panel. |
| seg_fps | 21–24 | RVM at 1080p. ComputeUnits All/GPU/ANE all give about the same, so the model probably runs partly on CPU. |
| stt_rtf | 0.052–0.061 | 45 s of French in ~2.5 s. First model load is 8 s (Metal shader compile). |
| stt_wer_estimate | 0.031 | The transcript is essentially perfect; the errors are number/"4K" normalization. Word timestamps look correct. |
| audio_stretch_ok | 1 | |
| cold_start_ms | 550–660 warm, 1.4–1.9 s first launch | |
| app_size_mb | 15.7 | .app without AI. ort + whisper add ~18 MB of binary (the CLI is 33.7 MB). Models: RVM 14 MB, whisper 547 MB. |

`SMOKE=1 ./bench.sh` takes ~150 s, including a no-op incremental build. The full run should take ~3–4 min.

## 3. Build and development effort

**Toolchain**
- Global rustc is 1.63. `rust-toolchain.toml` pins **1.99.1** for this folder only, so the global default is untouched. Note that rustup self-updated during the install.
- whisper.cpp needs cmake. It is installed in a local venv (`.venv`), along with onnx/onnxsim for the model-freeze script.
- Node 20 for the UI.

**Build times** (M1 Pro, shared with other agents)
- Cold workspace build: ~4–6 min.
- `tauri build`: ~2.7 min cold. It uses the `custom-protocol` feature, which means a second build of tauri.
- ort-sys downloads a prebuilt static ONNX Runtime.
- Incremental engine builds: a few seconds. Final link with thin LTO: 10–20 s.

**LOC written:** ~2,900 in total.
- Rust engine: ~1,300
- Tauri shell: ~330
- AI: ~330
- procstat: ~150
- TS/CSS/HTML: ~450
- bench.sh: ~160
- model script: ~40

**Friction hit along the way**
- objc2 0.3 crates gate cross-framework types behind features. Without them, methods simply "don't exist".
- wgpu 30 had new required fields and API moves: `color_space`, `queue.present`, `apply_limit_buckets`, `CurrentSurfaceTexture`.
- whisper.cpp's `@available` checks need `libclang_rt.osx.a`, linked explicitly in `ai/build.rs`.
- ort rc.14 requires an explicit `Environment`.
- CoreML EP produced wrong results silently, with only stderr noise.
- **FFmpeg was not used.** Homebrew ships FFmpeg 9.0, which the Rust bindings (ffmpeg-next) don't support yet. Going directly to AVFoundation/VideoToolbox through objc2 was the cleaner zero-copy route anyway. An FFmpeg fallback for exotic formats (LGPL dylib) is still needed and was not prototyped.
- The unsafe code is small and contained in `decode.rs`, `gpu.rs`, `present.rs` and `export.rs`.

## 4. Fit for the stack-sensitive requirements (FEATURES.md §23)

| # | Requirement | Fit | Notes |
|---|---|---|---|
| 1 | Real-time GPU compositor, zero-copy decode→texture | **Strong** | Zero-copy IOSurface NV12 → wgpu texture is proven. wgpu provides WGSL, compute (for scopes) and float formats. If wgpu lacks something, there is an escape hatch to raw Metal (`as_hal`). Cost: 4x4K @30 fps for 8–18 % app CPU. |
| 2 | Hardware codecs via the OS | **Strong** (macOS) | AVFoundation and VideoToolbox are first-class through objc2. ProRes, HDR and alpha are just settings. Other platforms need FFmpeg hwaccel behind the same reader trait. |
| 3 | Instant scrubbing (<50 ms) | **Medium** | p95 is ~75 ms because AVAssetReader always decodes from the keyframe. Fix is engine work, not a stack limit: direct `VTDecompressionSession` with a sample cursor, frame and thumbnail caches, proxies, and keyframe-only scrubbing while dragging. |
| 4 | 500-clip timeline at 60 fps | **Good, with caveats** | Canvas 2D holds 60 fps but rAF is capped at 60 Hz and JS GC pauses are a risk. For 30+ tracks with filmstrips and waveforms, move to WebGL2/WebGPU or draw the timeline natively with wgpu. |
| 5 | On-device ML runtime breadth | **Good** | ort/CoreML EP and whisper.cpp/Metal work. Vision, Speech, Translation and VTFrameProcessor are reachable via objc2. Swift-only APIs (Foundation Models) need a small Swift shim. CoreML EP is fragile with dynamic shapes. |
| 6 | Real-time segmentation in preview | **Medium** | 21–24 fps at 1080p; at 540p preview resolution it should be about 4x faster. ORT works on CPU tensors, so each mask needs one copy to the GPU. The better macOS path is Vision `VNGeneratePersonSegmentationRequest`, which returns a CVPixelBuffer that can go to wgpu zero-copy. |
| 7 | Pro audio engine | **Strong** | Real-time-safe Rust callback with no GC. Signalsmith supports curve speed and pitch/formant shifting. Also available: nnnoiseless and DeepFilterNet (Rust). |
| 8 | Time remapping and interpolation | Good | Preview and export share one compositor, so results are identical. RIFE via ORT, or VTFrameRateConversion via objc2. |
| 9 | Text engine | **Medium (effort)** | GPU text for export must be built: cosmic-text/swash or CoreText, plus MSDF. This is the biggest DIY area. |
| 10 | Color pipeline / HDR / EDR | Good | Rgba16Float and `SurfaceColorSpace` are available. EDR is one call on our own CAMetalLayer. |
| 11 | Universal keyframe system | Neutral | Rust model shared with the headless CLI. |
| 12 | Background job system | Strong | Threads plus a separate CLI process. The webview stays responsive because it is a separate process. |
| 13 | 8 GB unified-memory discipline | Good | ~300 MB total during 4x4K preview, of which WebKit is ~75 MB. Decode queues are bounded. |
| 14 | Undo/redo, autosave, crash recovery | Neutral | `im`/`rpds` for structural sharing, serde for saving. |
| 15 | Native desktop integration and i18n | **Medium** | Tauri covers menus, multiple windows, drag and drop and dialogs. ScreenCaptureKit and camera need objc2. Accessibility for canvas-drawn widgets needs an ARIA mirror. |

## 5. French localization

- **UI side:** FormatJS / ICU MessageFormat in TypeScript.
- **Rust-side strings:** Fluent (`fluent-rs`) with the same keys.
- **Locale and switching:** Tauri passes the system locale. Switching at runtime is just a re-render, which the prototype already does.
- **From WebKit for free:** French hyphenation, plurals and number/date formatting.

## 6. Cross-platform story

- **Already portable:**
  - Tauri UI (WebView2 on Windows, WebKitGTK on Linux).
  - wgpu (D3D12 and Vulkan backends).
- **macOS-only today:**
  - AVFoundation decode/encode.
  - CVMetalTextureCache interop.
  - The layer-under-webview presentation trick.
- **Equivalents elsewhere:**
  - Decode: Media Foundation/D3D11 on Windows, VA-API/DMABUF on Linux, with FFmpeg hwaccel as the common fallback.
  - Presentation: WebView2 composition-mode interop on Windows, which is painful. WebKitGTK on Linux is the hardest case.
- **Estimate:** build macOS-first behind traits (`VideoReader`, `GpuInterop`, `Presenter`). Each extra OS then costs about 1–2 engineer-months.

## 7. How well an AI agent can build and verify UI in this stack

**What works well**
- Every step runs from the CLI.
- The app is fully driven by environment variables, and metrics come back on stdout.
- Engine output is easy to verify headlessly (CLI render/export plus ffprobe or pixel checks). I checked an exported frame visually.
- A golden-image test harness would be straightforward.
- The web UI can be tested with Playwright in a normal browser, with `invoke` mocked.

**What's hard**
- **No real-window screenshots here.** `screencapture` needs the Screen Recording permission, and this terminal doesn't have it. Workarounds: read back the comp texture to a PNG, use `WKWebView.takeSnapshot` (but it doesn't include the native video), or grant the permission once on CI.
- Three kinds of errors to deal with: TS, Rust, and objc2 FFI.
- API churn in objc2 and wgpu meant repeatedly reading crate sources.
- CoreML EP failures are silent.

## 8. Risks and weaknesses

1. **Scrub p95 is above the 50 ms target** on 4K HEVC, because AVAssetReader always decodes from the keyframe. Fixing it requires a direct VideoToolbox decoder plus caches and proxies.
2. **The native-view-under-webview presentation is macOS-specific and somewhat hacky.**
   - It depends on wry's view hierarchy (`WryWebViewParent`).
   - Transparency needs `macOSPrivateApi`, which raises a Mac App Store concern.
   - Detached player windows each need their own native plumbing.
   - Rect sync goes over IPC, so the video can lag the layout by a frame during live resizes.
3. **WKWebView caps rAF at 60 Hz** and has GC pauses. A heavy timeline could force native wgpu drawing, which would erode the benefit of the web UI.
4. **ORT + CoreML EP is fragile.** Dynamic shapes give wrong results without a hard error, so models must be frozen offline. Masks are CPU tensors (one copy per frame). Prefer Vision/CoreML via objc2.
5. **Two UI technologies (web + wgpu).** On-canvas handles, inline text editing and snap guides need a careful split between them. HTML-over-video was verified by view hierarchy, not by screenshot.
6. **Ecosystem churn.** wgpu has breaking releases about every quarter, ort is still at RC, and objc2 has feature gating. Versions must be pinned.
7. **The preview clock is wall-clock in this prototype.** Production should slave video to the cpal audio clock, which is straightforward.
8. **Not prototyped:**
   - HDR/10-bit
   - ProRes alpha
   - FFmpeg fallback
   - Windows/Linux presentation
