# PB-LATENCY / PB-DROP: preview playback on the owner's Intel Mac (2026-10-24)

Hand-off note for the session that finishes this on a machine that can build Montage. Branch `fix-pb-latency`
(fix commit `917a088`, on top of main `8b6829d`). **The fix has never been compiled or tested**: the Mac where the bugs
were seen (Intel i7-7920HQ, macOS 13.7.8) only has Command Line Tools / Swift 5.8.1 and the package needs Swift 6.2.
Everything below comes from that Mac's unified log (`log show --predicate 'process == "Montage"'`) and the code.

## Verification on the build Mac (2026-10-24, Apple Silicon, macOS 26.4) — read this first

Commit `2cc98ba` supersedes the `917a088` fix. Harness: `PlaybackDeviceReproTests` (opt-in, `MONTAGE_PB_REPRO=1`, env
vars documented in the file): a real `PlaybackEngine` / AVPlayer routed to virtual outputs (nothing on the speakers),
the 1023 layout with one sine pitch per track; output recorded from the device's loopback with a CoreAudio recorder
(ffmpeg's avfoundation capture dropped ~20 % of the samples: useless) and analysed per clip (100 ms windows) and per
cut (20 ms windows). Outputs: "Steam Streaming Speakers" (44.1 kHz) with a 4096-frame IO buffer = clock lead 0.36–0.44 s
(the owner's 0.35–0.37 s); "Background Music" at 44.1 kHz / 512 frames = the owner's built-in speakers config.

- **PB-LATENCY reproduced and fixed.** main: every play from a seek (and resume in place) went BACKWARDS (2.0 → 1.65 s
  in 2.5 s, 4 re-primes). `2cc98ba`: +1.9–2.0 s, 0 re-primes, 0 rebuilds. `917a088`'s guard was right; `2cc98ba` also
  moves the floor to where a tolerant seek landed and to every clock start without a seek (resume, `setRate`).
  Regression test (no device needed): `PlaybackLatencyTests` — fails on main (13 re-primes), passes now.
- **PB-DROP: trigger reproduced, audible symptom NOT reproduced on this Mac.** main with 48 kHz media on the 44.1 kHz
  output logs the owner's exact lines (`MCM ignoring event at invalid buffer offset 3804/557`, ~80 per play, at the
  cuts), yet in 46 plays (incl. an output switch while playing, as when the AirPods were unplugged) no lane ever went
  silent, not even for 20 ms. This macOS evidently heals a dropped ramp value within a render chunk; macOS 13 likely
  does not (the owner's symptom). Not testable here.
- **`917a088`'s PB-DROP fix made it WORSE here**: with no volume curve at all in the mix, a lane's mixer input stayed
  muted for whole plays (8 plays in 12; the tap's output for that lane was verified non-silent: the mixer muted it).
  A constant step `setVolume(1)` or one 1→1 ramp over the item: 1 play in ~20 muted. One 1→1 ramp per clip (the
  shape of the old per-clip ramps, values all 1): 0 in 36 plays. That is what `2cc98ba` ships: gains in the taps,
  mixer values all 1, so whatever AVPlayer drops at a cut cannot change a lane's level, on any macOS.
- Tapless fallback (frozen-clock recovery) keeps main's mix unchanged (removing the clip-end 0s made a lane start one
  85 ms chunk at the wrong level here: reverted). It still carries PB-DROP's risk on macOS 13, as before.
- Also fixed in `917a088`'s code: `Int(∞)` crash on the audio thread past a lane's last clip; gains at rates ≠ 1 (tap
  buffer duration used); untimed tap buffers hold the last gain; export uses the same tap gains (gain > 1 applied in
  full, `LaneGainTests.exportAppliesGainsAboveOne`).
- **To confirm on the owner's Intel Mac (macOS 13)**: play project 1023 on the built-in speakers at 44.1 kHz across the
  cuts several times; `log stream --predicate 'process == "Montage" AND eventMessage CONTAINS "MCM ignoring"'` will
  still show a few lines at cuts (values 1, harmless); no lane should drop.

## Symptoms (owner, project "1023")

1. **PB-DROP** (2026-10-23, after unplugging AirPods → built-in speakers): playback runs, but at every cut one or
   several audio lanes go silent (always at least one audible, a different set at each cut). Pause + play restores
   every lane until the next cut. Never happened while on the AirPods. Reproduced again 2026-10-24 13:19 with the
   main build of 11:27 (`8b6829d`), built-in speakers.
2. **PB-LATENCY** (2026-10-24 11:20, another output device): pressing play does nothing; the player "tries" but the
   playhead never advances.
3. (Already fixed on main, FLAKY-THUMB `b827eab`) the installed app then dated from `0060d48`: one end-of-media
   timeline thumbnail (IMG_9727 at 30.0 s, quantum 120) failed and was regenerated on every redraw — ~60
   AVAssetImageGenerator decodes per second for the whole session. Gone with the 11:27 build (8 VMCs per session).

Owner could NOT reproduce on the build Mac: see "Why it does not reproduce everywhere".

## Project 1023

`~/Movies/Montage/1023.montage` on the Intel Mac. 1080×1920, 25 fps, ≈25.4 s. Media: three iPhone clips (HEVC 4K
portrait, AAC stereo **48 kHz**), proxies ready (720p H.264). Times below in seconds (model ticks = 705 600 000/s).

| track | clips (start s) | audio composition lanes |
|---|---|---|
| main (IMG_9727, volumes 1.07 / 1.82) | 0, 5.523, 9.650, 11.520, 18.286, 20.854, 22.865 | 2 (A/B, clips alternate) |
| overlay 1 (IMG_9725, linked) | 5.503, 11.563, 18.286, 20.854, 22.865 | 1 |
| overlay 2 (IMG_9726, vol 2.69, linked) | 11.520, 20.854, 22.865 | 1 |
| audio A (extracted 9725 / 9726) | 0, 5.523, 9.650, 18.286 | 1 |
| audio B (extracted 9725) | 9.650 (1.91 s) | 1 |

So ~6 audio composition tracks, each with cuts; every lane has a tap (`LaneProcessor`) and per-clip audio-mix ramps.

## PB-LATENCY: the stall watchdog re-primes forever

### Evidence (session pid 12291, 11:20)
- AVPlayer rate log (`-[AVPlayer _setRate:…]`) alternates PLAY / pause every ~0.45 s for minutes, each pause followed by
  a seek to a time slightly EARLIER than the previous one: `1.773 → 1.752 → 1.731 → 1.693 …`, `5.053 → 5.027 → 4.997 …`.
  Every ~3 cycles a new player item (`reason CurrentItemChanged`) = `maxFutilePrimes` → `forceRebuild`.
- Output device latency (`subaq_getAudioQueueLatencyFigTime: Returning audio device latency as …`): **0.274 s**.
- After each seek + play, the item clock starts BEFORE the seek target (`figPlaybackBoss_timebaseRateChangedDeferredWork:
  Timebase rate changed to non-zero @-0.352s. Will reach preroll time 0.000s`; `subaq_performStartupSync … media time -0.352`).

Measured lead (preroll time − start of the clock) per output, from the owner's logs:

| output latency | lead |
|---|---|
| 0.007 s (built-in speakers) | 0.16–0.17 s |
| 0.190 s (AirPods) | 0.25–0.27 s |
| 0.274 s (11:20 device) | 0.35–0.37 s |

### Mechanism
`PlaybackEngine.watchForStall` (called from `pixelBuffer(forHostTime:)` every display refresh): when the ITEM time
advances `stallSpan` = 0.3 s with no new frame, it re-primes with an exact seek to the current item time. During the
lead the item time is before the seek target, where no frame exists, so a lead > 0.3 s always fires it — at a time
before the target, so the next lead is just as long: endless loop, playhead creeping backwards. AirPods (lead 0.25) and
the built-in speakers (0.17) stay under 0.3, hence "works on my other Mac / worked yesterday".

### Fix (in `917a088`)
`performSeek` records `seekTarget` (item time − tolerance); `watchForStall` does not watch while `itemTime < seekTarget`.

### Reproduce anywhere
- Real way: an output whose lead exceeds 0.3 s (latency ≳ 0.2 s): a Bluetooth speaker, some AirPlay / HDMI outputs.
  Check `log stream --predicate 'process == "Montage"' | grep "device latency"`.
- Any Mac: on **main**, temporarily set `PlaybackEngine.stallSpan` to `0.1` (below the ~0.17 s built-in lead), build,
  open any project, press play: the loop above appears (pause/seek/play every ~0.3 s, `stallRecoveries` climbing,
  playhead stuck). With `fix-pb-latency` + the same temporary `0.1`, playback must run normally. Revert the constant.
- A unit-level regression test is still missing (idea: a test seam to feed `watchForStall` item times below the seek
  target, or a `PlaybackEngine` hook for the clock lead).

## PB-DROP: lanes silent after a cut on a 44.1 kHz output

### Evidence
- CoreAudio logs `[com.apple.coreaudio:mcmx] AUMultiChannelMixer3.cpp:629 MCM ignoring event at invalid buffer offset
  3556/557` (also …/558). 557.3 = 512 × 48000 / 44100: the mixer renders 48 kHz media in slices sized for a 512-frame
  44.1 kHz device. Occurrences in the owner's logs:
  - only while the output was a 512-frame device (built-in speakers dev 72, the 11:20 device dev 82): ~230 on 10-23,
    105 on 10-24 13:19;
  - **never** on the AirPods (dev 125, 480-frame IO buffer at 48 kHz, i.e. no rate conversion) during ~20 min of editing.
- 10-24 13:19 session (main build, built-in speakers): every burst of MCM lines falls on a cut. Converted to timeline
  time using the play starts (play 09.943 from 0; 18.404 from 5.180; 21.539 from 3.398; 35.749 from 3.962): bursts at
  ≈5.4–5.7 s (cut 5.50/5.52) on four separate plays, ≈9.5–9.9 s (cut 9.65), ≈11.4–11.7 s (cut 11.52/11.56).

### Mechanism (hypothesis — correlation is exact, but the log does not say WHICH event was dropped)
`CompositionBuilder` sets each lane's clip volumes as audio-mix ramps: `setVolume(0, at: 0)`, per clip a
`setVolumeRamp` over the clip, `setVolume(0, at: clipEnd)`. AVPlayer feeds these to the mixer as parameter events per
render slice; with a sample-rate converting output some events get offsets beyond the slice and are ignored. When the
dropped event is a clip's opening ramp, its lane stays at the 0 set at the previous clip end → silent until a seek
(which re-evaluates the whole volume timeline). Fits: random lanes per cut, play/pause restores, AirPods fine.

### Fix (in `917a088`)
Preview builds with taps apply clip gains inside `LaneProcessor` (the lane's MTAudioProcessingTap), sample by sample,
from the same ramps (`CompositionBuilder.volumeRamps`), silence outside them; the audio mix then carries NO volume
events. Export and tapless builds (`audioTapsDisabled` after a frozen clock, `AudioTap.make` failure) still use the
mix ramps (`CompositionBuilder.apply`). Expected result: no "MCM ignoring event" lines at all during preview playback.

### Reproduce anywhere
1. Audio MIDI Setup → the output you listen on (built-in speakers or headphones) → Format **44 100 Hz** (Apple Silicon
   built-in speakers usually default to 48 kHz: probably why the build Mac does not reproduce). Restart Montage.
2. A project like 1023: **48 kHz** media (any iPhone .MOV; or ffmpeg sines, a different pitch per track so a missing
   lane is audible), main track with ≥ 4 cuts (A/B lanes), one or two overlay video tracks and an audio track with
   audible clips crossing the same cuts. Copying `1023.montage` needs its media (IMG_9725–9727, ~460 MB).
3. `log stream --predicate 'process == "Montage" AND eventMessage CONTAINS "MCM ignoring"'` while playing from 0 across
   the cuts. On main: MCM lines at the cuts and lanes dropping; on `fix-pb-latency`: no MCM lines, nothing drops.
   If no MCM lines appear on main even at 44.1 kHz, try a 512-frame IO buffer and more lanes before concluding.

## What changed in `917a088`
- `MontageEngine/Playback/PlaybackEngine.swift`: `seekTarget`, guard in `watchForStall`.
- `MontageEngine/Composition/CompositionBuilder.swift`: `applyVolume` split into `volumeRamps` + `apply`; build collects
  each lane's ramps and gives them to the tap (preview) or the mix (export / no tap).
- `MontageEngine/Audio/AudioMix.swift`: `GainRamp`; `LaneProcessor(gains:)`, `applyGains` (linear per sample inside a
  ramp, 0 outside), `routeLive` (old routing loop), `nextTime` when the tap gets no timestamp.
- `Tests/MontageEngineTests/LaneGainTests.swift` (new): tap gains / silence / cut / no timestamp / seek back; preview
  build has no mix ramps, export and `audioTaps: false` do.

## To do on the build Mac
1. Reproduce both on main (recipes above) to confirm the diagnosis before trusting the fix.
2. Build `fix-pb-latency`; fix compile errors (it was written blind).
3. `scripts/test.sh --filter 'LaneGainTests|VolumeCurveRenderTests|AudioPipelineTests|PlaybackStressTests|PlaybackSkipTests'`,
   then `scripts/check_fast.sh`; `scripts/test_x86.sh --filter LaneGain` (the owner's Mac is Intel).
4. Repeat the reproductions on the branch; add the PB-LATENCY regression test.
5. Merge through the batch flow (`check_clean.sh --ui`, `merge_agent.sh`); STATUS rows PB-LATENCY / PB-DROP.

### Risks to check
- Tap gains assume the post-effects tap gets Float32 (`AudioTap.Box.nonFloat` skips processing: the clips would then
  play at unity gain in preview, never silent) and a correct composition timestamp (`range.start`); the existing EQ
  routing already relies on it. Check fades / keyframed volume / ducking by ear and with a quick cut preview (skips).
- Gains > 1 (1023 uses up to 2.69) now scale samples in the tap instead of the mixer: listen for clipping.
- Suggestion: have `scripts/build_app.sh` stamp the git SHA into Info.plist; the installed app on the Intel Mac had no
  commit id, and it lagged main by several merges.
