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
| F4 | Finisher: FX / CL / MK / AI / EX / PM / SE rows | 4 | ready to merge (17 rows → done: FX-001/002/004/008/018, CL-012/014/028, MK-004, AI-002/009/028/041, EX-016, PM-009/014, SE-017; still partial: FX-016 (no ML stylization), AI-006 (no TTS emotion styles), AI-010 (no ML de-reverb), SE-013 (light theme)) | worktree-agent-abda850bc4d311345. Notes: `a11yAudit` UI step (real AX tree) for VoiceOver checks; Clip gained `effectScope`, `hdrConversion`, `ClipMatte.bodyOnly` (clean Montage*.build); RenderStageSpec v2 (audio re-render once); UI driver file drops use absolute URLs; CLIP model (300 MB) via model manager; MI-025 (F3) can follow AI-028. For C1: CL-014 is an opt-in per-clip switch (`Clip.hdrConversion`, nil = default pipeline bit for bit) — C1 owns default tone mapping. For C2: SE-017 added a11y modifiers to `SectionHeaderBar` / `CapCheckbox` / `CapToggle` / `Dropdown` (labels + VoiceOver actions only, no behaviour change) |
| F3 | Finisher: media / canvas / KF / text / audio partial rows | 4 | ready to merge | 22 done (TX-018 auto lyrics is F4 AI-002): MI-001/006/008/012/013/014/020/021/024, CV-003/006/009/014, KF-009, TX-005/011/026/040, AU-004/007/009/016/019. Stay partial (need content or ML we don't have): TX-013/TP-004 (no Lottie, not thousands), AU-030 (TTS emotion styles), AU-008 (ML de-reverb), AU-010 (strings/synth/wind stems), MI-025 (CLIP search, = AI-028 F4). Gotchas: UI driver file drops now use absolute URLs; dropped caption files go through the caption-track import; test temp files (montage-* in $TMPDIR) filled the disk (12 GB) — stale ones (> 3 h) were removed |
| FIN | Final polish backlog (collect here): prompt/auto-select HDR project colour space when HDR media imported (CapCut-like); verify EDR preview on a real HDR display; text Loop grid duplicate names (Float/Shake/Hop/Breathe/Heartbeat shared vs glyph); FR video-animation names truncated ("Fond…ntrant") — verify after W5 merge; animation grid not scrollable by test driver | 4 | backlog | |
| AI2 | AI wave 2 (P1 rest): EditPilot agent (on-device LLM), AI movement, relight, speaker-ID captions (AI-005/TX-038), forced alignment (TX-030), dictate (TX-034), camera tracking hand | 3 | merged (AI-048, AI-005, TX-038, TX-030, TX-034, AI-024/CL-020, AI-025, AI-013 (hand + custom box), CL-019 done; AI-041 track object; AI-031 Home wizard; quit-mid-job + LaMa segfault fixed) | worktree-agent-ace3ab6274c22fd67 |
| MUS | Music & sound library usable on Instagram (AU-001, AU-002, AU-025): bundled CC0 pack (66 tracks + 195 SFX via scripts/fetch_music_pack.sh, audio never committed, build_app.sh bundles + SHA-checks it) + online search (Freesound CC0/CC BY, Jamendo CC BY only; user keys in Keychain, Settings ▸ Music); no generated audio | 3 | ready to merge (integrated, AU-001/002/025 done) | worktree-agent-a47f7bb6ab8a14a34 (c71c6cd) |
| SR1 | Enhance quality speed (AI QA: ×50 RT): VideoToolbox low-latency super resolution over overlapping tiles (≤ 960 px, 6 per 1080p frame, scaled concurrently) + GPU resize instead of the full ×4 scaler; decoded frames go straight to the tiler (no CPU copy without denoise / deflicker). IMG_9079 copy 1080p HLG → 4K: 1629 s → 27.6 s (×50 → ×0.84 RT); synthetic 540p → 1080p ×0.18 RT, 1080p → 4K ×0.72 RT (TiledSuperResolutionTests, load-aware budgets 3× / 6×); export "AI ultra HD" uses the same path | 4 | ready to merge | worktree-agent-adfcb28782f253ff4 |
| C3 | Timeline & media fixes: (1) media drag shows a grey placeholder where it lands, main track ripples live, lane boundary = new lane there (`TimelineDropPlan`, `InsertTarget.newTrackAbove`), exit cancels — video / image / audio / several; (2) draggable clip volume line, dB tooltip, ↕ cursor, one undo step, keyframes offset (`ClipVolumeLine`); (3) media cards 288 px, aspect-fit letterboxed; (4) tooltips after 0.4 s app-wide (`Tooltips.install`); (5) playback freeze FIXED: seeking while AVPlayer's clock ran (rate 1, no stall waiting) often left the custom-compositor video pipeline without a preroll — clock + audio ran on, no frame requested for seconds. Seeks while playing now hold rate 0 and resume when the last coalesced seek lands. `PlaybackStressTests` (10-bit B-frame HLG HEVC via ffmpeg): 21/40 actions froze before → 0 (max 0.49 s to frames); 1019 real footage 60 actions 0 stalls; UI script `playback_seek_while_playing` | 4 | see branch | worktree-agent-aef37c1ea9a138783 |
| C2 | Inspector fixes: ▼ expands unticked options (generic, InspectorSectionView + effect blocks; settings editable, ticking applies); Remove BG / Auto removal / Custom removal / Chroma key (FR Supprimer l'arrière-plan / Suppression automatique / personnalisée / Clé chroma); job progress: timeline redraws on `store.jobs` (one source, `jobProgress` / `JobInfo.percent`); same-kind multi-select gets the full inspector (Bind.apply / `performInspector` fan out, one undo, mixed "-"; single-clip AI / mask / text-box sections hidden, `InspectorMultiEdit`) | 4 | ready to merge | worktree-agent-a9132457188fc6b70 |
| C4 | Captions & transcript rework: Captions top-level asset tab (Auto · Local · Filler words); caption list = numbered text rows, hover ＋ / 🗑, no timing steppers; Text ▸ Basic \| Templates \| Bubble \| Effects; ☑ Apply to all main captions (default on, one undo step, live in drags); Transcript: global (no selection), Auto-detect dropdown fixed, up-to-date / out-of-date · Update (incremental), Remove filler words in timeline time (leading / trailing / cross-cut pauses, scope = selected clips), captions follow the cuts, 3 switchable apply styles (below) | 4 | ready to merge | worktree-agent-ab58eee3f67565a6e |
| C6 | Media library + tooltips (owner test): (1) grid tiles ~140 pt, 3 per row at the default panel width, count follows the width (`MediaGrid`), 288 px posters stay 2x sharp; (2) list view = CapCut filmstrip rows (screenshot 27): frames across the panel width (portrait as square crops, Retina-sized), rounded, duration top right, name below, frames lazily from `ThumbnailCache`, waveform strip for audio; (3) white hover-time bar on cards / rows; a click on the media already in the preview moves it to the clicked time, another media opens at 0 (`previewMedia(_:hoverTime:)`, grid + list); (4) custom tooltips replace AppKit's: 0.2 s delay every time (no instant hand-over), gone on exit / click / scroll / key, dark pill under the element; `.help(String)` in MontageUI is shadowed by `Support/Tooltips.swift` (no call-site change, text kept as accessibility hint). Tests `MediaLibraryC6Tests`, UI `c6_media_library`, `c6_tooltips` | 4 | ready to merge (all 4 items done; clean check + UI scripts green) | worktree-agent-af9a3fe457d0164bc |
| C3b | Timeline round 2 (owner feedback): (1) moving an existing clip works like a library drop — single-clip moves lift the clip (`TimelineOps.liftForMove`, lanes kept), placeholder + live main-track ripple + new lane at boundaries, drop = `TimelineOps.relocate` exactly as previewed, one undo step; (2) flicker FIXED — the move gesture mutated the model every mouse event, a new lane appeared/disappeared, every row shifted under the pointer and the next event re-targeted (oscillation in the owner's recording); now the model is untouched until the drop. Splitter / window resize: `CAMetalLayer` views changed `drawableSize` in `layout()` but drew on the next display-link tick, presented outside the resize transaction (stretched / blank frame) → `MetalResize` presents synchronously with `presentsWithTransaction` (timeline + player); (3) one-sided waveforms from the bottom; (4) volume keyframes are diamonds on the volume line, always visible; (5) volume-line drags: diamond = that keyframe, segment = both bounding keyframes, before first / after last = that keyframe (`ClipVolumeLine.Grab`); render samples eased spans (16 pieces) so it matches the drawn curve (`VolumeCurveRenderTests`). Tests `TimelineC3bTests`, UI `c3b_move_clip`, `c3b_volume_keyframes` (driver: drag `"hold"` + `release`); (6) remaining playback freeze (C1 saw `PlaybackStressTests` fail on main): real, not load — reproduced at load 8 (~1 run in 4: after a scrub's final exact seek / a seek storm, AVPlayer plays with full buffers but never asks our compositor for a frame again). Internal to AVFoundation; reordering didn't prevent it and `preroll` never completes with a custom compositor (10/40 stalls). Fix: the engine watches the display-link frame polls — playing, no seek in flight, item clock +0.3 s with no new frame → exact re-seek at the current time (rate held, resumed); `stallRecoveries` counts it. 0 stalls in 13 synthetic runs (incl. under load) + 1019 80 actions; the 4 s budget is unchanged. Hardened after an 8 s freeze in a gate run beside another agent's gate (clock running, 0 frames composed, no re-prime): the output re-handed the frame it already showed, which reset the watch → only a new display time counts as a frame; after 2 futile re-seeks the player item is rebuilt (`stallRebuilds`); stall reports carry compositor requests / GPU frames / re-primes / rebuilds (`CompositorStats.requestsStarted`). 9 full-suite runs (4 beside a second full suite) 0 stalls | 4 | see branch | worktree-agent-aef37c1ea9a138783 |
| QA-AI | AI QA pass 2: every model installed, all `requires.models` scripts, every done/partial AI feature end to end on a copy of project 1018 (iPhone 1080×1920 HLG, French speech) + bench/media | 4 | ready to merge — 6 bugs fixed (table below) | worktree-agent-af260dfaae90fa707 |
| U2 | Caption / transcript word timing (owner, 1019 IMG_7251: caption "Vous" 3.2 s long from the clip start, before the person speaks). Cause: whisper DTW gives a token's end only; a word started a fraction of the way from the previous token — for a segment's first word that is the segment start (30 s window start / previous segment end), so after 3.7 s of walk-in noise "Vous" started at 0.56 s; the energy-VAD snap missed it because the rustle / footsteps (−47…−58 dB, 25–30 dB under the voice) counted as speech. Fix: a word starts no earlier than its first token's DTW time − a spelling-based max duration (`WhisperEngine.maxTokenDuration`, hesitations 1.5 s); VAD runs are speech only with 50 ms in a row within 22 dB of the voice level (`SpeechActivity` hysteresis). Transcript cache t6: older cached transcripts ignored (also by the transcript panel's `latest`), existing caption clips untouched. Fixture `bench/speech_onsets.swift` (FR Thomas / EN Samantha, known onsets, silences + rustle + footsteps; cached in ~/Library/Caches/MontageDev/fixtures): onsets median 21 → 19 ms, max 2709 → 72 ms (FR), 2124 → 121 ms (EN); IMG_7251 "Vous" 0.56 → 3.66 s (voice 3.68; post-pause onsets −20 / 0 / −150 ms, the last after a breath). Tests `CaptionOnsetTests` (opt-in footage `MONTAGE_U2_FOOTAGE`) | 4 | ready to merge | worktree-agent-ad754d5a09064707e |
| P1 | Project switcher (owner: "an easy way to access all my projects when I am in a project"): the centred title-bar name is a button ("1019 ⌄", `titlebar.projectSwitcher`) opening an in-window popover (380 pt, `switcher.popover`) — search (case/diacritic-insensitive, autofocused), every non-trashed project with cover / "Edited today 12:26 · 01:29", current first (✓) then last opened then modified, ↑/↓ wrap, Return = switch here (auto-save + close + "Saved to project"), ⌘-Return / ⌥-click / hover ⧉ = new window (PM-014), "Open in another window" / dimmed "Drive offline" rows, Esc clears then closes, footer New project ⌘N · All projects ⌘⇧H (`menu.home` now bound); ⌘⇧O / File ▸ Switch Project… (rebindable `menu.switchProject`, ignored mid-drag and in other text fields). Pure logic `ProjectSwitcherModel` (MontageCore). Safe switching: `AppModel.open` runs lock / drive / summary checks BEFORE closing the current project and reopens it if the open still fails (else Home). Stale-lock fix: `SessionLock.holderPID` / `isHeldByOtherProcess` / `CrashRecovery.hasStaleLock` count only a live MONTAGE process (same bundle id, else executable name; `registerTestHolder` for fixtures) — a reused pid after a crash = stale lock (crash recovery). Red close button in the editor → Home + "Saved to project" (Home still quits). Tests `ProjectSwitcherModelTests`, `ProjectSwitcherTests` (+ opt-in `MONTAGE_P1_PROJECTS` real-project switch: copies of 1019 (stale lock, live non-Montage pid → opens with crash recovery) ↔ 1018 in ~50 ms), UI `pm_switcher(_fr/_held/_offline)`, parity docs/ux/parity/p1_switcher.png (popover + Home "Saved to project" toast vs capcut_05); `a11yAudit` gained `"element": "id:x"` (subtree / frame scope) | 4 | ready to merge | worktree-agent-ae1ae0a16b0f37fa6 |
| T1 | Test & merge tooling (process review): two-stage gate — `scripts/check_fast.sh` (incremental build + unit tests + UI scripts selected from the diff by `scripts/ui_select.py` / `app/Tests/ui_map.txt` + smoke set) while iterating, `check_clean.sh --ui` once before merge (writes `build/check_clean.ok`); one automatic retry per failed unit test / UI script ("flaky (passed on retry)") + `app/Tests/quarantine.txt` (8 known load flakes, reported, not gating; twice-failing unlisted tests still fail); hang watchdog (no output + ~0 % CPU for 10 min → `sample` stacks, kill, "HUNG"); slots reclaim dead / PID-reused / 20-min-idle holders (`scripts/slots.sh status|reclaim`), load-aware extra slots; private TMPDIR per test run (deleted on exit), 5 GB disk check, `scripts/cleanup.sh [--dry-run]` (first run freed 13.6 GB), `scripts/merge_agent.sh <branch>` (gate stamp → ff-merge → build_app → drop .build); real-like fixtures `fixtures/real/` (iPhone HEVC Main10 HLG portrait with a face + speech, speech with a pause, 120 BPM music; `RealLikeMedia`, `RealLikeFootageTests`, colour looks, UI `real_footage_import`; owner clips opt-in `MONTAGE_REAL_FOOTAGE`). Validated: check_fast on a 1-file change in 6 min (980 unit + 11 UI scripts, green); the watchdog killed a deliberately hung test after 1 min (`MONTAGE_HANG_MINUTES=1`), with `sample` stacks pointing at the hanging line; dead-PID and idle slot holders reclaimed. Last full check_clean --ui (before the final fix): 173/175 pass, 5 flaky, 1 quarantined; `fin_timecode_solo` failed twice, so it now waits for the field and seek (fixed). Full stage 2 on the final head not yet run | 4 | ready to merge | worktree-agent-a626be3fcaf8e5d24 |
| C1 | Colour-space looks (owner project 1019, iPhone HLG/DV): preview matched to Apple + export in SDR / HLG / PQ (untagged video composition, compositor-stamped output, HLG ambient viewing environment, Rec.709 SDR drawable); `ColorSpaceLookTests` ΔE00 vs Apple | 4 | ready to merge | worktree-agent-ab87aa66ecd61e634 |
| U1 | Owner UI fixes: (1) **flicker while moving panels — root cause**: `Splitter` read `DragGesture` in its default LOCAL space (its own frame, which moves with every resize) and summed per-event deltas, so each event saw mouse travel minus the splitter's last move: the panel followed half the mouse and its width alternated between two values on successive frames (owner's recording: asset edge 820/857/821/858 px; Metal views redrew each wrong size). Now window space + absolute (size at press + travel); same bug fixed in the crop dialog handles. Re-recorded on 1019 (on-screen test window, `screencapture -v`): 41 → 1 direction reversals, 1:1 travel; (2) Settings vertical-only (`lockHorizontalScroll`, no sideways rubber-band) + switch rows aligned — NOT reproduced in the harness (no overflow in any tab en/fr, elasticity already none): defensive; (3) FR "Légendes" → "Sous-titres" in ~70 strings (owner; CapCut fr uses Légendes); (4) in-app titles without "…" (`settings.title`, `keymap.title`; the shortcut list names menu commands without it too; only app-menu items keep it); (5) tooltip pill measured one line and clipped wrapped text ("…à partir de") → wraps; caption number tooltip ends with the start time; `captions.added` key defined twice with different format args fixed; l10n_check now fails on format-argument mismatches; (6) `PlayheadFollow`: user scroll while playing is never fought (follow off until play / seek, or until the user has scrolled back to the line and let go for 1 s), play brings an off-screen playhead in (left + 40 pt / right − 40 pt), page at the right edge; (7) marquee: start anchored in content coordinates (`MarqueeAnchor`: time + content y, so the rectangle extends while the view scrolls instead of sliding), display-link edge autoscroll (`EdgeAutoscroll`: 24 pt band, 120 pt/s + 28 pt/s per pt deeper, cap 3000; runs while the mouse stands still; the drag step is replayed so the marquee / moved clip / trim edge keep up) for marquee, clip move (also vertical), trim, roll, keyframe, marker, scrub — it used to scroll 8 pt per mouse event. Tests `OwnerUIFixesU1Tests`, UI `u1_marquee_autoscroll`, `u1_splitter_drag`, `u1_settings_no_hscroll(_fr)`, `u1_caption_tooltip_fr`, `u1_playhead_follow`; parity docs/ux/parity/u1_*.png. CapCut 9.6 was launched in the background and captured (`screencapture -l`), but it ignores pid-targeted synthetic events while inactive and agents may not activate apps or send screen input, so its playback follow / marquee were not re-observed live: parity uses docs/ux CapCut shots | 4 | ready to merge | worktree-agent-a04eb954f1fe114fc |
| B1 | Engine bugs: (1) range export starting mid-project hung (IMG_9079 @ 1 s / 10 s): the base track was the 1-s blank stretched to the project duration, reads starting inside stretched samples never deliver for ~1/3 of durations → 60-s blank tiled unscaled (`RangeExportTests`, ffmpeg HLG HEVC fixture + opt-in owner clip); (2) every remaining `copyNextSampleBuffer` loop in MontageEngine / MontageAI off the cooperative pool (`OffPool.run` / new `OffPool.next`, ScrubAudio on GCD; `BlockingReadStressTests` deadlocks pre-fix); (3) load flakes: ML `JobQueue` jobs `heavy: true` respect `HeavyWorkGate` in tests (gate moved to MontageEngine, re-entrant, taken before a slot), per-run unit-test cache folder (concurrent runs deleted each other's mattes: RelightRenderTests), cutout / auto-beats tests await the job task, animation tiles hold the end pose under UI tests (w5_animation_apply), assets_media_tab waits for state | 4 | ready to merge | worktree-agent-a5b5cbfb73ba84b18 |

## C4 — "Remove filler words": three apply styles to try (owner picks one)
**Obsolete (2026-10-22, FB-11): the owner removed "Remove filler words" and this setting; kept for history.**
Switch in **Settings ▸ Edit ▸ Labs ▸ Filler removal style** (stored as `fillerRemovalStyle` in
`~/Library/Application Support/Montage/settings.json`: `"instant"`, `"review"` (default) or `"inline"`; takes effect on the next click,
no restart). Every style starts the same way — one click on **Remove filler words** in the Transcript panel (toolbar ▸ Transcript, no
clip needs to be selected) or in **Captions ▸ Filler words** (also reachable from the ✨ wand in Inspector ▸ Captions): it transcribes
what is missing first, then finds hesitations / fillers / repetitions / pauses ≥ the minimum (options ⚙: kinds, minimum pause), in the
**selected main-track clips** if any are selected, else **everywhere**. Pauses include the silence before the first and after the last
word of a run of speech clips and across cuts. Captions follow every cut (their words in the cut disappear from the caption text).
- **(A) Instant**: cuts everything at once (one undo step); the toast says "Removed N filler words and pauses (X s)" with **Undo**.
- **(B) Review list**: a checklist replaces the transcript — one row per filler / pause with its context ("… show. ⏸ Pause Today …"),
  duration and time; click a row to play it, uncheck what to keep, **Remove N** (footer shows the time saved; Keep all / Remove all).
- **(C) Inline**: the transcript stays, fillers and pause chips are highlighted in red (= removed); click one to keep it (outlined),
  click again to drop it, then **Apply (N)**.
Both entry points render the same `TranscriptWorkspace` (MontageUI/AI/TranscriptPanel.swift + FillerReviewViews.swift); the engine is
`FillerCleanup` (MontageCore). Tests: `FillerCleanupTests`, `FillerRemovalSpeechTests` (whisper on bench/media/speech_fr.wav padded
with silence), UI scripts `c4_fillers_{review,inline,instant}`, `c4_transcript_stale`, `c4_captions_tab`, `c4_caption_list`.
Before/after of the owner's bug: screenshot 9 = before (one 32.7 s clip), 8 = after the old removal (6 s of silence kept at the start of
IMG_9079 and 4 s at the end of IMG_7251, captions not moved).

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

## macOS 13 UI results (m13-uifix, 2026-10-21)
macOS 13.7.4 VM (Apple Silicon guest, Mac2 paravirtual GPU, 1x display, en_US, UTC, 8 GB, no FFmpeg): the universal release
build passed 135 / 185 UI scripts (35 failed, identical arm64 / x86_64-Rosetta). After m13-uifix: the 35 pass on arm64, a
14-script sample on x86_64. Causes:
- **Export from the UI was blocked** (export_dialog, _fr, export_range, export_selected_cancel): `canExport` required MP3 to be
  usable even with Export audio off; MP3 needs the FFmpeg sidecar (not bundled, absent on a fresh Mac). Fixed for every OS: the
  audio format only matters when audio is exported, and without FFmpeg the format falls back to AAC. Not a 13 issue.
- **Transition param edits wrote back a stale transition** (w5_transition_drop: Softness 40 reset Duration 1.0 → 0.5). The row's
  commit closure held the instance captured at render time; it now starts from the current transition. Present on the host
  too (the new expect failed there); only visible in the 13 snapshot.
- Expected 13 differences, tests OS-aware (`minOS` / `maxOS` steps, docs/TESTING.md): Enhance quality is macOS 26+ (VT super
  resolution); relight has no depth-model offer on 13 (pseudo-depth only); smart brush finds people only on 13 (no
  `VNGenerateForegroundInstanceMaskRequest`; non-person object → "No object found…" toast); transcription before 26 is
  SFSpeech, which needs the Speech Recognition permission (job fails at once in a test process).
- Relight pseudo-depth pass: ~65 s for the 6 s demo clip in the VM (×11 real time; timeout raised to 150 s). VM GPU/ANE, not
  measured on real 13 hardware.
- Snapshot-only differences (27 scripts, 31 baselines in `app/Tests/Baselines/macos13/`, used on 13 only): text rasterised at
  1x, native slider / segmented control / placeholder / link-button (inactive window) looks, en_US decimal point, no offline
  music section in a `--no-content` build, the relight download card (14+). Harness fixes for all machines: overlay scroll bars
  and Europe/Paris time zone in the test process, crop size on non-Retina displays.
- Not 13-specific, noticed: the timeline toolbar's `magnet` SF Symbol doesn't exist on any macOS (empty button); several host
  baselines predate current UI (asset tab bar with Templates, relight Cutout tab) and pass only within tolerance.

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


## Done cross-team items
- W3 → W13: Adjustment asset tab ▸ My presets (`AdjustPresets.shared` listed, add as adjustment layer / apply to selected clip / delete) — done by pilot-1 (CL-013).
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
- 2026-10-22 batch-fb1 owner feedback: FB-04 Spoken word off keeps its style (`TextContent.inactiveKaraoke`), on restores
  it; FB-05 magnet toolbar icon redrawn as monoline like its neighbours; FB-06 `Dropdown` was a clear borderless `Menu`
  over a drawn field (real clicks missed it) → full-field Button opening a native NSMenu (all ~70 uses); FB-07 modal
  dialogs own the cursor / tooltips (`ModalHoverGate`, `.modalHoverShield()`); FB-08 model download card pinned
  bottom-right; FB-09 Settings steppers 22×14 halves, whole half clickable. Pending: macos13 re-record of
  ai_captions_identify_speakers / ai_speakers_section overrides (FB-11 changed the host baselines).
- 2026-10-19 Crash selecting / moving / deleting a TTS audio clip (project 1018): not a model problem — any audio clip
  on the Basic tab trapped in `AudioInspector.clipBinding` (force unwrap) when the selection went away before the panel
  dropped the section. Fixed (placeholder fallback, no-op set on a missing clip); `AudioUITests.audioSectionChromeSurvivesClipRemoval`,
  UI script `audio_delete_selected`. Existing projects need no repair.
- 2026-10-19 iPhone HLG/Dolby Vision footage: SDR projects blown + orange skin, HDR preview grey. Colour pipeline now:
  exact 10-bit video range, HLG OOTF on luminance, BT.2020→709 with gamut desaturation, HDR→SDR curve `1−exp(−k·maxRGB)`
  fitted to Apple's own rendering (3.6/255 mean error on the owner's clips); HDR projects preview through an EDR
  CAMetalLayer (Rec.2100 HLG/PQ colour space, half-float frames) and tone-map on non-EDR screens / snapshots.
  Tests: `HDRTests` (ffmpeg HLG/PQ patch clips vs ColorMath + Apple, preview tone map), `ColorMathTests`.
- 2026-10-19 C1 project 1019 (iPhone HLG / DV 8.4): SDR preview red / crushed skin, PQ preview washed out, HLG preview
  brighter than QuickTime — while the export looked right. Cause: AVPlayer converts the source frames to the video
  composition's colour properties before the custom compositor (VideoToolbox HDR→SDR / HLG→PQ, despite
  `supportsHDRSourceFrames`; AVAssetReader only re-matrixes), and tags them like the composition, so the renderer
  converted the footage a second time. The video composition is now untagged (frames arrive as decoded); the compositor
  stamps its output with the project tags (`MontageCompositor.stamp`). Also: HLG preview layer + HLG HEVC export carry
  the footage's ambient viewing environment (`HDRViewingMetadata`, iPhone 314 lux, as AVPlayer/QuickTime do); SDR
  preview drawable tagged Rec.709 (colour-managed like AVPlayer). CIEDE2000 per patch vs Apple's rendering of the same
  frame (`ColorSpaceLookTests`, owner clips via `MONTAGE_C1_FOOTAGE`): SDR preview 13 → 1.6–2.1 mean, PQ preview 9 →
  0.14, HLG 0.17–0.20; export = preview within 0.3–1.2 (compression). Known: SDR fully saturated BT.2020 primaries
  (synthetic patches) differ up to ΔE 11 from VideoToolbox's tone map (real footage < 3). Pre-existing: a
  range export starting mid-clip stalled (the video reader never delivers) on some iPhone clips, e.g. IMG_9079 at 1 s
  or 10 s (full / from-0 exports fine) — fixed in B1 (stretched base track, not the clip).
- 2026-10-20 B1 range-export hang: not iPhone-specific. The composition's base track was the 1-s blank STRETCHED to
  the project duration; for about one duration in three (32.735 s = IMG_9079 alone, 32.7, 45.123, 61.01 s …) an
  AVAssetReader whose time range starts inside the stretched samples never delivers a frame — also with Apple's own
  compositor and without the clip. Now a 60-s 1-fps blank is tiled unscaled. `RangeExportTests` (ffmpeg 10-bit HLG
  HEVC iPhone-like fixture; owner clip opt-in `MONTAGE_B1_CLIP=<copy of IMG_9079.mov>`).
- 2026-10-22 owner TODO list, batch-ob1 (IDs OB-01…12; OB-08 magnet + OB-09 overlay clip look in a later batch):
  - OB-01 counter: count span split into one equal bucket per displayed value (1→10 over 100 frames = 10 frames each).
  - OB-02/03 timeline click: a click that changes the selection never moves the playhead; a click in the sole selected
    clip seeks; the empty header column = click at 0 (`TimelineClickPolicy`). OB-05: right-click on empty track space → Paste
    (clips / media files / image / text at the clicked time, greyed when nothing pasteable).
  - OB-04 text box edge pills resize from the centre (⌥ = one side; inverts TX-011's earlier F3 wording).
  - OB-06 export finish screen never auto-plays. OB-07 `store.requireModels` (ModelDownloadFlow): popup → bottom-right
    indicator with confirmed cancel → the action proceeds; AI remove, AI writer, Isolate music. Timeline "Get stems" still
    opens the model sheet (moved to the OB-08/09 task).
  - OB-10 Text sub-tabs Basic | Templates (Caption category first for captions) | Spoken word (captions) | Bubble.
  - OB-11 arrows/Home/End go to the focused text field even when a menu has the key equivalent (`TextFieldKeys.route`);
    ↑/↓ step inspector numeric fields (⇧ ×10). Settings' NumberSetting and slider fields don't have ↑/↓ yet.
  - OB-12 a click on the selected layer's body selects the topmost unlocked layer under the pointer.
  - Open: macos13 override of `ai_remove_track` may need re-recording (Remove enabled before the model is installed);
    test-media cache writes are not atomic (a 0-byte `montage-test-media-v1/face-walk-v1.mov` crashed every unit run);
    unverified risk: `SliderRowView` is `.equatable()` without comparing closures (stale clip after switching between two
    clips with equal values). Flaky during agent gates: player_preview, timeline_edit, inspector_fr_formats,
    f4_se_a11y_editor, f3_waveform, finish_pen_mask_draw, c2_inspector_expand_unticked, ai_relight_model,
    f3_motion_blur (exit 139), TimeRemapTests.reversedAudioIsSampleReversed.
- 2026-10-23 TL-048 Quick cut (batch-qc1 engine/core, batch-qc2 UI; spec + research bench docs/QUICK_CUT.md, docs/quickcut/).
  Owner decisions: clips with nothing detected stay untouched; all tracks (main ripples, others close up in their own
  footprint); EditPilot remove_silences uses the same detector. batch-qc1 merged with --skip-gate-check (owner
  2026-10-23): every build / unit / UI test green, perf gate failed on metrics that also fail on main 795294b (perf.sh
  alone: assets_scroll_main_cpu_p95_ms 3.41 > 3, inspector_drag_main_cpu_p50_ms 11.84 > 8, timeline_scroll_cpu_p95_ms
  2.32 > 2; assets_scroll was 0.83 in batch-dx 2026-10-22 02:39, 4.11 in batch-fb1): regression on main, fix task open.
  Flaky in these gates: ai_relight_model, c3b_volume_keyframes, effects_library, model_download_proceed,
  ai_camera_custom_box, HDRTests.hlgSourcePassesThroughHLGProject. Apply with 300 cuts: 170-195 ms release (RippleCut
  per-range O(n) copying, budget 300 ms).
- 2026-10-23 PERF-R1: the "main perf regression" above was no code regression (fed8612, before OB/FB/QC, measures the
  same): on a quiet machine the CPU clocks down between bursty perf events, inflating main-thread CPU 1.5-4x; old gates
  passed only because load (24-60) kept clocks up. Fix (owner 2026-10-23): PerfClockWarmer spins a sibling thread during
  perf steps (MONTAGE_PERF_WARM=0 = off); assets_scroll p95 0.67-0.90, inspector_drag p50 ~5, timeline_scroll p95 ~0.6.

## Decisions log
- 2026-10-22 Owner removed features (batch-fb1): transcript-based editing (AI-019 / TL-042, FB-01), Auto captions "Identify
  filler words" (FB-02), "Remove filler words" + its Labs style setting (AI-020 / AU-027, FB-11), Highlight keywords incl.
  Spoken word keyword emphasis and EditPilot highlight_keywords (TX-022 / AI-004, FB-03). Old projects / settings still decode.
  Kept: `RippleCut` (EditPilot remove_silences), `FillerWords` lexicon (captions text cleanup). Tooltip policy (FB-10): hover
  help only on icon-only controls or when the visible text is unclear (Support/Tooltips.swift, montage-gotchas).
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
- Intel / macOS 13 (m13-intel): `Float16` is unavailable on x86_64 — use `Half` (MontageCore; bit-exact, verified on all
  2^32 floats) behind `#if arch(arm64)`. `scripts/build_app.sh` builds a universal app (`--host-only` for quick builds);
  `scripts/build_ai_runtimes.sh` builds universal macOS 13 sidecars (x86_64 = ggml CPU, no Metal; never link Homebrew
  dylibs). `scripts/test_x86.sh` runs the x86_64 unit tests under Rosetta.
- Gate (T1, 2026-10-21): feature agents run targeted tests + `scripts/check_fast.sh` once on the final commit (never `check_clean.sh`); the orchestrator runs ONE `scripts/check_clean.sh --ui` per batch. Failed
  tests are retried once alone; only twice-failing tests that are not in `app/Tests/quarantine.txt` fail the gate.
  A "flaky" line is a bug report, not a pass to ignore.
  Tests run in a private TMPDIR: anything that must survive the run (caches) belongs in `MONTAGE_TEST_MEDIA_DIR` /
  MontagePaths, never in `FileManager.default.temporaryDirectory`.
- `a11yAudit` (T1 fix): under load the real AX read sometimes returned no windows (the offscreen accessory window is
  missing from AXWindows) → the in-process fallback, which misses SwiftUI names → random "unlabeled AXMenuButton"
  failures in `f4_se_a11y_*`. The audit now also takes the app's window children / main window and re-reads for ~6 s.
- Media features: test with `RealLikeMedia` (iPhone HLG portrait, speech, music) rather than only testsrc patterns.
  Rotation, 10-bit HLG and 44.1 kHz AAC are the paths real footage breaks.
- MP3 export requires FFmpeg sidecar with libmp3lame; otherwise option disabled with hint.
- Never use AVAudioTimePitchAlgorithm `.varispeed`: hangs the audio reader during export on sped-up clips.
- Heavy work from main-actor code/tests starves PlaybackTests — run it off-main (`Task.detached`).
- Blocking AVFoundation reads (`copyNextSampleBuffer`, `AudioFileIO.read`, semaphores around async loads) inside `async`
  tests run on Swift's cooperative pool (≈ core count threads): when ~10 such tests overlap the pool is exhausted and
  AVFoundation deadlocks (whole suite hangs at 0 % CPU). New tests must do blocking media work on a GCD queue
  (`withCheckedContinuation` + `DispatchQueue.global().async`, see `FinisherAudioTests.grain`); engine read loops use
  `OffPool.run` around the loop, or `await OffPool.next(output)` per sample when the loop awaits (B1: every
  MontageEngine / MontageAI loop does; `BlockingReadStressTests`); avoid in-process
  `OSLogStore` enumeration (SupportPackage shells out to `/usr/bin/log`). A watchdog for such a hang needs its own
  `Thread`: with the pool deadlocked, GCD's global queues get no new worker either.
- ML work started through `JobQueue` passes `heavy: true` (B1): in unit tests it then runs inside `HeavyWorkGate`
  (now in MontageEngine, re-entrant). Tests that drive a store flow await the task it returns (`setCutout`,
  `autoBeats`) instead of polling with a time budget. Unit-test processes use their own cache folder
  (`$TMPDIR/montage-test-cache/run-<pid>`, `MontagePaths.testRunCacheDirectory`; compiled models stay shared), so
  tests may write / delete content-hash-keyed cache entries (mattes, stems) without racing other checkouts' runs.
- The composition base track tiles a 60-s blank unscaled (`CompositionBuilder.addBase`): never `scaleTimeRange` a
  composition track to an arbitrary duration — reads starting inside stretched samples can stall forever (B1).
- Quit / end of a UI test: `AppShutdown.stopBackgroundWork()` cancels exports + every `JobQueue` job and waits for them (exiting under live Core ML/Metal work crashed in MPSGraph teardown). The `ai_remove_inference` exit-139 segfault (clean-check) was the same teardown crash (inference still running at `exit`, MPSGraph logging); also LaMa is now one shared model with serialized predictions and owned pixel copies (stress test `concurrentInpaintingUnderLoadAndCancel`). New background work must go through `JobQueue` (or check `Task.isCancelled`) so quit can stop it.

- Inspector multi-select (C2): new inspector writes go through `Bind.apply` / `ClipParamRow` / `store.performInspector(UpdateClip|SetSpeed)`
  so they apply to every same-kind selected clip; per-clip-only sections go in `InspectorMultiEdit.singleOnlyIDs`. Effect rows
  match other clips' instances by type (`EffectParamRow.resolve`).
- Generated media must keep the source's colour: copy primaries / transfer / matrix into the writer (`AVVideoColorPropertiesKey`),
  HDR as HEVC Main10 fed 10-bit buffers that carry the same colour attachments (untagged → kVTParameterErr). Colour stats taken
  on SDR frames (AVAssetImageGenerator) must be converted before being applied to HDR working values (`ColorLooks.inProjectSpace`).
  Vision on iPhone portrait footage: pass the orientation (`SubjectAnalyzer.orientation(asset.sourceRotation)`), then map back to raw.
- SwiftUI builds its accessibility tree only for real AX clients: audit VoiceOver labels with the `a11yAudit` UI step (AXUIElement of the own process, on the main thread), not by walking NSView accessibility children.

- Tooltips: `.help("…")` with a String inside MontageUI is Montage's own tooltip (`Support/Tooltips.swift` shadows SwiftUI's
  overload): 0.2 s, hides on exit / click. Keep using `.help(tr(…))`; don't set AppKit `toolTip` on new views. Synthetic
  hovers reach it through `SyntheticEvents.observeDequeued` (tracking areas ignore posted moves).
- Never seek `PlaybackEngine.player` directly while it plays: go through `seek`/`performSeek` (they hold the rate at 0
  until the seek lands; seeking with the clock running froze the preview, C3-5). Start playback with `resume(atRate:)`.
- `EditSession.postProcess` (C4) runs after every command and every gesture tick: today it replays a selected caption's style edit on
  its track ("Apply to all main captions", `CaptionStyleSync`, ~4 ms for 400 captions). Keep anything added there cheap.
- Ripple cuts from the transcript (`TranscriptEditing.rippleDelete`) move caption tracks themselves (linked or not) — don't also
  shift captions by linkage in new transcript features.

- Session locks (P1): only a live process that is Montage holds a `.session.lock` (`SessionLock.isMontageHolder`); tests that fake
  "open in another window" must `SessionLock.registerTestHolder(pid)` (any other live pid is a stale lock = crash recovery).
- UI-test key routing: while a text field edits, the driver hands key events straight to the window (bypassing the app key
  monitor, order-dependent) — fields that need ↑ / ↓ / Return / Esc should handle them in the field (`control(_:textView:doCommandBy:)`,
  see `SwitcherSearchField`), not only in the app monitor. In this environment the real AX tree of the offscreen test window is
  empty (`AXWindows` = the application), so `a11yAudit` often falls back to the in-process walk, which sees few SwiftUI nodes.

## Known risks
- Apple on-device French STT WER ~13% without OS model download → whisper.cpp (large-v3-turbo, 547 MB) as quality path.
- Session interruptions (restart, auth, account switch) stop agents; worktrees keep work. Resume via SendMessage; if the transcript is gone, start a continuation agent pinned to the existing worktree path (worktree = source of truth, not the agent).
