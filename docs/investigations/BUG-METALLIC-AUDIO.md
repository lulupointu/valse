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

## Files
- `app/Sources/ValseEngine/Audio/TapDiagnostics.swift` (`TapLabelLead` switch, `TapDiagnostics` stamp capture,
  default output format), `app/Tests/ValseEngineTests/TapLabelLeadTests.swift` (BUG-CUT-AUDIO-HOLE).
- `app/Sources/ValseEngine/Audio/AudioMix.swift` (`LaneProcessor.labelsLeadOneBuffer`, jump probe, `tapCapture`),
  `Audio/AudioTap.swift` (doc), `Composition/CompositionBuilder.swift` (preview → labels lead),
  `Playback/PlaybackEngine.swift` (`reportLaneAudio`, `laneAudioJumps`).
- `app/Tests/ValseEngineTests/MetallicAudioTests.swift`: two regression tests (preview / export clip start) and the
  opt-in owner-session replay + tap timeline probe (`VALSE_METALLIC_REPRO=1`, `VALSE_METALLIC_MEDIA=wav`).
