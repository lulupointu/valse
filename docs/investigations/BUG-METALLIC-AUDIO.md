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

## What Montage can measure: the lane output (tap) against the source
`AudioMixState.tapCapture` (new) hands tests every buffer a lane tap gives to AVPlayer's mixer, after the lane
processing. `MetallicAudioTests` compares it, buffer by buffer, with the source decoded offline
(AVAssetReader) at the composition time the tap reports.

Owner-session replay on this Mac (opt-in `MONTAGE_METALLIC_REPRO=1`, IMG_4057's real audio, then a white-noise WAV
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
  (subsystem `fr.montage`, error level, public). Seeks reset the taps; paused-item repeats are silent and not counted.
  The fixed owner-session replay here logs 1 jump in 21 s (around the item swap / seeks) and lane output at lag 0
  (±2 samples after a mid-play rebuild): a burst of jumps in steady playback is the signal to look for.
- `AudioMixState.tapCapture` for tests / future probes.

## Recipe / questions for the owner (Intel Mac)
1. Build from this branch (or main once merged). Before playing:
   `log stream --level debug --predicate 'subsystem == "fr.montage" OR eventMessage CONTAINS "MCM ignoring" OR eventMessage CONTAINS "overload"' > ~/metallic.log`
2. Same project 1024, built-in speakers left at 44.1 kHz. Play IMG_4057 from its start for 2 min; scrub / seek while
   playing a few times; leave proxies generating if possible.
3. When it sounds metallic: note the wall time, do NOT pause first. Switch the output to 48 kHz in Audio MIDI Setup
   while it plays (does it stop?), then pause → play. Then try once with the output at 48 kHz from the start.
4. Questions: was it like an echo / two voices slightly apart (comb), a robot / buzz (chopped), or underwater / swirly
   (phasey)? Did it start at a precise moment (a click, a seek, the app freezing briefly) or creep in?
5. Send `~/metallic.log` and the Montage unified log of the session as before. A `lane audio jumped` line at that time
   = duplicated/missing audio inside our lanes; none = AVFoundation's chain after the tap (then: test the
   48 kHz-output workaround, and a "re-prime" on a TimePitch/route event).

## Files
- `app/Sources/MontageEngine/Audio/AudioMix.swift` (`LaneProcessor.labelsLeadOneBuffer`, jump probe, `tapCapture`),
  `Audio/AudioTap.swift` (doc), `Composition/CompositionBuilder.swift` (preview → labels lead),
  `Playback/PlaybackEngine.swift` (`reportLaneAudio`, `laneAudioJumps`).
- `app/Tests/MontageEngineTests/MetallicAudioTests.swift`: two regression tests (preview / export clip start) and the
  opt-in owner-session replay + tap timeline probe (`MONTAGE_METALLIC_REPRO=1`, `MONTAGE_METALLIC_MEDIA=wav`).
