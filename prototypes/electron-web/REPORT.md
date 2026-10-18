# Electron + web tech — prototype report

(Written by the orchestrator from the prototype agent's hand-back; the agent could not write .md files.)

**Stack**: Electron 44.9.0 (Chromium, Node 24) · TypeScript · React 19 · Vite/esbuild · WebCodecs (VideoToolbox HW decode/encode) · mediabunny 1.61 (MP4 demux/mux) · WebGPU compositor · Canvas2D virtualized timeline · Web Audio + Signalsmith Stretch (WASM AudioWorklet) · onnxruntime-node 1.30 in a utilityProcess (CPU/CoreML) + onnxruntime-web WebGPU alt · whisper.cpp (Metal) CLI sidecar.

## How to run
- `./bench.sh` — full benchmark (~2–3 min), writes `results.jsonl`. `./bench.sh --smoke` — short version (3 s preview, 10 seeks, 1 s export, 20 seg frames) → `results.smoke.jsonl`.
- Requires Node ≥ 22.12 (auto-picked from ~/.nvm) and `whisper-cli` (Homebrew whisper-cpp).
- Models auto-downloaded into `models/`: RVM 14 MB, whisper large-v3-turbo q5_0 547 MB.
- Each phase launches the packaged release app with `--bench=<phase>`; in-app watchdog + perl alarm timeouts; pkill after each phase.
- CPU/RSS summed across all processes (main, GPU, renderer, utility, network) using cumulative CPU time and RSS from `ps`.

## Smoke numbers (NOT a benchmark; M1 Pro, load average 9–15 from other prototypes)
| Metric | Value | Notes |
|---|---|---|
| preview_fps | 29.4 | 2/109 frames stale at start-up |
| preview_cpu_pct | 44% | summed over 12 processes; 100% = one core |
| preview_rss_mb | 573 (peak 605) | overcounted: shared pages counted per process |
| scrub p50 / p95 | 90 / 105 ms | 4× 4K HEVC, 12-frame GOP; decode-bound |
| export_seconds | 0.85 for 1 s | verified H.264 High 1080p30, 30 frames, visual check |
| timeline_fps | 119.8 | capped by 120 Hz display; draw avg 0.27 ms, p95 0.4 ms |
| seg_fps | 40–46 CPU | RVM 960×544 decode→mask; CoreML 29; ORT-web WebGPU 28.5 |
| stt_rtf | 0.09–0.11 | incl. process spawn + model load; 45.3 s audio |
| stt_wer_estimate | 0.03 | 120 words with DTW timestamps |
| audio_stretch_ok | true | 440 Hz → 440.3 Hz at 1.5x while video plays at 1.5x |
| cold_start_ms | ~470 median | 2.5 s first launch after build |
| app_size_mb | 360 | Electron framework 287 MB; app.asar 71 MB (27 MB droppable ORT-web wasm); ORT dylib 42 MB |

## Architecture (code paths we would keep)
- **Main process**: private `media://` scheme with range reads (short reads in one go, open-ended reads streamed & cancellable); export streamed to disk; STT sidecar; segmentation utility process.
- **Playback engine in a Worker**: decode, WebGPU compositing on OffscreenCanvas, frame clock — React work can't drop frames (took preview from ~23 to 29 fps under load).
- **Decoder**: keyframe-correct seeks, discard pre-roll, 5-frame queue per layer, decoder reused across seeks, forward seek within GOP keeps decoding.
- **Compositor**: zero-copy VideoFrame import into WebGPU; per-layer transform/opacity/brightness/saturation; same code for preview and export.
- **Export**: composite → HW H.264 (VideoToolbox) → mediabunny mux → streamed to disk.
- **Timeline**: single canvas, draws visible clips only.
- **Segmentation**: RVM with recurrent state, decodes next frame during inference; three switchable backends.
- **Audio**: WebCodecs audio decode → Signalsmith AudioWorklet; `schedule()` allows speed curves.
- **Localisation**: en/fr catalogues with plural rules, follows system language; production would use FormatJS/i18next.

## Fit vs stack-sensitive requirements (FEATURES.md §23)
1. Compositor: good (WebGPU/WGSL ≈ Metal expressiveness, zero-copy import). Gaps: HDR display control, no Metal-level memory control, frames cross into Chromium GPU process.
2. Codecs: H.264/HEVC HW decode+encode. No ProRes; 10-bit/HDR/alpha partial; FFmpeg would need a native addon/sidecar; Chromium caps HW decode sessions.
3. Scrub < 50 ms: not met with long-GOP 4K (~90 ms, 4 layers). Decode-bound → any stack needs proxies / all-intra preview cache.
4. Timeline: excellent.
5. ML runtimes: medium. ORT via N-API works; Vision/Speech/Foundation Models/VTFrameProcessor each need an Obj-C++ addon. Masks reach compositor via CPU copy unless ORT-web shares the WebGPU device (slower here).
6. Live segmentation during 4K playback on base Air: doubtful (CPU contention; CoreML split RVM into 10 partitions).
7. Audio: AudioWorklet is real-time thread and WASM avoids GC; weak on cross-process A/V clock sync, device/latency control, record with monitoring. May need native audio addon.
8. Time remap: pure TS, preview = export; RIFE possible via ORT.
9. Text: shaping/bidi/emoji/variable fonts free from browser; per-glyph GPU animation needs custom MSDF (as any stack).
10. Colour: float16 textures and compute available; 10-bit/HDR import and encode colour tags weak.
11. Keyframes: fine. 12. Background jobs: fine (utility processes/workers isolate crashes).
13. 8 GB memory: weakest point — ~250–300 MB summed RSS baseline, opaque GPU-process frame pools.
14. Undo/autosave: fine (Immer + fs). 15. Native integration: menus, DnD, multi-window, desktopCapturer OK; canvas a11y needs ARIA work.
16. Interchange: JS libs for FCPXML, SRT/ASS/VTT, Lottie, GIF; mediabunny MP4/MOV.

## Cross-platform
Biggest strength: same code on Windows (Media Foundation/D3D12) and Linux (VA-API decode more fragile).

## Agent buildability / verification
Very good: build ~2 s, package ~40 s, typecheck ~1 s; `--bench` flags non-interactive; `capturePage()` screenshots verified compositor output; ffprobe/ffmpeg verify exports; Playwright `_electron` available.

## Effort
~1,170 LOC TypeScript + ~90 LOC scripts, ~1.5 h. Pitfalls: Electron installer needs Node ≥ 22.12; open-ended range reads made seeks 300–1000 ms until streamed (~90 ms); renderer→utility MessagePorts silently null transferred ArrayBuffers (must copy frames); packager rejects `--asar` with sub-options; onnxruntime-node ships its 42 MB dylib twice.

## Risks
Memory/footprint on 8 GB; codec gaps (ProRes, 10-bit/HDR, alpha) — native decoder loses zero-copy; Obj-C++ addon per Apple framework; no zero-copy masks; AudioWorklet ≠ CoreAudio; WebCodecs/WebGPU behaviour changes across Electron releases; ~290 MB framework before models.
