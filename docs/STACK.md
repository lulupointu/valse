# STACK.md — tech stack decision for Valse

Status: **recommendation, pending owner sign-off** · Benchmarks run 2026-10-18 by the neutral bench lead.
Inputs: docs/BRIEF.md, docs/STACK_BENCH.md, FEATURES.md §23, the 4 prototype REPORT.md files, and the runs below.

## 1. How the benchmarks were run
- **Machine:** M1 Pro (8P+2E, 16 GB), 120 Hz ProMotion, macOS 26.4, on AC power (battery charging 87→97 %), `pmset -g therm`: no thermal or performance warnings at any point.
  Background: no other bench or build was running, but the machine was not idle: iTerm2, coreaudiod, CrowdStrike, Firefox and a running CapCut instance used about 0.6–0.8 of a core in total, and the load average was 4–8. Snapshots before each run are in `bench/results/system_state.log`.
- **Protocol:** everything prebuilt in release first. `bench/run_all.sh` runs each full `bench.sh` sequentially with a 60 s cooldown between runs, in 2 rounds (round 1 Swift→Electron→Tauri→Qt, round 2 reversed). Raw lines are in `bench/results/<stack>-r{1,2}.jsonl`. The table below shows the **median of the 2 rounds (min–max)**; a single value means both rounds were identical. The aggregator is `bench/aggregate.py`; the full table is in `bench/results/summary.md`.
- **Harness fixes** (measurement only, no engine change; each one is marked `[bench harness]` in the code):
  1. Swift: CPU% was the mean of `ps %cpu`, a decaying average that under-reports. It is now the delta of cumulative CPU time over wall time, like the other three. `preview_rss_mb` was the peak; it is now the mean, like the others, and the peak is reported separately.
  2. Electron: the VideoToolbox XPC decoder/encoder helpers were not counted in CPU/RSS, while the other three counted them. They are now counted.
  3. Qt: a flat 20 s phase watchdog killed the 20 s preview before it could report. Only smoke runs had been done before this fix.
  4. Added the **8-layer stress test** (a–d twice) to all 4 stacks: `VALSE_LAYERS=8`, metrics `preview8_*`. Added preview-only and `BENCH_WRAP` hooks for the constrained runs.
  5. Added a supplementary **phys_footprint** measurement (`bench/footprint.sh`), because summed RSS double-counts shared pages (it inflates Electron) and misses GPU/IOSurface memory.
- **Comparability caveats** (left as is and documented here):
  - CPU is % of one core in all 4 stacks, summed over the app, its helpers and the VT XPC services spawned for it.
  - The end of a scrub is measured differently. Swift: drawable on screen. Qt: frame swap. Tauri: present plus GPU completion. Electron: GPU done, not yet presented. Electron is favoured by at most about 1 vsync.
  - Timeline fps is capped by the display. Tauri's WKWebView caps requestAnimationFrame at 60 Hz, while the other three run at 120 Hz. **A base Air is 60 Hz, so all four hit the target there.**
  - Cold start is not the same event in every stack. Swift and Electron measure to the UI shell plus the timeline. Tauri and Qt measure to the first composited 4×4K frame. Qt's UI-only figure is 486 ms.
  - Segmentation uses different models in each stack: Swift uses Vision `.balanced`, Electron RVM 960×544 on CPU, Tauri RVM 1080p on CoreML, Qt MODNet 512×288. **STT is the same whisper.cpp large-v3-turbo in all four**, so it is stack-neutral. Swift's headline STT number is Apple's DictationTranscriber; its whisper result is listed separately. Electron's RTF includes spawn and model load.
  - The layer layouts differ slightly between stacks (layer sizes 0.35–1.0). Fill cost at 1080p is negligible here; decode dominates.

## 2. Results (median of 2 rounds, M1 Pro)

| Metric | Swift native | Electron | Tauri + Rust | Qt + C++ |
|---|---|---|---|---|
| preview fps / dropped (20 s, 4×4K HEVC) | 30.0 / 0 | 29.8 / 5.5 (4–7) | 30.0 / 0 | 29.9 / 0 |
| preview CPU % (1 core = 100) | **20.8** (20.2–21.4) | 59.5 | 26.1 | 42.0 (41.1–42.9) |
| preview RSS mean MB (summed) | **185** (174–196) | 773 | 280 | 476 |
| phys_footprint MB: app + helpers (VT decoder share) | 1286 (1113) | 1500 (951) | 1453 (1276) | **1050** (655) |
| **preview8** fps / dropped | **30.0 / 0** | 29.7 / 5.5 (2–9) | 29.9 / 0 | 29.4 / 10.5 (8–13) |
| preview8 CPU % / RSS MB | **30.7 / 250** | 82.4 / 868 | 39.7 / 379 | 61.2 / 378 (319–436) |
| preview8 phys_footprint MB | 2494 | 2724 | 2754 | **1998** |
| scrub exact p50 / p95 ms (50 seeks) | 73 / 107 | 70 / 93 | **48 (46–51) / 76** | 85 (82–89) / 152 |
| scrub keyframe-tolerant p50 / p95 | 41 / 49 (Swift only) | — | — | — |
| export 10 s 1080p H.264 (s) | 2.2 | 2.0 | 2.0 | 4.1 |
| timeline fps (500 clips) | 120 | 119 | 60.5 (WKWebView cap) | 119 |
| seg fps (model differs) | 50 (48–53) Vision | 49 RVM-CPU | 24 RVM-CoreML | 55 MODNet |
| STT RTF / WER (fr) | 0.059 / 0.126 (Apple), whisper 0.079 / 0.031 | 0.080 / 0.030 | 0.055 / 0.031 | 0.068 / 0.031 |
| audio 1.5× pitch-preserved | ok | ok | ok | ok |
| cold start ms (definitions differ) | 394 | 638 | 549 | 465 |
| app size MB (no models) | 0.7 | 360 | 15.7 | 243 (untrimmed) |

**Constrained-CPU approximation of a MacBook Air (single run each, preview only). This is NOT an Air measurement.**
The M1 Pro has only 2 E-cores, while an Air has 4P+4E and a 7–8-core GPU. Neither throttle reproduces the Air's GPU or its 8 GB.

| Throttle | Swift | Electron | Tauri | Qt |
|---|---|---|---|---|
| `taskpolicy -c utility` (QoS clamp): fps / dropped | 30.0 / 0 | 29.9 / 2 | **15.5 / 145** | 29.9 / 1 |
| `taskpolicy -b` (DARWIN_BG = E-cores + low GPU/IO priority): fps | **28.9** | 0.1 | 9.3 | 0.05 |

`-b` is harsher than any real Air: it also demotes GPU and IO priority. Still, only Swift kept playing under it. Swift's decode, composite and present pipeline runs on AVFoundation and system threads, so the throttle hurts it less. Qt's render loop and Electron's GPU process stalled. Under the milder clamp, Tauri's sleep-paced player thread is the only one that degraded.

**What the numbers say**
- On a 16 GB M1 Pro, all four stacks hit the basic 4-layer preview.
- The real discriminators are CPU headroom, memory and robustness. Swift leads on all three; Tauri is close behind; Qt and especially Electron trail.
- No stack meets **scrub < 50 ms** at p95 with exact seeks on long-GOP 4K HEVC. This is a decode and architecture problem, not a stack problem.
- The VideoToolbox decoder itself holds **about 1–1.3 GB for 4×4K and about 2–2.5 GB for 8×4K**, whatever the stack. On an 8 GB Air, 4K multi-layer editing therefore needs proxies.

## 3. Scoring against the goal (1–5, higher is better)

| Criterion (weight) | Swift | Electron | Tauri | Qt | Notes |
|---|---|---|---|---|---|
| 1. Reachable feature completeness (×3) | **5** | 2 | 4 | 4 | Swift: ProRes 4444/alpha, HDR/EDR, Vision, SpeechAnalyzer, Translation, Foundation Models, Core Text and AVAudioEngine are first-party. Electron: no ProRes, weak 10-bit/HDR/alpha, one Obj-C++ addon per Apple framework, masks need a CPU copy. Tauri and Qt reach the same APIs via objc2 or Obj-C++; Tauri must build GPU text itself and Swift-only APIs need a shim. |
| 2. Smoothness on base Air, perf + memory (×3) | **5** | 1 | 4 | 3 | Swift has the lowest CPU and RSS, 0 drops at 8 layers, and was the only one to survive `-b`. Tauri is close but degrades under clamps. Qt drops frames at 8 layers and its CPU is 2× Swift's. Electron uses 3× CPU and 4× RSS and drops frames everywhere. |
| 3. Local-only (×1) | 5 | 4 | 5 | 5 | Electron: Chromium network services must be locked down. Swift: the best fr STT asset is an OS download, so ship whisper as an AI pack. |
| 4. French localization (×1) | 4 | 5 | 5 | 5 | All are good. Swift needs designed runtime switching (String Catalogs plus an app-level locale). |
| 5. Cross-platform bonus (×1) | 1 | 5 | 3 | 4 | Swift is macOS-only (iPad is possible). Tauri's media and presentation layers are macOS-specific, at about 1–2 engineer-months per extra OS. |
| 6. AI agents build **and verify** (×2) | 4 | 5 | 3 | 4 | Swift: `swift build/test`, offscreen Metal snapshots and headless export pixel tests. `screencapture` needs a one-time permission, and XCUITest needs Xcode. Electron: Playwright `_electron` plus `capturePage`. Qt: `grabWindow` (includes RHI content) and QTest. Tauri: 3 languages, no macOS WebDriver, and the native video is missing from webview snapshots. |
| 7. Licensing risk (×1) | **5** | 4 | 5 | 3 | Qt: LGPLv3 obligations, private QRhi, GPL Rubber Band (swap it for SoundTouch or buy a licence), LGPL FFmpeg build. Codec patents are covered by using the OS codecs on every stack. |
| 8. Long-term risk (×2) | 4 | 3 | 2 | 3 | Swift: Apple lock-in and yearly API churn (some APIs are macOS 26 only), but a single stable vendor. Tauri: wgpu, ort RC and objc2 churn, a private-API transparent webview, and 2 UI technologies. Qt: licensing policy and semi-private RHI. Electron: memory and codec ceiling. |
| **Weighted total (/70)** | **61** | 43 | 52 | 52 | |

## 4. Recommendation
**Choose Swift native: SwiftUI/AppKit shell, a custom Metal compositor and timeline, AVFoundation/VideoToolbox, Vision/CoreML/Speech, AVAudioEngine.**

Rationale:
- It wins both success criteria. It has the shortest path to the stack-sensitive features (ProRes/HDR/alpha, Apple AI frameworks, zero-copy masks, Core Text) and the most CPU and memory headroom.
- It was the only stack that stayed smooth at 8 layers and under the harsh `-b` throttle.
- It has no licensing exposure.
- Cross-platform is only a bonus in the brief, which is exactly what Swift gives up.
- Agent verification is good enough: CLI builds, headless render/pixel tests and offscreen snapshots. It needs one-time Screen Recording permission on the dev machine.

**Runner-up: a Rust engine (wgpu + objc2 AVFoundation) with a Tauri UI.** It had the best scrub, low CPU and RSS, a 16 MB app, a permissive licence and a real cross-platform path. It is held back by fragility under CPU pressure, the hacky native-view-under-webview presentation, API churn, and harder agent verification. Qt is a close third: strong ecosystem and testability, but higher CPU/RSS, a slow export path and licensing work.

**What would change the decision**
- Windows/Linux becoming a requirement within about 2 years: choose Rust + Tauri, or Qt if the team prefers one UI technology.
- A real base-Air run showing Swift dropping frames where another stack does not. **Run `bench/run_all.sh` on an 8 GB Air before Phase 1 ends.**
- macOS 26 as the minimum OS being unacceptable. This removes SpeechAnalyzer and some VT features, but not the stack choice itself.
- Agents unable to verify SwiftUI UI reliably. Mitigation: keep the logic in a UI-free `ValseEngine` package and test it headlessly.

## 5. Architecture lessons any stack must adopt
1. **Scrub < 50 ms needs more than exact seeks.** Exact seeks on long-GOP 4K HEVC measured 48–85 ms p50 and 76–152 ms p95 in every stack. Needed:
   - an all-intra / low-res **proxy or preview cache**;
   - **keyframe-first-then-refine** while dragging (Swift tolerant seek: 41/49 ms);
   - an own async `VTDecompressionSession` decoder pool with several frames in flight, instead of AVPlayer, AVAssetReader or FFmpeg's synchronous VT hwaccel (the cause of Qt's 2× slower export);
   - thumbnail and filmstrip caches.
2. **Memory budget comes from the decoder.** Each 4K HEVC stream costs about 300 MB in the VT helper. On 8 GB: preview at ½ res from proxies, bound decoder pools and frame queues (Qt's 4×4 queue of 4K frames costs about 400 MB in-app), keep at most 1 heavy model resident, and use mip/box downsampling instead of sampling 4K straight to 1080p.
3. **Zero-copy everywhere:** IOSurface/CVPixelBuffer → Metal textures for decode, ML masks and encode. One compositor shared by preview, export and thumbnails, so output is deterministic.
4. **Presentation on a dedicated high-QoS render path** (CAMetalLayer plus display link, presented-time stats), clocked from the audio device. Never pace with sleeps on a normal thread; Tauri and Qt degraded under throttling.
5. **The timeline is one GPU-drawn, virtualized canvas** (instanced draws, glyph atlas). No widget or DOM per clip.
6. **Built-in verification hooks:** headless render/export tests with pixel asserts, offscreen snapshot flags for every custom view, `--bench` modes, and metrics as JSON lines. Keep the engine UI-free so agents can test it from the CLI.
7. **Ship AI as optional local packs** (whisper for fr STT, at about 3 % WER vs 13 % for Apple Dictation). Load them on demand and run jobs in a queue.
