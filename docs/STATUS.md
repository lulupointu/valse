# Project status — orchestration tracker

Single source of truth for *where the project is*. Per-feature status lives in docs/FEATURES.md (Status column);
run `scripts/feature_status.py` for a per-area summary, `--list partial|blocked|todo [--area TL]` for details.
Updated by the orchestrator after every merge / wave; agents append to "Cross-team requests" when they hit a dependency.

## Phase
- [x] 1. Discovery — FEATURES.md (434 features, 116 Pro), UX.md (live CapCut), UX_AI.md (AI/Pro UX)
- [x] 2. Strategy — 4 stack prototypes benchmarked → native Swift (STACK.md); foundation + ARCHITECTURE.md
- [ ] 3. Implementation — waves of feature teams (below)
- [ ] 4. Hardening — real mouse/keyboard E2E pass on Montage (iTerm has Screen Recording + Accessibility), perf on Air-like settings, FR review

## Workstreams (ARCHITECTURE.md §17)
| WS | Area | Wave | State | Branch / last merge |
|---|---|---|---|---|
| W1 | Timeline editing UX | 1 | merged (24 done / 10 partial / 1 blocked) | main 82aaa0d |
| W2 | Player canvas & playback | 1 | merged (10 done / 7 partial) | main bf3e193 |
| W3 | Inspector panels | 1 | merged (16 done / 14 partial / 1 blocked) | main 19504fe |
| W6+W9 | Render engine + media pipeline | 1 | merged incl. colour + media helpers | main 9c54c1b |
| W8 | Audio | 1 | merged (19 done / 13 partial / 1 blocked) | main a3bf1f7 |
| W14 | QA: UI test driver, screenshot diff, perf | 1 | merged (driver, gestures, perf.sh --air, check_clean, 14 UI scripts) | worktree-agent-aa1de47edb2d5d946 |
| W4 | Effects & filters content | 2 | merged (243 effects, 108 filters, 170 stickers, asset tabs) | main 7b6e923 |
| W5 | Transitions & animations content | 2 | running | |
| W7 | Text engine (styles, templates, per-glyph anim, captions styling) | 2 | merged (TX 21 done / 9 partial / 5 blocked) | main 8602b57 |
| W10 | AI features (captions/STT, cutout matte, denoise, reframe, TTS, translate, …) | 2 | running | |
| W11 | Export & interchange | 2 | merged (EX 22 done / 1 partial / 2 todo P2) | main 8fea692 |
| W12 | Home, project mgmt, settings, shortcut editor | 2 | ready to merge (PM 12 done / 2 partial; SE 6 done / 4 partial) | worktree-agent-ac8ee24bcf15bf705 |
| W13 | Asset library content (search, favourites, hover preview, stickers, audio lib) | 2 | running | |
| PERF | MacBook Air smoothness: 500-clip fit-zoom timeline 154 ms/frame on E-cores → <16 ms; full --air audit; flaky PlaybackTests | 3 | running | |
| UXR | UX parity review vs CapCut (docs/UX_GAPS.md: 1 P0 / 18 P1 / 36 P2) | 3 | done; gaps dispatched (running teams fix own; POL-A W1/W2/W3, POL-B W7/W8/W11) | main b0d4b1f |
| POL-A | UX polish timeline/canvas/inspector (UX_GAPS W1–W3) | 3 | running | |
| POL-B | UX polish text/audio/export (UX_GAPS W7/W8/W11) | 3 | running | |
| — | Templates (TP), Retouch/body (RT) | 3 | queued (depend on W7, W10) | |

## Cross-team requests / blockers (open)
| From | Needs from | What | Feature IDs |
|---|---|---|---|
| W10 | W11 | Export: wait for running AI jobs (cutout / reframe / stems) before export; call `AIEngineHooks.prepareOpticalFlow(width:height:wait: true)` when clips use optical flow | EX, SP-005 |
| W6 | W1 | Double-click enter/edit inside compound clips (nested render done) | TL-021 |
| W8 | W1 | Menu entry for AU-016; waveform drawing polish; track volume ±0.1 dB shortcuts | AU-016, AU-019, AU-004 |
| W3 | W1/W2/W5/W8 | Timeline/canvas/content/audio-render parts of inspector-partial rows | CV-003/004/006/012, KF-001/003/008, SP-002, AU-004/005, CL-002, TR-002, MK-001 |
| W14 | W1/W2/W3/W6/W7/W8 | Driver landed (73ea621, docs/TESTING.md): merged teams still lack interaction tests → hardening pass | — |
| W14 | W14 | SwiftUI onTapGesture/DragGesture views don't receive synthetic events yet (custom inspector sliders) | — |
| W7 | W2 | Canvas edge pills / ⌥-drag set `TextContent.boxWidth` (fraction of canvas width; engine wraps) | TX-011 |
| W2 | W1 | Timeline preview axis: call `store.hoverPreview(t)` / `hoverPreview(nil)` on hover so the player shows the hovered frame | TL preview axis |
| W2 | W9 | Decoder downscale + preview render cache for Low/Med quality; real reverse decode (J shuttle is emulated with seeks, no audio) | PB-002/005/008 |
| W4 | W10+W6 | Person matte as an effect input (`EffectInput.matte`) so body effects work on plain video | FX-002 |
| W4 | W6 | Effect mask (mask texture feeding the effect mix) | FX-005, CL-012 |
| W4 | W14 | Driver `hover` doesn't trigger SwiftUI `.onHover` (posted mouseMoved never reaches the inactive window); card hover-loop previews untested | FX-001 |
| W4 | W2/W13 | Click on an effect/filter card = 3 s "Previewing — Effects" loop in the player | FX-001 |
| W1 | — | Cover editor (TL-045), group double-click enter (TL-020), clip markers (TL-025), track volume (TL-018) | TL-045/020/025/018 |

## Done cross-team items
- W12 did W6's + W2's requests: Settings ▸ Performance (preview quality + proxies persisted from Settings and the player menu, proxy policy/location/size, render cache size/cap/auto render) and the green render-cache bar under the ruler.
- W12 did W11's request: Settings toggles write `hardwareDefaultsKey`, `ExportQueue.soundDefaultsKey` and new `notifyDefaultsKey`.
- W12 → W11: Settings ▸ Export defaults feed the first export via `ExportDialogModel.firstExportDefaults`; HW encoding written to `hardwareDefaultsKey`.
- W10 for W7: auto captions/lyrics through `CaptionOps.addCaptionTrack` with word timings (karaoke), translations in `caption.translation`, LLM keywords + translate menu in W7's Captions tab; Text to speech tab (TX-016).
- W10 for W8: ML voice stems (AUSoundIsolation) feed Isolate voice / Reduce noise / Enhance voice in the rendered stage; HTDemucs instrument stems (AU-010) via the demucs.cpp sidecar.
- W11 did W8's audio-only export dialog (+ MP3 via the LGPL FFmpeg sidecar), W1's in/out range export (TL-028), W7's export-dialog captions (CaptionOps.segments + CaptionFiles.serialize).
- W7 did W2's request: `TextContent.boxWidth` in the model; `TextMetrics` now backed by the text engine layout (handles hug rendered text).

- W10 wrote person/subject/custom mattes through W6's `MatteVideoWriter`, flipped `CutoutAvailability.matteCompositingAvailable` (W3 cutout sections now live) and installed the optical-flow `FrameInterpolation.provider`.
- W3 built transition inspector (requested by W1).
- W8 delivered auto beats into `Clip.beats` (TL-026) for W1.
- W6/W9 delivered reverse render (TL-014) and nested compound rendering (TL-021 render side) for W1.
- W2 built the on-canvas parts of W3's CV-003/004 (handles, rotate handle, snapping); canvas fill (W3) is excluded from canvas hit-testing.

## Decisions log
- 2026-10-18 Stack: native Swift/Metal/AVFoundation (STACK.md, owner-approved). macOS-only; cross-platform is a bonus.
- Proxies mandatory (4K HEVC decode ≈1.1–1.3 GB for 4 streams; no stack scrubs <50 ms p95 on originals).
- FFmpeg only as a separate LGPL sidecar process producing ProRes+PCM mezzanine (ARCHITECTURE §6.1).
- Integration: each team rebases on main, runs scripts/test.sh, ff-merges; if blocked by permission check, orchestrator merges (AGENT_GUIDE).
- Agents never send real mouse/keyboard input while teams run in parallel; real-input E2E pass is phase 4.

## Engineering gotchas (read!)
- PlaybackTests realtime check can flake under heavy machine load (seen by W11) — W14 to harden.
- MP3 export requires FFmpeg sidecar with libmp3lame; otherwise option disabled with hint.
- Never use AVAudioTimePitchAlgorithm `.varispeed`: hangs the audio reader during export on sped-up clips.
- Heavy work from main-actor code/tests starves PlaybackTests — run it off-main (`Task.detached`).

## Known risks
- Apple on-device French STT WER ~13% without OS model download → whisper.cpp (large-v3-turbo, 547 MB) as quality path.
- Session interruptions (restart, auth, account switch) stop agents; worktrees keep work. Resume via SendMessage; if the transcript is gone, start a continuation agent pinned to the existing worktree path (worktree = source of truth, not the agent).
