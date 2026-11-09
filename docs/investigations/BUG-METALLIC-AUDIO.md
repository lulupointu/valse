# BUG-METALLIC-AUDIO: metallic voices during preview playback (owner report 2026-10-24)

Report, logs, project and media: `bugreports/2026-10-24-metallic-audio/` (README first). Owner's Intel MacBook Pro
(i7-7920HQ, macOS 13.7.8), built-in speakers at **44.1 kHz**, iPhone media with **48 kHz** AAC. While IMG_4057 played
(18:51:15 → 18:53:05 Paris time) voices sounded metallic; pause → play cleared it for good.

## Build
The installed app was built from `8b6829d` (README, plist has no SHA). That is BEFORE PB-LATENCY / PB-DROP (`917a088`,
`2cc98ba`, merged `5935025`) and PB-SEEK-LAG: in that build the clip volumes were audio-mix ramps in AVPlayer's mixer
and the lane taps only routed live effects (none in this project: passthrough).

## The report's clock-step hypothesis is refuted
The README's evidence was a +12/13 ms step of `wall − item timebase` at item ≈ 285 s (18:51:55.45 → 18:51:57.16),
"gone after pause/play". Both are artefacts of the analysis:

- `system-all-processes-…log.gz` line 2281: `18:51:55.549 === system wallclock time adjusted` — the step window.
- Log timestamps are wall clock. Against the monotonic host clock that CoreMedia prints
  (`playerfig_setBossRateWithFade … rate = 1.000, fadeDuration = nan, <host seconds>`), `wall − host` is +0.0 ±0.7 ms
  from 18:46:45 to 18:51:14.9, then **+13.3 to +14.0 ms for every later event until 19:04** (pause/play included).
  The wall clock moved, not the item clock; both VMCs (4K decode and proxy) "stepped" by the same 13 ms at once.
- "Offset gone after pause/play": `off.py` re-bases on the first sample of each window.
- No `HALC … skipping cycle due to overload` / IO overload anywhere in the session or coreaudiod logs, no
  `MCM ignoring event` between 18:51:02 and 18:53:12 (no cut was crossed: IMG_4057 was one clip, 244.018–360.938),
  one AudioQueue with data (mono lane `0x600002772640`), AQ time advancing 1:1 with the host clock (110.335 s of AQ time
  vs 110.334 s expected from the sibling queue), `startedCallback` mappings of the bug run identical in shape to the
  clean runs. Nothing in the logs distinguishes the metallic play from the clean replay of the same range at 18:54:36.

So the logs do not contain the cause. What they rule out: a clock step / drift correction, an IO overload, a duplicate
AVPlayer / item / audio queue (AQME running count 4 = the item's 4 lanes), dropped mixer volume events, proxy audio
(preview audio always comes from the original file), spatial audio (IMG_4057 has one AAC mono track, no `apac`).

## What Valse can measure: the lane output (tap) against the source
`AudioMixState.tapCapture` (new) hands tests every buffer a lane tap gives to AVPlayer's mixer, after the lane
processing. `MetallicAudioTests` compares it, buffer by buffer, with the source decoded offline
(AVAssetReader) at the composition time the tap reports.

Owner-session replay on this Mac (opt-in `VALSE_METALLIC_REPRO=1`, IMG_4057's real audio, then a white-noise WAV
control): seek + play, item replaced while playing (`forceRebuild`, as the proxy-ready swap at 18:51:08), seek while
playing, three 1.5 s all-core CPU spikes, pause → play. Result: every sounding buffer is the source **bit-exact (normalised
correlation 1.0000)**, no duplicated copy, no stretch — but **at a lag of exactly 4096 samples** (85.3 ms): the tap's
timestamp is one buffer EARLY in AVPlayer playback (same with the codec-free WAV, so not AAC priming).

| tap | preview (AVPlayer) label vs content | export (AVAssetReaderAudioMixOutput) | `duration` |
|---|---|---|---|
| post-effects (shipped) | one buffer early (4096 frames) | exact | correct (×rate at J/K/L, 1× at clip speed 1.5) |
| pre-effects (tried) | exact | — | wrong at clip speed 1.5 (1.5× the span while labels advance 1/1.5×) |

### Consequence on main (since PB-DROP, `2cc98ba`): a real preview bug, fixed here
The clip gains run in the lane taps since PB-DROP. With labels 85 ms early, in PREVIEW:
- the first 85 ms of every clip after a gap or a cut on its lane were muted (gain 0 "before the clip");
- fades, volume keyframes, ducking and loudness gains, and the live-effect switch between clips (EQ, channels, voice
  live nodes) ran 85 ms late. Export was right.

`laneOutputStartsWithTheClipsFirstSample` (clip after a gap, measured on the content): main → the clip becomes audible
85.35 ms into its source; fixed → 0. Fix: `LaneProcessor.labelsLeadOneBuffer` (preview builds only): buffer time =
stamp + the buffer's own span (`frames × duration / frames`, so ×rate at J/K/L). `exportStartsWithTheClipsFirstSample`
guards the export side (exact, unchanged).

This is NOT the owner's metallic voice (his build had no tap gains), but it is the next thing he would have heard on
main ("first syllable of every cut clipped") and it made every timing measurement through the taps 85 ms off.

## Most likely cause of the metallic voice (unverified)
With one mono AAC lane playing, no IO overload and bit-exact lane output, the remaining stage that can turn a voice
"metallic" (phasey / flanged) and be reset by a seek is AVFoundation's own render chain AFTER our tap, in the audio
queue: its TimePitch unit (every queue is built with `TimePitch (Algorithm 'tido')`, the README noted it) and the
48 → 44.1 kHz conversion of the 557-frame slices. A time-domain time-pitch left running at a rate slightly ≠ 1 (or a
converter in a bad phase) after some disturbance sounds exactly like this and is flushed by `AudioQueueReset` (any seek;
the owner's pause → play = exact seek). This Mac (Apple Silicon, macOS 26, 48 kHz output) never showed it; the owner's
macOS 13 + 44.1 kHz output is the configuration where AVFoundation already misbehaved (PB-DROP).

## Instrumentation added
- `PlaybackEngine.reportLaneAudio`: the lane taps count time jumps while sounding (a buffer that does not follow the
  previous one: duplicated audio = negative jump, hole = positive); logged every ≤ 2 s as
  `lane audio jumped N× while sounding (largest ±x ms at item t s, rate r): BUG-METALLIC-AUDIO probe`
  (subsystem `fr.valse`, error level, public). Seeks reset the taps; paused-item repeats are silent and not counted.
  The fixed owner-session replay here logs 1 jump in 21 s (around the item swap / seeks) and lane output at lag 0
  (±2 samples after a mid-play rebuild): a burst of jumps in steady playback is the signal to look for.
- `AudioMixState.tapCapture` for tests / future probes.

## Recipe / questions for the owner (Intel Mac)
1. Build from this branch (or main once merged). Before playing:
   `log stream --level debug --predicate 'subsystem == "fr.valse" OR eventMessage CONTAINS "MCM ignoring" OR eventMessage CONTAINS "overload"' > ~/metallic.log`
2. Same project 1024, built-in speakers left at 44.1 kHz. Play IMG_4057 from its start for 2 min; scrub / seek while
   playing a few times; leave proxies generating if possible.
3. When it sounds metallic: note the wall time, do NOT pause first. Switch the output to 48 kHz in Audio MIDI Setup
   while it plays (does it stop?), then pause → play. Then try once with the output at 48 kHz from the start.
4. Questions: was it like an echo / two voices slightly apart (comb), a robot / buzz (chopped), or underwater / swirly
   (phasey)? Did it start at a precise moment (a click, a seek, the app freezing briefly) or creep in?
5. Send `~/metallic.log` and the Valse unified log of the session as before. A `lane audio jumped` line at that time
   = duplicated/missing audio inside our lanes; none = AVFoundation's chain after the tap (then: test the
   48 kHz-output workaround, and a "re-prime" on a TimePitch/route event).

## BUG-CUT-AUDIO-HOLE (2026-11-08)
Owner's 2017 Intel MacBook Pro, macOS 13.7.8: PREVIEW has an audio hole at a cut (export fine everywhere; the Apple
Silicon / macOS 26 Mac has none), built-in speakers and USB earphones alike. Setup: main track A | B (B fades in at its
start); on an audio track a 0.2 s clip over the cut, fading out just after it.
- Screen recording: exactly 85 ms of all-zero samples between the 0.2 s clip's fade-out and B's fade-in. 85 ms = 4096
  frames at 48 kHz = one tap buffer; exact zeros = our lane gains (0 outside the ramps), not an IO overload.
- Unified log, same item times at every replay (deterministic, not load): `lane audio jumped 1× while sounding (largest
  +85.4 ms at item 54.889 s, rate 1.00)` and `(largest +42.7 ms at item 57.497 s …)` (2048 frames).
- Hypothesis (unproven): the one-buffer lead above (`LaneProcessor` adds one buffer span to every preview stamp) was
  measured on macOS 26 only; on macOS 13 the post-effects tap may stamp exactly (or variably), so preview gains, fades
  and clip edges are shifted by one buffer there → a hole at cuts.

Diagnostic build (default behaviour unchanged):
- Switch, read at each composition build: `defaults write fr.valse.Valse ValseTapLabelLead -int 0` = preview uses the
  stamps as is (like export); `1` = one buffer (the automatic value); `2` = two buffers;
  `defaults delete fr.valse.Valse ValseTapLabelLead` = automatic. Env `VALSE_TAP_LABEL_LEAD` wins (tests).
  Code: `TapLabelLead` (Audio/TapDiagnostics.swift), `LaneProcessor.leadBuffers`.
- Log line per lane per seek / play start (subsystem `fr.valse`, error, public; checked ≤ 1/s, nothing in steady
  playback, silent captures while paused skipped):
  `tap stamps lane 0 tap lead 1: #0 54.1173 4096f d85.33ms 48000Hz snd | #1 54.2027 4096f d85.33ms Δ+4096f 48000Hz snd | … (rate 1.00, from item 54.100 s, preview lead 1 (auto), macOS 13.7.8, out 44100 Hz / 512 f): BUG-CUT-AUDIO-HOLE probe`
  = the first 6 raw buffers after the tap's prepare / reset: stamp (s), frames, reported duration, Δ stamp in frames vs
  the previous buffer, sample rate, sound before our gains; then player rate, seek target, active lead mode, macOS
  version, default output device nominal rate / IO buffer size. What to read: whether the first stamp sits one buffer
  before the seek target (lead) or on it (exact), and whether Δ follows the previous or the current buffer's frames.
  The `lane audio jumped` line now ends with the active lead mode too.

Recipe for the owner (Intel Mac):
1. Install the diagnostic build; open the project; play across the cut from ~2 s before it with the default setting →
   note whether the hole is there.
2. `defaults write fr.valse.Valse ValseTapLabelLead -int 0` in Terminal, quit and relaunch Valse.
3. Replay across the cut the same way → hole gone, still there, or moved / doubled? (Optionally repeat with `-int 2`.)
4. `log show --last 10m --predicate 'subsystem == "fr.valse"' > ~/Desktop/valse-log.txt` and send that file
   (`defaults delete fr.valse.Valse ValseTapLabelLead` restores the default).

### Part 2: pre-effects lane taps, measured (2026-11-08, Apple Silicon / macOS 26, 48 kHz output). NOT shipped
Proposed general fix: install the lane taps pre-effects (before AVFoundation's time-pitch stage) so preview and export
label alike and the lead disappears. Measured with `TapProbeTests` (opt-in: `VALSE_TAP_PROBE=1`; `VALSE_TAP_PRE=1`
switches `AudioTap.make` to pre-effects, test/probe only; preview probes run with `VALSE_TAP_LABEL_LEAD=0`). Each tap
buffer is compared with the source decoded offline at the source time the composition's own remap
(`CompositionBuilder.remapSegments`) gives for the buffer's stamp: normalised correlation, best lag ±4800 samples, on the
first and the last 256 samples of the buffer (the last assuming contiguous source samples from the first).

Timing: pre-effects stamps are EXACT everywhere tried, preview and export (lag in samples, corr 1.000):

| layout (clip at 1 s, 3 s of 48 kHz noise) | preview head / tail lag | export head / tail lag |
|---|---|---|
| speed 1 after a gap | 0 / 0 | 0 / 0 |
| constant speed 2 / 0.5 / 1.5 | 0 / 0 · 0 / 0 · ±1 / ±1 | 0 / 0 · 0 / 0 · 0..1 / 0..1 |
| split: speed 1 then speed 2 on one lane | 0 / 0 | 0 / 0 |
| player rate 2 / 0.5 (J/K/L) | 0 / 0 · 0 / 0 | — |
| 44.1 kHz source (preview tap at 44.1 kHz, export conformed) | 0 / 0 | 0 / 0 |
| curve speed 0.5 → 2 | −5..0 / −5..0 | −5..0 (one 2-frame buffer: meaningless) |

What a pre-effects buffer is: SOURCE samples at the track's rate, contiguous (tail lag = head lag), so one frame covers
`1 / (sampleRate × segment speed)` of composition time (Δstamp / frames = 0.5 / sr at speed 2), independent of the
player rate. A buffer can straddle a speed change: at the end of a 2× clip followed by a gap, a 24592-frame buffer held
6800 frames at 2× then 17792 at 1× (Δ / frames = 0.8617 / sr), so the lane processor would need a per-segment frame →
time map (the clip's speed segments), not one step per buffer. Preview buffers were 4096 frames in quiet runs and 24592
(512 ms) in a run on a loaded machine; the first buffer after a play has no stamp; export buffers 1–4096 frames.

Why it was stopped (the brief's stop conditions, for the owner):
1. **Live effects change sound at clip speed ≠ 1, in export too.** Pre-effects, the live chain (EQ, voice-filter
   colour, echo, chorus, reverb, tremolo, ring mod, bitcrush…) runs on source samples BEFORE the time stretch, so every
   time constant scales with the clip speed. Measured, export of micEcho (0.16 s echo) on a burst: clip speed 2 →
   echo 76 ms after the burst, speed 0.5 → 320 ms (post-effects the chain runs at output rate: 160 ms by construction).
   Same for tremolo / chorus rates and reverb tails, and in preview also with the J/K/L rate. Filters, gains and fades
   are unaffected (pitch-preserving stretch keeps frequencies; a slowly varying gain commutes with the stretch).
2. **Live-effect edits are heard later in preview.** The pre-effects tap processes a buffer ~454 ms before the playhead
   reaches it (median, 41 buffers; post-effects: ~110 ms), so an EQ / voice-strength change while playing lands
   ~0.45 s late (more with 512 ms buffers).
Options (owner decision): (a) accept 1 and 2 (CapCut parity unknown); (b) pre-effects + compensate time-based effects by
the segment speed (a patch, and J/K/L stays rate-dependent); (c) keep post-effects and find a general labelling fix
there (e.g. derive the label from consecutive stamps vs the frames of the previous / current buffer, which the macOS 13
log can discriminate since its buffer sizes vary: 4474 / 4096 frames).

Side finding (pre-existing, also post-effects = main): export of a mono WAV clip with the micEcho voice effect at speed
1 is silent or nearly so: the tap stamps jump from 0 to 2.2187 s after the first 512-frame buffer (also +93.9 s at speed
2 post-effects) and the reader's output timestamps jump with them (`echoDelay` probe). Without the effect the same clip
exports fine. Fixed since as BUG-ECHO-EXPORT-SILENT (a slow first tap callback made the reader skip ahead).

### Part 3: root cause of the post-effects lead (2026-11-09, Apple Silicon / macOS 26). Owner: keep post-effects
Method (`TapProbeTests.previewLead` / `exportLead` / `seekStructure` / `longPlayDrift`, opt-in `VALSE_TAP_PROBE=1`):
irregular 30 ms noise bursts (120–320 ms apart: a periodic train aliased the first measurement) or white noise, lane
output vs the source decoded offline; lead = content time − stamp (positive: stamps EARLY), preview lead override 0.
`VALSE_PROBE_DEVICE` routes the player to an output (built-in speakers 48 kHz / 4096-frame tap buffers; Steam virtual
speakers 44.1 kHz / 4474 frames, the owner's Intel shape; the default AirPods were at 24 kHz / 8208 frames), the
`CompositionBuilder.laneTimePitch` test hook sets the lanes' algorithm. Lead in ms of item time:

| lane stretcher (mix input `audioTimePitchAlgorithm`) | r1 s1 | r2 s1 | r0.5 s1 | r1 s2 | r2 s2 | r1 s0.5 | r2 s0.5 |
|---|---|---|---|---|---|---|---|
| `.spectral` (ships) | **+85.33** | ≈ +60 | ≈ +135 | ≈ 0 | ≈ 0 | ≈ −2 | **0.00** |
| `.timeDomain` | −7.7 | −24 | +7 | −10 | −34 | **+32** (s0.25: **+102**) | 0.00 |
| `.varispeed` | +86.3 | +0.5 | +2 | +0.5 | +0.5 | — | — |
| export (AVAssetReaderAudioMixOutput), any algorithm | 0.00 | — | — | 0 (spectral), −11 (time-domain) | — | — | — |

- The item's own `audioTimePitchAlgorithm` changes nothing (lanes carry theirs); re-assigning it after `readyToPlay` is
  ignored. Each lane's AudioQueue logs `AQ Time-stretcher … Enabled the time-stretcher as (nutp)` (spectral) or `(ipto)`;
  queues are CREATED with `TimePitch (Algorithm 'tido')` on both systems, then switched to 'spec' (`qtpa`) here.
- AUNewTimePitch (`nutp`, what `.spectral` instantiates) reports kAudioUnitProperty_Latency = **4096 frames at rate 1,
  3072 at 2×, 6144 at 0.5×** (`timePitchUnitLatency`). The spectral lead on UNSCALED segments is exactly that latency in
  the LANE's frames: 85.33 ms for 48 kHz media, **92.85 ms for 44.1 kHz media** (4096 / 44100), ≈ 64 / 128 ms at 2× /
  0.5× — constant in frames, independent of the tap buffer size (4096, 4474 or 8208 frames) and of the output rate.
  On SCALED segments (clip speed ≠ 1), and whenever speed × rate brings the stretch back to 1 through a scaled
  segment (r2 s0.5), the spectral stamps are exact. Content is bit-exact and contiguous in every case at rate 1.
- After a seek (spectral, unscaled, r1): `nostamp` silent buffer, a silent buffer stamped target − 2 × 4096 frames, then
  the target's audio from frame 0 of a buffer stamped target − 4096 (`seekStructure`), at every target tried.
- So: on macOS 26 AVFoundation stamps a post-effects tap on an unscaled segment EARLY by the spectral stretcher's
  latency (as if the latency were compensated in the stamps although the bypassed stretcher adds none), and exactly on
  scaled segments; the reader (export) has no such stage. Main's "one buffer" lead only matches when the tap buffer is
  4096 frames, the media 48 kHz, the clip unscaled and the rate 1: it labels sped-up / slowed clips one buffer LATE,
  J/K/L by ~100 ms, 44.1 kHz media 7 ms off on a 48 kHz output, and everything 85 ms late on an 8208-frame output.
- The owner's macOS 13.7.8 Intel: no hole with lead 0 → its spectral stamps are ≈ exact on unscaled segments; its
  queues were created 'tido' (logged; the 'spec' switch is not in the logs he sent).

Candidate fixes tried / rejected:
- `.timeDomain` preview lanes (no lead): uniform on both systems in theory (macOS 13 queues looked 'tido'), labels a
  constant −7.7 ms at r1 s1 (stamps jitter ±4 ms; a continuity rule keeps the labels flat over 12 s), but the lead grows
  in slow motion (+32 ms at 0.5×, +102 ms at 0.25×) and J/K/L reaches −34 ms, plus lower quality on music: rejected.
- Lead = AUNewTimePitch's reported latency (queried at runtime) on unscaled segments: matches every macOS 26 case
  above, but the owner's macOS 13 needs 0 there with presumably the same AU: not general, not shipped.
- No AVFoundation knob makes the stamps exact on unscaled segments here (spectral/varispeed +1 latency, time-domain
  −8 ms ± 4). Proposed general fix (not implemented, needs a decision): MEASURE the lead at runtime from known content —
  a hidden "pilot" lane in preview compositions (a generated WAV of clicks every 0.4 s, tiled unscaled over the whole
  item, its tap detects the clicks, publishes `lead = latency frames` to `AudioMixState` and zeroes its own output);
  lanes add `leadFrames / laneSampleRate` on unscaled segments only. OS-independent, self-checking; to verify first:
  label continuity at an unscaled ↔ scaled boundary on one lane, cost of the extra queue, lanes at other rates.

Diagnostics added (ships, default behaviour unchanged): every `tap stamps … BUG-CUT-AUDIO-HOLE probe` line now ends with
`|| vs target: first stamp −170.7 ms, sound onset raw −85.3 ms / labelled +0.0 ms` (`TapDiagnostics.selfCheck`): raw
onset = (stamp + first sounding sample) − seek target = −(the stamps' lead) whenever the media sounds at the target, so
the owner's next macOS 13 log shows its lead per lane directly (≈ 0 expected); labelled = the same with the lead the lane
applied (≈ 0 = right). Each buffer also shows `snd@n` (first sounding sample).

### Part 4: is there a stamp-only rule? No (2026-11-09, same Mac). Fix NOT shipped: owner decision needed
Two checks of whether anything the tap or the engine sees (besides content) predicts the lead:
- **Architecture is not the cause.** `TapProbeTests.previewLead` (none) run as an x86_64 build under Rosetta
  (`scripts/test_x86.sh`; AudioQueue's stretcher runs in-process, translated) gives the same leads and stamp structure as
  arm64: r1 s1 +85.33 ms, r2 s1 ≈ +60..100, r0.5 s1 ≈ +135, scaled segments 0, first stamp − target −170.65 ms at r1.
  The owner's Intel difference is the OS (13.7.8 vs 26) or his output path, not x86 code.
- **The first stamp after a seek does not reveal the lead.** First stamp − seek target vs content lead (rate 1 unless
  noted, unscaled, 48 kHz built-in output):

  | lane stretcher | first stamp − target | content lead |
  |---|---|---|
  | spectral r1 / r2 / r0.5 | −170.7 / −192.0 / −192.0 ms | +85.3 / ≈ +60..100 / ≈ +135 ms |
  | varispeed r1 / r2 / r0.5 | −86.3 / −85.8 / −3.0 ms | +86.3 / +0.5 / +2 ms |
  | time-domain r1 / r2 / r0.5 | −23.2 / −11.6 / −29.0 ms | −9.1 / −24.2 / +7.2 ms |
  | any, scaled segment (s2) | 0.00 | ≈ 0 (time-domain −10..−34) |

  Spectral and varispeed share the r1 lead but not the first-stamp offset; the preroll varies per stretcher, so
  "first stamp − target" cannot be turned into a lead. Stamp steps (Δ) follow the previous buffer's frames in every case.
- What remains: the lead is only knowable from CONTENT. Options for the owner:
  1. **Pilot lane** (recommended general rule, part 3): every preview composition with lane taps gets one hidden audio
     track tiling a generated 48 kHz click file unscaled over the item, with the lanes' stretcher; its tap finds the
     clicks, publishes `lead frames` (per player rate, remembered across launches) and zeroes its output; lanes add
     `leadFrames / laneSampleRate` on unscaled segments, 0 on scaled ones. OS-independent and self-correcting by
     construction. Costs: one extra AudioQueue + decode per preview, a generated file, labels are the remembered value
     (or 0) during the first ~0.5 s of the first play at a new rate. Accuracy: exact at rate 1 (bit-exact content);
     at J/K/L rates the spectral stretch smears the clicks (this Mac's two methods disagree at r2: +60 vs +100 ms).
  2. **Source self-check** (no extra lane): after a seek, correlate the first sounding lane buffers with the clip's
     source decoded off-thread and publish the lead. Fails on lanes with live effects, quiet media, conformed audio;
     more code paths than 1.
  3. **Wait for the owner's next Intel log** (this branch's `|| vs target: … sound onset raw …` self-check): it gives
     macOS 13's lead and first-stamp structure per lane; if it shows exact stamps with 'tido' queues, the rule may be
     "lead = the stretcher's latency when the queue runs spectral", still needing a runtime way to see the queue's
     stretcher (no public API found).
  Until then preview keeps lead 1 buffer (+ the `ValseTapLabelLead` override: `-int 0` fixes the Intel hole).

### Part 5: macOS 13 reproduced in a VM, root cause, replacement study (2026-11-09). Nothing shipped
Tool: `scripts/audio_probe.sh` builds `scripts/audio_probe/AudioTimingProbe.swift` (one file, no Valse module, no test
framework, target macOS 13) and runs the SAME binary on this Mac (macOS 26.4.1, arm64) and in the Tart VM `ventura13`
(macOS 13.7.4, arm64, output "AVIODevice" 48 kHz / 512 f; it has an output device even headless). It rebuilds the
preview audio shape (composition audio track, clip at 1 s, 6 s of the burst source, optional `scaleTimeRange`, audio
mix input with an algorithm + POST-EFFECTS tap, AVPlayer, exact seek to 1.3 s, `playImmediately`) and measures on the
content like `TapProbeTests.previewLead` (lead = content − stamp, positive = stamps early). Audio-only compositions
reproduce the host's known numbers exactly (+85.33 ms), so the video track / compositor are not involved.

**1. macOS 13 reproduces the owner's Mac: stamps are exact.** Lead in ms (envelope / burst onsets), 48 kHz media,
4096-frame tap buffers on both:

| lane algorithm | system | r1 s1 | r2 s1 | r0.5 s1 | r1 s2 | r2 s2 | r1 s0.5 | r2 s0.5 |
|---|---|---|---|---|---|---|---|---|
| `.spectral` (ships) | macOS 13 VM | **0.00** | ≈ 5 (smeared) | ≈ 2 | ≈ −1 | ≈ 0 | ≈ 0 | 0.00 |
| | macOS 26 host | **+85.33** | ≈ +56..100 | ≈ +135 | ≈ −1 | ≈ +1 | ≈ −3 | 0.00 |
| `.timeDomain` | macOS 13 | 0.00 | −8.6 | +5.1 | −10.8 | −37.9 | +30.1 | 0.00 |
| | macOS 26 | −9.1 | −24.2 | +7.2 | −10.2 | −33.6 | +31.7 | 0.04 |
| `.varispeed` | macOS 13 | +85.33 | 0.0 | ≈ 0 | +0.5 | +0.5 | ≈ 2 | +2.0 |
| | macOS 26 | +86.33 | +0.5 | ≈ 2 | +0.5 | +0.5 | ≈ 2 | +2.0 |
| export (reader), any | both | 0.00 | — | — | ≈ 0 | — | — | — |

44.1 kHz media (3779-frame tap buffers): macOS 13 0.00, macOS 26 +92.88 ms (= 4096 frames at 44.1 kHz). The owner's
85 ms hole at a cut is the one-buffer lead main adds on top of exact stamps.

**2. Root cause: on macOS 26 the stamps break the API contract by the stretcher's latency.**
- Contract (MediaToolbox/MTAudioProcessingTap.h): `MTAudioProcessingTapGetSourceAudio`'s `timeRangeOut` is "the asset
  time range corresponding to the provided source audio frames", and "the caller is responsible for absorbing any
  processing delays" (an AU's reported latency must not reach the tap). We call it as documented (in-place, flags
  propagated, range from the same call): no misuse, and nothing else to read (the tap has no latency / stretcher
  property; `CMTimeRange.duration` and the flags are the only other outputs).
- AUNewTimePitch (`nutp`, what `.spectral` runs; logged on 26 as "Enabled the time-stretcher as (nutp)") reports
  kAudioUnitProperty_Latency **2048 / 1536 / 3072 frames at 1× / 2× / 0.5× on macOS 13 and 4096 / 3072 / 6144 on 26**
  (doubled). Other units unchanged (`tmpt` 2519, `vari` 48, `ipto` 1115-1116).
- AVPlayer stamp structure after a seek (unscaled, r1): first stamped buffer at target − **2048 frames** on 13
  (−42.65 ms: the owner's own log said −42.6 ms) with exact content; at target − **8192 = 2 × 4096** on 26 with content
  late by 4096. I.e. first stamp − target = −(L + lead) with L the unit's latency on that OS: 13 subtracts L once and
  is right; 26 subtracts it twice. Same for 44.1 kHz media (−2047 / −8191 frames). Scaled segments start at the target
  with exact stamps on both systems (and on 13 their first buffer carries StartOfStream 0x100).
- macOS 26 logs show AVFoundation enabling the stretcher bypass at rate 1 (`TimePitchProperty set qtpb: 1`,
  `kAudioQueueProperty_TimePitchBypass`) on the unscaled lane. So the bypassed stretcher delays nothing, yet the stamps
  are moved back by its (new, doubled) latency. macOS 13 logs none of these lines (even with
  `log config --mode level:debug` on com.apple.coreaudio / coremedia); its queues are created 'tido' like 26's.
- Below AVFoundation, a bare AudioQueue + post-effects AudioQueueProcessingTap (`AudioTimingProbe aq`) behaves the same
  on both: source frame 0 arrives 4096 + L frames after the tap's first stamp (13: 6144, 26: 8192; varispeed 4144 on
  both), bypass 0 or 1 alike; StartOfStream is set on buffer #3 on 26, never on 13. So the queue's own timeline is
  self-consistent; the error is in AVFoundation's conversion of that timeline to asset time (FigAudioQueue, private),
  which on 26 over-compensates by L while bypassed.
- The flags cannot be used to detect it: on 26 StartOfStream lands on the buffer stamped AT the target (whose content
  is target + L), on 13 it is absent in the unscaled case.
- Verdict: **tool broken** (AVFoundation regression between macOS 13 and 26, contradicting its header contract), not
  API misuse. Unscaled spectral lanes, i.e. the common case, are wrong on 26; the size of the error depends on the OS's
  stretcher latency and on the player rate, which is why no stamp-only rule exists (Part 4). Worth a Feedback Assistant
  report (probe binary + this table as the reproducer).

**3. Replacement study: export pipeline → AVSampleBufferAudioRenderer (prototype `AudioTimingProbe renderer`).**
Preview audio read by `AVAssetReaderAudioMixOutput` (the export path: exact stamps everywhere measured) and enqueued to an
`AVSampleBufferAudioRenderer` (`audioTimePitchAlgorithm = .spectral`) under an `AVSampleBufferRenderSynchronizer`
(seek = flush + new reader at the target; play = `setRate(r, time: target)`). Two variants:
- tap INSIDE the reader (today's LaneProcessor as is): labels exact, but the reader decodes and mixes ahead on its own:
  the tap runs **3.4 s** ahead of the clock unpaced and still **1.8 s** with enqueue pacing → a live-effect edit would
  be heard 2-3.5 s late. Rejected.
- **no tap; lane processing at enqueue time** (`--notap --ahead 0.15`: the feeder copies a buffer only while it is less
  than 150 ms past the clock, and would run each lane's LaneProcessor on it, labelled by the sample buffer's PTS):

| measured (spectral, 48 kHz media) | AVPlayer + tap today | renderer, enqueue-time processing |
|---|---|---|
| label lead r1 s1 (host 26 / VM 13) | +85.33 / 0.00 ms | **0.00 / 0.00 ms** |
| label lead r2, r0.5, s2, s0.5, 44.1 kHz media | OS- and rate-dependent (table above) | 0.00 (envelope corr 1.000 at r ≠ 1; scaled ≈ 0 like export) |
| 44.1 kHz output (Steam virtual speakers, host) | +85.33 ms, 4474-frame buffers | 0.00 ms |
| seek / play → moving clock, host | 215-333 ms (play after a landed seek) | 188-263 ms (first PCM 49-104 ms) |
| seek / play → moving clock, VM | 214-345 ms | 156-232 ms (first PCM 56-141 ms) |
| seek storm (12 seeks 80 ms apart while playing), host | median 355 ms, max 386 | median 185-247 ms, max 260 |
| same, VM | median 309 ms, max 321 | median 143-185 ms, max 240 |
| processing ahead of the clock (= live-edit latency) | 28 ms (26) / ~100 ms (13) | 148 ms at r1 (pacing; 75 at 2×, 300 at 0.5× in wall time) |
| output vs its clock (muted process tap, host, 14.2+) | −7 ms r1, −34 ms r2 | −7 ms r1, −38 ms r2, +2 ms r0.5 |
| CPU (one 1-lane stream, % of a core) | 2.4-4 % host, 3-5 % VM | 5-9 % host, 11-16 % VM |
| J/K/L rates | stretcher in the queue | synchronizer rate + renderer spectral stretch: clock exact at 2 / 0.5 |
| reverse | not supported (video-only emulation) | same |

- Video stays on AVPlayer (custom compositor, `AVPlayerItemVideoOutput`): `player.sourceClock` = a
  `CMAudioDeviceClock` of the output, both started with `setRate(_:time:atHostTime:)` at one host time after each seek
  (`AudioTimingProbe clocks`): audio − video clock **0.00 ms median, ≤ 0.42 ms (host) / ≤ 0.82 ms (VM)** over 2.5 s
  after each of 4 seeks.
- What PlaybackEngine would change (estimate 3-5 agent-days + a stress round): a new `PreviewAudio` engine
  (synchronizer, renderer, one AVAssetReader with one `AVAssetReaderTrackOutput` per composition audio lane, paced
  feeder, per-lane LaneProcessor + gains + live chains at enqueue, a summing mixer to one stereo stream, seamless
  rebuild via `renderer.flush(fromSourceTime:)`, output-device / route-change handling, ReaderCancel rules) ≈ 600-800
  lines; preview compositions without audio tracks (CompositionBuilder: small); PlaybackEngine transport
  (play / pause / seek / setRate / loop boundary / currentTime from the synchronizer; start both clocks at one host
  time; stall and clock watches re-based) ≈ 250 changed lines; removal of TapLabelLead / tap diagnostics / lead logic;
  tests: PlaybackTests, PlaybackStressTests, PlaybackSilenceTests, MetallicAudioTests, CutAudioTimingTests (become the
  acceptance tests) ported. Export can keep its tap (exact) or share the new per-lane code.
- Gains / risks: one output stream instead of one AudioQueue per lane (BUG-PLAY-SILENT disappears by construction), no
  audio-mix ramps (PB-DROP), no tap re-preparation on format changes (PB-QC), labels exact on every OS / rate / speed /
  output, edits while playing without `replaceCurrentItem` gaps. Risks: A/V start sync through two pipelines (measured
  locked here, but not with the custom video compositor; preroll with it never completes, STATUS C3b), a new seek
  path to stress (seek storms, stuck seeks: PB-SEEK-LAG), reader cost per seek (49-150 ms to first PCM, more under
  load and with many lanes), CPU ~2× today for the stream, output latency handling on Bluetooth / high-latency
  devices (PB-LATENCY: to verify with AirPods), AVSampleBufferAudioRenderer on Intel macOS 13 untested on hardware.
  AVAudioEngine with source nodes (the other option) gives the same exact labels but would need our own time-stretch
  for J/K/L and our own A/V clock; the renderer + synchronizer does both.
- Recommendation: replace the preview audio path (renderer + synchronizer, lane processing at enqueue) rather than
  patching the tap timing: it is the only option measured exact on both systems without an OS switch or a pilot lane.

VM how-to for engine probes: docs/TESTING.md "macOS 13 VM for engine probes".

### Part 6: phase A, `PreviewAudio` built and measured (2026-11-09). Not wired into PlaybackEngine yet
`ValseEngine/Audio/PreviewAudio.swift` (+ `PreviewAudioLanes.swift`, `PreviewAudioCheck.swift`): one AVAssetReader on the
preview composition (built with `audioTaps: false`), one `AVAssetReaderAudioMixOutput` per lane (`BuiltComposition.audioLanes`:
the lane's track, clips, gain ramps), `LaneProcessor` on each reader buffer at its PTS (no lead), lanes summed into
1024-frame stereo chunks → `AVSampleBufferAudioRenderer` (spectral) under an `AVSampleBufferRenderSynchronizer`; feeder on
a private serial queue, paced 150 ms ahead of the clock. Measured on the ENQUEUED chunks (no output capture on 13), the
same numbers on macOS 26.4.1 (host) and 13.7.4 (VM, `scripts/audio_probe.sh --vm --app`):
- burst onsets vs labels: 0 frames at rate 1 / 2 / 0.5; 44.1 kHz media −0.8..−1.1 frames (reader resampler); speed 2 /
  0.5 segments: envelope −1..−2 ms (spectral smear; export measured the same way gives ≈ 0..2.5 ms).
- the owner's cut (A fading out | B fading in) + a clip after a gap: = the export mixdown (max |diff| 4e-6, lag 0).
- seek → first chunk 92-177 ms, seek → moving clock 178-228 ms (host) / 215-219 ms (VM); 12 seeks 80 ms apart: no
  deadlock, one reader open, engine released, clock running 300-430 ms after the last seek, labels exact.
- live EQ edit heard 180 ms after the clock at the edit (150 ms queue + a chunk); pause / resume: clock still, no flush,
  labels continuous, resume 13-23 ms; `replace` while playing: no discontinuity, new gains heard 185 ms after.
- `renderer.flush(fromSourceTime:)` was refused even 80 ms ahead of the clock with 40 ms queued past it (the renderer has
  consumed the paced queue): a swap continues where the queue ends instead.
- Reverse shuttle: rates ≤ 0 pause the audio (silent, as with AVPlayer today; the prototype has no reverse either).

## Files
- `app/Sources/ValseEngine/Audio/TapDiagnostics.swift` (`TapLabelLead` switch, `TapDiagnostics` stamp capture,
  default output format), `app/Tests/ValseEngineTests/TapLabelLeadTests.swift` (BUG-CUT-AUDIO-HOLE).
- `app/Sources/ValseEngine/Audio/AudioMix.swift` (`LaneProcessor.labelsLeadOneBuffer`, jump probe, `tapCapture`),
  `Audio/AudioTap.swift` (doc), `Composition/CompositionBuilder.swift` (preview → labels lead),
  `Playback/PlaybackEngine.swift` (`reportLaneAudio`, `laneAudioJumps`).
- `app/Tests/ValseEngineTests/TapProbeTests.swift`: part 2 / 3 probes (opt-in `VALSE_TAP_PROBE=1`; `VALSE_TAP_PRE=1`,
  `VALSE_PROBE_DEVICE=<output UID>`, `VALSE_PROBE_ALGOS=none,x/S,x/T,x/V`, `VALSE_PROBE_SPEEDS=1`, `VALSE_PROBE_SRC=44100|aac`);
  `CutAudioTimingTests.swift`: acceptance tests for the future fix (opt-in, fail on main as described in part 3);
  `AudioMixdown.render(…, audioState:)` lets a test read the export lanes' taps; `CompositionBuilder.laneTimePitch` hook.
- `scripts/audio_probe/AudioTimingProbe.swift` + `scripts/audio_probe.sh` (part 5): standalone probe (player / export /
  aq / renderer / clocks / au / devices / matrix / replacement), host and macOS 13 VM; logs in build/audio_probe/.
- `app/Tests/ValseEngineTests/MetallicAudioTests.swift`: two regression tests (preview / export clip start) and the
  opt-in owner-session replay + tap timeline probe (`VALSE_METALLIC_REPRO=1`, `VALSE_METALLIC_MEDIA=wav`).
