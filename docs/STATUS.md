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
| W5 | Transitions & animations content | 2 | ready to merge (KF 11 done / 1 partial; TR 6 done / 1 blocked; CV-012, ST-004 done) | worktree-agent-a5c1da405c0ba0b29 |
| W7 | Text engine (styles, templates, per-glyph anim, captions styling) | 2 | merged (TX 21 done / 9 partial / 5 blocked) | main 8602b57 |
| W10 | AI features (wave 1: captions, cutout, stems, TTS, stabilize, tracking, looks, enhance, writer, clipper, LaMa, search) | 2 | merged (AI 18 done / 10 partial / 32 todo, mostly P2/generative) | main 25a02e3 |
| W11 | Export & interchange | 2 | merged (EX 22 done / 1 partial / 2 todo P2) | main 8fea692 |
| W12 | Home, project mgmt, settings, shortcut editor | 2 | ready to merge (PM 12 done / 2 partial; SE 6 done / 4 partial) | worktree-agent-ac8ee24bcf15bf705 |
| W13 | Asset library content (search, favourites, hover preview, stickers, audio lib) | 2 | merged (shared asset browser, media bin, local stock, 36-track generated music lib, previews on W2's PlayerPreview) | main 379b708 |
| PERF | MacBook Air smoothness — rounds 1+2 merged (8a083c4): timeline air 154→1.7 ms; slider drag air 60→16 ms; 50 captions air 58→5–12 ms; memory 1.1 GB→~800 MB; auto 4K proxies ~31 fps air. TODO: full perf.sh pass on a quiet machine (phase 4) | 3 | merged | main 8a083c4 |
| UXR | UX parity review vs CapCut (docs/UX_GAPS.md: 1 P0 / 18 P1 / 36 P2) | 3 | done; gaps dispatched (running teams fix own; POL-A W1/W2/W3, POL-B W7/W8/W11) | main b0d4b1f |
| POL-A | UX polish timeline/canvas/inspector (UX_GAPS W1–W3) | 3 | merged (lanes, cover editor, mask handles incl. pen/text, previewing mode, scopes, Adjust footer/Mask) | main 1efcb9a |
| POL-B | UX polish text/audio/export (UX_GAPS W7/W8/W11) | 3 | merged (all 8 gaps fixed) | main 9b94922 |
| BUG1 | Owner bugs: audio-inspector crash on deselect/delete (any audio clip) FIXED; HLG/DV colour pipeline (luminance OOTF, gamut desaturation, Apple-matched HDR→SDR, EDR preview) FIXED | 4 | merged | main ba1d11a |
| BUG2 | Owner bugs: auto captions too big (out of 9:16 frame); caption timing early/late/badly cut | 4 | ready to merge (integrated): CaptionLayout (canvas-aware size/position, safe width) + renderer wrap/auto-shrink; whisper DTW + energy-VAD snapping: onset MAE 225 → 41 ms (39 ms e2e through trim/×1.25/AAC priming); verified with large-v3-turbo on a copy of 1018 (captions inside 9:16 frame) | worktree-agent-a47f7bb6ab8a14a34 (0d27b98 + cache key t5 d30aa3a) |
| F1 | Finisher: remaining timeline/playback/speed/audio/settings/media rows (TL-037/043 P0, AU-029 P0 …) | 4 | running | |
| F2 | Finisher: remaining colour/stickers/masks/effects/cutout/canvas/text/export rows (CL-011/024, ST-009 P0 …) | 4 | merged b1ef9be | 9 done (MK-001/002/005, ST-008, CL-008/016, ST-010…), CL-012 partial (no Smart brush); FX-008/018, CL-014/028, MK-004 not started (P2). Gotcha: clear .build/…/Montage*.build after struct layout changes |
| FIN | Final polish backlog (collect here): prompt/auto-select HDR project colour space when HDR media imported (CapCut-like); verify EDR preview on a real HDR display; text Loop grid duplicate names (Float/Shake/Hop/Breathe/Heartbeat shared vs glyph); FR video-animation names truncated ("Fond…ntrant") — verify after W5 merge; animation grid not scrollable by test driver | 4 | backlog | |
| AI2 | AI wave 2 (P1 rest): EditPilot agent (on-device LLM), AI movement, relight, speaker-ID captions (AI-005/TX-038), forced alignment (TX-030), dictate (TX-034), camera tracking hand | 3 | merged (AI-048, AI-005, TX-038, TX-030, TX-034, AI-024/CL-020, AI-025, AI-013 (hand + custom box), CL-019 done; AI-041 track object; AI-031 Home wizard; quit-mid-job + LaMa segfault fixed) | worktree-agent-ace3ab6274c22fd67 |
| MUS | Music & sound library usable on Instagram (AU-001, AU-002, AU-025): bundled CC0 pack (66 tracks + 195 SFX via scripts/fetch_music_pack.sh, audio never committed, build_app.sh bundles + SHA-checks it) + online search (Freesound CC0/CC BY, Jamendo CC BY only; user keys in Keychain, Settings ▸ Music); no generated audio | 3 | ready to merge (integrated, AU-001/002/025 done) | worktree-agent-a47f7bb6ab8a14a34 (c71c6cd) |
| SR1 | Enhance quality speed (AI QA: ×50 RT): VideoToolbox low-latency super resolution over overlapping tiles (≤ 960 px, 6 per 1080p frame, scaled concurrently) + GPU resize instead of the full ×4 scaler; decoded frames go straight to the tiler (no CPU copy without denoise / deflicker). IMG_9079 copy 1080p HLG → 4K: 1629 s → 27.6 s (×50 → ×0.84 RT); synthetic 540p → 1080p ×0.18 RT, 1080p → 4K ×0.72 RT (TiledSuperResolutionTests, load-aware budgets 3× / 6×); export "AI ultra HD" uses the same path | 4 | ready to merge | worktree-agent-adfcb28782f253ff4 |
| C3 | Timeline & media fixes: (1) media drag shows a grey placeholder where it lands, main track ripples live, lane boundary = new lane there (`TimelineDropPlan`, `InsertTarget.newTrackAbove`), exit cancels — video / image / audio / several; (2) draggable clip volume line, dB tooltip, ↕ cursor, one undo step, keyframes offset (`ClipVolumeLine`); (3) media cards 288 px, aspect-fit letterboxed; (4) tooltips after 0.4 s app-wide (`Tooltips.install`); (5) playback freeze FIXED: seeking while AVPlayer's clock ran (rate 1, no stall waiting) often left the custom-compositor video pipeline without a preroll — clock + audio ran on, no frame requested for seconds. Seeks while playing now hold rate 0 and resume when the last coalesced seek lands. `PlaybackStressTests` (10-bit B-frame HLG HEVC via ffmpeg): 21/40 actions froze before → 0 (max 0.49 s to frames); 1019 real footage 60 actions 0 stalls; UI script `playback_seek_while_playing` | 4 | see branch | worktree-agent-aef37c1ea9a138783 |
| QA-AI | AI QA pass 2: every model installed, all `requires.models` scripts, every done/partial AI feature end to end on a copy of project 1018 (iPhone 1080×1920 HLG, French speech) + bench/media | 4 | ready to merge — 6 bugs fixed (table below) | worktree-agent-af260dfaae90fa707 |

## AI QA results (2026-10-19, pass 2)
Inputs: COPIES of project 1018's footage (IMG_9079 32.7 s talking head, IMG_7510 91 s, scratch QA projects; the original was
only read), bench/media. Every model in ModelCatalog installed (whisper turbo + small, demucs 4s/6s, Qwen3-4B, LaMa, WeSpeaker,
Depth Anything) + whisper-cli / demucs / llama-completion. The 7 model-gated UI scripts pass; 19 QA UI scripts drove each feature
in the app on the 1018 copy (player / inspector / timeline snapshots looked at); `RealMediaQATests` + `RealMediaQA2Tests`
(`MONTAGE_QA_VIDEO`, docs/TESTING.md) measured engines. Timings were taken on a loaded machine (2–4 other heavy jobs).

| Feature | Verdict | Evidence |
|---|---|---|
| Auto captions AI-001 / TX-017 (whisper turbo) | works | 32.7 s FR in 4.8 s (×0.15 RT); transcript word-perfect with punctuation; 8 two-line captions inside the 9:16 frame |
| Speaker ID AI-005 | works | WeSpeaker: 1 speaker (correct), 8 turns, 1.3 s |
| Align script to speech TX-030 | works | match 0.98, 8 captions, 3.7 s |
| Keyword highlight AI-004 | works | Qwen (local) 3.2 s: attendre, nouvelles, sœur, trente |
| Bilingual / translate AI-003 | blocked (OS) | Apple Translation fr↔en pack not installed ("needsDownload") — owner downloads it once (see below) |
| Transcript editing AI-019 / pauses AI-020 | works | panel shows the exact text + pause chips; EditPilot "supprime les silences" cut 5 pauses (32.7 → 12.6 s) |
| Auto lyrics AI-002 | not tested | no sung footage available (partial row unchanged) |
| Stems AI-011 / AU-010 (demucs 6s) | works | ×2.3 RT (77 s); vocals RMS 0.037 vs other stems < 1e-4; UI "Vocals" stem track |
| Isolate voice / Reduce noise / Enhance voice AU-007/008/009 | works | export mix noise floor −73.8 dBFS → −81.7 (reduce noise) / −95.1 (enhance) / −120 (isolate), speech −27.7 → −30.6 dBFS; AUSoundIsolation ×0.07 RT |
| Text to speech AI-006 / TX-016 | works | FR voice, linked TTS clip on the 1018 copy |
| Auto cutout CK-002 / AI-015 | works | clean hair edges; person ×2.2 RT, main subject ×5.2 RT |
| Auto reframe AI-012 | works | 4 s, 24 keyframes (9:16 → 1:1 can only pan vertically) |
| Camera tracking AI-013 | works (bug fixed) | face / body 1–1.6 s; **bug**: the motion-path overlay drew one diamond per tracking keyframe, a band over the eyes → generated paths (camera tracking / reframe / AI movement) are no longer drawn, dense paths lose their diamonds |
| Motion tracking AI-014 | works | face box tracked 10 s (300 samples) in 1.4 s |
| AI movement AI-025 | works | 0.5 s, keyframes written |
| Face mosaic AI-051 / ST-006 | was broken → fixed | **bug**: on rotated (iPhone portrait) footage the face ellipse grew in raw-frame axes: mouth / chin left clear, mosaic on the wall. Faces are now detected upright and grown in display axes; stale mattes regenerate on project open |
| Relight AI-024 | works | depth + person matte 61 s for 32.7 s (×1.9 RT); visible key light |
| AI remove AI-041 | works | LaMa on a 1080×1920 still 5.5 s, seamless; videos > 30 s are refused by design |
| Auto adjust / Color correction CL-007 / CL-008 | was broken in HDR → fixed | **bug**: SDR-computed looks applied to HLG working values gave a strong cyan / green cast (1018 is an HLG project). Looks are now re-baked for HDR projects (delta in project space); wall goes warm → neutral |
| Reduce image noise CL-018 / AI-022 | was broken on HDR → fixed | **bug**: the processed copy lost its colour tags (HLG read as BT.709: grey, washed out). Output now keeps the source tags, HDR as HEVC Main10 (10-bit widen, tagged buffers); old cached copies ignored (`-c2`) |
| Enhance quality CL-019 / AI-021 | was slow → fixed (SR1) | before: 1629 s for 32.7 s (×50 RT: the full VideoToolbox ×4 scaler turned the 1080p source into 8K frames, 1.5 s each), UI job at 39 % after 15 min. After: tiled low-latency ×2 scaler, 2160×3840 HLG Main10 in 27.6–30 s (×0.84–0.92 RT, machine loaded) — in the app 33 s from tick to done, cancel immediate. Same colour fix applies |
| Stabilize CV-013 / AI-059 | works (sped up) | analysis 455 s → 179 s for 32.7 s (decoder-side downscale instead of full-res CPU box filter); same camera path |
| Smooth slow-mo AI-018 | works (fix) | optical-flow provider on, 0.09 s / frame; **bug**: under heavy load the blocking `prepareOpticalFlow(wait:)` (export / tests) gave up after 30 s waiting for a utility-QoS queue (54 s session start in the full suite) and silently fell back to frame blending → it now builds the session on the calling thread |
| Scene split AI-026 | works | 1.9 s; "No scene change found" on a single shot (correct) |
| Smart search AI-028 | was broken → fixed | **bug**: Vision labels the clip "people" / "adult", but "person", "personne", "femme" found nothing (embedding too far, no translation pack). Built-in FR/EN synonyms; UI search "personne" now finds IMG_9079 |
| AI writer AI-029 | works (minor) | Qwen local, FR multi-line script in the UI (11 s); the engine ignored "4 phrases" once (one sentence) |
| EditPilot AI-048 | works (bug fixed) | FR request on 1018: 3-step plan (silences, captions, keywords) applied as one undo step; **bug**: "Rends la vidéo carrée pour Instagram" → 9:16 by the model; a ratio word in the request now overrides the model's ratio |
| AI clipper / shorts AI-031 | works | clipper on 91 s: 1 highlight in 14.6 s (LLM on) |

Owner, by hand: (1) Apple Translation packs (System Settings ▸ General ▸ Language & Region ▸ Translation Languages ▸ French +
English) for bilingual captions; (2) re-apply Auto adjust / Color correction and Reduce noise / Enhance quality on clips of HDR
projects processed before this fix (face covers refresh themselves when the project opens).

## Cross-team requests / blockers (open)
| From | Needs from | What | Feature IDs |
|---|---|---|---|
| W10 | W11 | Export: wait for running AI jobs (cutout / reframe / stems) before export; call `AIEngineHooks.prepareOpticalFlow(width:height:wait: true)` when clips use optical flow | EX, SP-005 |
| W6 | W1 | Double-click enter/edit inside compound clips (nested render done) | TL-021 |
| W8 | W1 | Menu entry for AU-016; waveform drawing polish; track volume ±0.1 dB shortcuts | AU-016, AU-019, AU-004 |
| W3 | W1/W2/W5/W8 | Timeline/canvas/content/audio-render parts of inspector-partial rows | CV-003/004/006/012, KF-001/003/008, SP-002, AU-004/005, CL-002, TR-002, MK-001 |
| W14 | W1/W2/W3/W6/W7/W8 | Driver landed (73ea621, docs/TESTING.md): merged teams still lack interaction tests → hardening pass | — |
| W14 | W14 | SwiftUI onTapGesture/DragGesture views don't receive synthetic events yet (custom inspector sliders) | — |
| W2 | W1 | Timeline preview axis: call `store.hoverPreview(t)` / `hoverPreview(nil)` on hover so the player shows the hovered frame | TL preview axis |
| W2 | W9 | Decoder downscale + preview render cache for Low/Med quality; real reverse decode (J shuttle is emulated with seeks, no audio) | PB-002/005/008 |
| W4 | W10+W6 | Person matte as an effect input (`EffectInput.matte`) so body effects work on plain video | FX-002 |
| W4 | W6 | Effect mask (mask texture feeding the effect mix) | FX-005, CL-012 |
| W4 | W14 | Driver `hover` doesn't trigger SwiftUI `.onHover` (posted mouseMoved never reaches the inactive window); card hover-loop previews untested | FX-001 |
| W1 | — | Group double-click enter (TL-020), clip markers (TL-025), track volume (TL-018) | TL-020/025/018 |
| UXR-W1 | W12 | Home thumbnail / package cover.jpg: render `Project.cover` with `CoverRenderer.jpeg` (nil cover = first frame) | TL-045 |
| W5 | W7 | Per-glyph/word text In/Out/Loop presets: register `AnimationDescriptor`s (targets `.text`) in `Registries.animations`; bind ‹◇› on text style rows to the new `ParamKey.text*` | TX-020, KF-009 |
| W5 | W13 | Sticker/effect tiles: hover-play animated stickers (`LottieLibrary`) like transition tiles do; favourites for the Transitions tab | TR-001, ST-* |
| W3 | W13 | Adjustment asset tab ▸ My presets: list `AdjustPresets.shared` (saved from the Adjust footer), apply = `AdjustTools.apply` | CL-013 |


## Done cross-team items
- W13 × W2: one library preview mode — W2 `Player/PlayerPreview.swift` (`store.isPreviewing`, `exitPreview()`, `PlayerUIState.preview`) now also has W13's `previewStock`, `previewTransition` (Transitions tab click), sample gradient under effects on an empty timeline, and exit on a click outside the asset panel + player; W13's duplicate LibraryPreview.swift removed. W13's 36-track MusicLibrary + AudioLibraryTab replace POL-B's 8-track pack / AudioLibraryView.
- W2 (UX polish) for W7: canvas text edge pills set `TextContent.boxWidth` (TX-011). For W4/W13: player preview mode (`store.previewMedia/previewEffect/previewSticker/exitPreview`, "Previewing — …"); effect/filter/sticker/media card clicks call it (FX-001, W13-1/W13-3).
- W12 did W6's + W2's requests: Settings ▸ Performance (preview quality + proxies persisted from Settings and the player menu, proxy policy/location/size, render cache size/cap/auto render) and the green render-cache bar under the ruler.
- W12 did W11's request: Settings toggles write `hardwareDefaultsKey`, `ExportQueue.soundDefaultsKey` and new `notifyDefaultsKey`.
- W12 → W11: Settings ▸ Export defaults feed the first export via `ExportDialogModel.firstExportDefaults`; HW encoding written to `hardwareDefaultsKey`.
- W14's `HeavyWorkGate` now also wraps W5's GPU-saturating transition/animation render loops (PlaybackTests fps flake).
- W10 for W7: auto captions/lyrics through `CaptionOps.addCaptionTrack` with word timings (karaoke), translations in `caption.translation`, LLM keywords + translate menu in W7's Captions tab; Text to speech tab (TX-016).
- W10 for W8: ML voice stems (AUSoundIsolation) feed Isolate voice / Reduce noise / Enhance voice in the rendered stage; HTDemucs instrument stems (AU-010) via the demucs.cpp sidecar.
- W11 did W8's audio-only export dialog (+ MP3 via the LGPL FFmpeg sidecar), W1's in/out range export (TL-028), W7's export-dialog captions (CaptionOps.segments + CaptionFiles.serialize).
- W7 did W2's request: `TextContent.boxWidth` in the model; `TextMetrics` now backed by the text engine layout (handles hug rendered text).

- W10 wrote person/subject/custom mattes through W6's `MatteVideoWriter`, flipped `CutoutAvailability.matteCompositingAvailable` (W3 cutout sections now live) and installed the optical-flow `FrameInterpolation.provider`.
- W3 built transition inspector (requested by W1).
- W8 delivered auto beats into `Clip.beats` (TL-026) for W1.
- W6/W9 delivered reverse render (TL-014) and nested compound rendering (TL-021 render side) for W1.
- W2 built the on-canvas parts of W3's CV-003/004 (handles, rotate handle, snapping); canvas fill (W3) is excluded from canvas hit-testing.

## Owner bug reports (fixed)
- 2026-10-19 Crash selecting / moving / deleting a TTS audio clip (project 1018): not a model problem — any audio clip
  on the Basic tab trapped in `AudioInspector.clipBinding` (force unwrap) when the selection went away before the panel
  dropped the section. Fixed (placeholder fallback, no-op set on a missing clip); `AudioUITests.audioSectionChromeSurvivesClipRemoval`,
  UI script `audio_delete_selected`. Existing projects need no repair.
- 2026-10-19 iPhone HLG/Dolby Vision footage: SDR projects blown + orange skin, HDR preview grey. Colour pipeline now:
  exact 10-bit video range, HLG OOTF on luminance, BT.2020→709 with gamut desaturation, HDR→SDR curve `1−exp(−k·maxRGB)`
  fitted to Apple's own rendering (3.6/255 mean error on the owner's clips); HDR projects preview through an EDR
  CAMetalLayer (Rec.2100 HLG/PQ colour space, half-float frames) and tone-map on non-EDR screens / snapshots.
  Tests: `HDRTests` (ffmpeg HLG/PQ patch clips vs ColorMath + Apple, preview tone map), `ColorMathTests`.

## Decisions log
- 2026-10-19 Owner: NO AI-generated/procedural music. Music & SFX library must offer real ONLINE search (Instagram-like) — explicit exception to local-only, limited to the music/SFX browser (user-supplied API keys e.g. Pixabay/Freesound, download-on-add so projects work offline). Rest of app stays offline.
- 2026-10-19 HDR media import keeps the project SDR by default (CapCut default; HDR footage now tone-maps like Photos/
  QuickTime). Timeline thumbnails stay on AVAssetImageGenerator: Apple's conversion is the reference the SDR curve is fitted to.
- 2026-10-18 Owner dropped 69 features (FEATURES.md status `wontdo`): cloud-only, generative AI, advanced voice AI (clone/s2s/overdub/translator), templates (TP-*), retouch/body (RT-*, AI-017, AI-052). EXCEPTION kept: music library + similar sounds (AU-001, AU-025) — must be a local library of tracks/sounds safe to use on Instagram (royalty-free/CC0, license recorded per item).
- 2026-10-19 MUS (owner): NO generated / procedural music or SFX (W13's MusicLibrary/MusicSynth and W8's SoundEffects deleted).
  Owner exception to local-only for the music/SFX library ONLY: Audio ▸ Online searches Freesound (CC0 + CC BY) and Jamendo
  (CC BY only; NC/ND/SA rejected by `OnlineLicensePolicy`) with the user's own free API keys (Settings ▸ Music, macOS Keychain,
  never committed). Network calls happen only when the user opens / searches Audio ▸ Online (and downloads a track on "Use");
  nothing else in the app touches the network (model downloads stay user-initiated as before). Used tracks are copied into the
  project with a license sidecar, so projects work offline. Pixabay was requested but has no public audio API (images/videos
  only) — not offered. Tests never hit the network (`MockOnlineAudioHTTP`); `liveSearch` is opt-in via MONTAGE_LIVE_*_KEY.
- 2026-10-18 MUS: the bundled library is CC0 / public domain ONLY (no CC-BY, so no caption attribution needed): FreePD.com (via the Wayback Machine — the site closed in 2025), Free Music Archive CC0 artists (HoliznaCC0, Loyalty Freak Music), Kenney, OpenGameArt, Wikimedia Commons (CC0 / PD with "attribution not required"; SoundBible/YouTube-sourced uploads rejected). Audio is never committed: `scripts/fetch_music_pack.sh` → cache `~/Library/Caches/MontageDev/content` → `build_app.sh` bundles it (warns when missing; `MONTAGE_REQUIRE_CONTENT=1` for release). Budget ≤ 150 MB (AAC 112 kbps music, 128 kbps SFX).
- 2026-10-18 Stack: native Swift/Metal/AVFoundation (STACK.md, owner-approved). macOS-only; cross-platform is a bonus.
- Proxies mandatory (4K HEVC decode ≈1.1–1.3 GB for 4 streams; no stack scrubs <50 ms p95 on originals).
- FFmpeg only as a separate LGPL sidecar process producing ProRes+PCM mezzanine (ARCHITECTURE §6.1).
- Integration: each team rebases on main, runs scripts/test.sh, ff-merges; if blocked by permission check, orchestrator merges (AGENT_GUIDE).
- W12 merged although `playbackDeliversFramesInRealTime` failed — only under load avg 140–270, passes alone, change doesn't touch playback. Perf team adding a test semaphore (max 2 heavy runs, perf.sh exclusive) + load-aware realtime test.
- Agents never send real mouse/keyboard input while teams run in parallel; real-input E2E pass is phase 4.

## Engineering gotchas (read!)
- Always-visible views must read store slices, never `store.project` (re-render storms). New render passes must `scratch.recycle` inputs (memory). See TESTING.md.
- UI tests are environment-independent (7d89983): AI models sandboxed (scripts declare `requires.models`, else SKIP), fixed cache sizes/clock in test mode, snapshot `mask`. uitest.sh exits non-zero on failure.
- Unit timing checks are load-aware (985b24e, TimingBudget: 3x gross bound, skipped when load > cores); precise budgets live in scripts/perf.sh. Heavy scripts share 2 machine-wide slots (scripts/slots.sh).
- MP3 export requires FFmpeg sidecar with libmp3lame; otherwise option disabled with hint.
- Never use AVAudioTimePitchAlgorithm `.varispeed`: hangs the audio reader during export on sped-up clips.
- Heavy work from main-actor code/tests starves PlaybackTests — run it off-main (`Task.detached`).
- Blocking AVFoundation reads (`copyNextSampleBuffer`, `AudioFileIO.read`, semaphores around async loads) inside `async`
  tests run on Swift's cooperative pool (≈ core count threads): when ~10 such tests overlap the pool is exhausted and
  AVFoundation deadlocks (whole suite hangs at 0 % CPU). New tests must do blocking media work on a GCD queue
  (`withCheckedContinuation` + `DispatchQueue.global().async`, see `FinisherAudioTests.grain`); avoid in-process
  `OSLogStore` enumeration (SupportPackage shells out to `/usr/bin/log`).
- Quit / end of a UI test: `AppShutdown.stopBackgroundWork()` cancels exports + every `JobQueue` job and waits for them (exiting under live Core ML/Metal work crashed in MPSGraph teardown). The `ai_remove_inference` exit-139 segfault (clean-check) was the same teardown crash (inference still running at `exit`, MPSGraph logging); also LaMa is now one shared model with serialized predictions and owned pixel copies (stress test `concurrentInpaintingUnderLoadAndCancel`). New background work must go through `JobQueue` (or check `Task.isCancelled`) so quit can stop it.

- Generated media must keep the source's colour: copy primaries / transfer / matrix into the writer (`AVVideoColorPropertiesKey`),
  HDR as HEVC Main10 fed 10-bit buffers that carry the same colour attachments (untagged → kVTParameterErr). Colour stats taken
  on SDR frames (AVAssetImageGenerator) must be converted before being applied to HDR working values (`ColorLooks.inProjectSpace`).
  Vision on iPhone portrait footage: pass the orientation (`SubjectAnalyzer.orientation(asset.sourceRotation)`), then map back to raw.

- Never seek `PlaybackEngine.player` directly while it plays: go through `seek`/`performSeek` (they hold the rate at 0
  until the seek lands; seeking with the clock running froze the preview, C3-5). Start playback with `resume(atRate:)`.

## Known risks
- Apple on-device French STT WER ~13% without OS model download → whisper.cpp (large-v3-turbo, 547 MB) as quality path.
- Session interruptions (restart, auth, account switch) stop agents; worktrees keep work. Resume via SendMessage; if the transcript is gone, start a continuation agent pinned to the existing worktree path (worktree = source of truth, not the agent).
