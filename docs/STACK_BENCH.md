# Stack evaluation — shared benchmark spec

Every candidate prototype lives in `prototypes/<stack>/` and MUST NOT run benchmarks concurrently with others
(the orchestrator runs all benches sequentially at the end). Build + smoke-test only, at small scale, while developing.

## Shared test media (generate once with `bench/make_media.sh`, idempotent, output in bench/media/)
- `a.mp4`..`d.mp4`: 4 distinct 3840x2160 30fps HEVC (hevc_videotoolbox or libx265), 60 s, moving content (testsrc2 / mandelbrot / different hues), AAC stereo tone.
- `h264_1080.mp4`: 1920x1080 30fps H.264, 60 s.
- `speech_fr.wav`: ~60 s French speech, 16 kHz+ (generate with macOS `say -v Thomas` or similar French voice, text provided in bench/speech_fr.txt).
- No person footage: for P5a measure segmentation speed on `h264_1080.mp4` (quality not assessed).

## Prototype scope (minimal, but real code paths you'd use in the final app)
P1. Preview: window with a player view rendering at 1920x1080 a composition of the 4 4K clips stacked as layers
    (each with its own scale/position transform, opacity 0.8, and one color filter e.g. saturation+brightness), playing at 30 fps.
P2. Scrub: programmatic seek to 50 random timestamps; time from seek request to composited frame displayed.
P3. Export: render the same 4-layer composition for 10 s to 1080p30 H.264 MP4 (hardware encode if the stack allows).
P4. Timeline UI: a scrollable/zoomable timeline with 500 clips (colored rects + label + thumbnail placeholder) across 6 tracks; programmatic scroll+zoom animation for 5 s; measure UI frame rate.
P5. AI: (a) person segmentation over 300 frames of 1080p video — fps; (b) French speech-to-text with word timestamps on speech_fr.wav — real-time factor + rough accuracy; using the best on-device option available to that stack.
P6. Audio: play a clip at 1.5x with pitch preserved (time-stretch) while video plays; just verify it works and note the API.

## Each prototype must provide
- `prototypes/<stack>/bench.sh` — builds (release) and runs P1–P6 non-interactively, prints a JSON line per metric:
  {"stack":..,"metric":..,"value":..,"unit":..} to stdout. Metrics: preview_fps, preview_dropped_frames, preview_cpu_pct, preview_rss_mb,
  scrub_ms_p50, scrub_ms_p95, export_seconds, timeline_fps, seg_fps, stt_rtf, stt_wer_estimate (optional), audio_stretch_ok, cold_start_ms, app_size_mb.
- `prototypes/<stack>/REPORT.md` — qualitative findings: dev effort, ecosystem fit for the 434 features in docs/FEATURES.md
  (esp. the "Stack-sensitive requirements" section), French localization approach, cross-platform story, risks, how well an AI agent can
  build & verify UI in this stack (CLI build, headless tests, screenshots), LOC written, build time.

Measure CPU/RSS by sampling the process (e.g. `ps -o %cpu,rss`) — include all helper processes (GPU/renderer/helpers for web stacks).
Machine: M1 Pro (note: target is a base MacBook Air; we compare relative numbers).
