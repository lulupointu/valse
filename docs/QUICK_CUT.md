# Quick cut (TL-048): spec, research, design

Owner brief 2026-10-22: "At the click of a button, the user can cut all the blanks from their audio/video clips in the
timeline." Typical use: import every rush into the timeline at the start of a project, select all (or nothing), and do a
quick first clean-up. It must be fast, and the preview must follow the duration slider in real time.

## 1. UX (owner sketch, wording refined to the app's style)

- **Entry:** a "Quick cut" button in the timeline toolbar (FR "Coupe rapide"), tooltip with a one-line explanation.
  It opens a popover anchored to the button:
  - Scope line (secondary text): "Applies to all media clips" / "Applies to the 3 selected media clips" / "Applies to
    the selected media clip" (FR "S'applique à tous les clips média" / "aux 3 clips média sélectionnés" / "au clip
    média sélectionné"). No selection = every audio/video clip; otherwise only the selected audio/video clips.
  - Title: "Remove blanks longer than" (FR "Supprimer les blancs de plus de").
  - Slider 0.1 … 5.0 s, step 0.1, plus a text field ("0.5 s") bound to the same value (clamped, 1 decimal).
  - Default = the last value used, app-wide (shared across projects, UserDefaults). First launch: 0.5 s.
  - Summary line: "12 blanks · −18.4 s" (FR "12 blancs · −18,4 s"), or "No blanks longer than 0.5 s".
  - While analysis is still running: progress line "Analysing audio… 3 / 12" (determinate), the overlay fills in clip by
    clip as results arrive.
  - "Apply" button (primary). Esc / clicking outside the timeline and the player = cancel, nothing changes.
  - While it is open, a click (or drag) on the timeline (ruler, empty track area, clip body, track header = time 0)
    only moves the playhead to the clicked time (owner bug report 2026-10-23): it neither closes the popover nor
    changes the selection, so the user can listen to the preview from any point.
- **Live preview while the popover is open:**
  - On target clips, every slice that will be removed is drawn over the clip (thumbnails + waveform), updated on every
    slider / text-field change. The owner's red is a sketch: use a colour that reads as "will be removed" without
    alarming. Suggested: a translucent dark veil with diagonal hatching and a thin accent edge, so the thumbnails still
    show through (match the app's timeline palette, both appearances).
  - Clips that are not targets are dimmed (look disabled) while the popover is open.
  - Pressing play (Space or the player button) plays the timeline with the marked slices skipped, so the user can hear
    the result before applying.
- **Apply** = ONE undo step. Toast: "Removed 12 blanks (−18.4 s)" (FR "12 blancs supprimés (−18,4 s)").

## 2. What a "blank" is

For a user, a blank is dead air: nobody is speaking and nothing meaningful is audible. In practice that covers silence
before a take starts and after it ends, pauses between sentences, hesitations without voice, breaths, mouth clicks,
room tone, hum, a passing car. It does **not** mean digital silence: real rushes always have background noise, and
levels differ between media (a lav mic at −12 dBFS next to a phone at −35 dBFS).

Technically: **a span of the clip's source audio where no speech or speech-level sound is detected, relative to that
media's own speech level and its local background noise**, plus any span the clip makes inaudible (volume 0, muted,
faded out). Conservative bias: when unsure, keep the audio. Cutting a word is much worse than leaving a pause (the user
can always lower the duration). A music bed or other continuous loud sound is not a blank.

Owner decisions (2026-10-22):
- A clip in which nothing is detected at all (silent B-roll, room tone only, steady tone/music without dynamics) is
  **left untouched**: Quick cut never deletes a whole clip. Clips without an audio track are untouched too.
- Scope covers **all tracks**. Main-track clips are cut and the main track closes up (ripple); linked / detached audio
  and captions follow the cuts. Clips on other tracks (voice-over, overlays) are cut and close up **inside the clip's own
  footprint** only: later items on that track don't move.
- **One detector**: EditPilot's `remove_silences` switches to the Quick cut analysis (the old `ActivityProfile`
  silence threshold stays only for "boring parts" if still needed there).

## 3. Research (done before reading any app code; bench in `docs/quickcut/`)

Corpus: 150 s of EN + FR speech (4 voices, 30 sentences, 27 known pauses of 0.12 … 3.5 s, random per-sentence gain),
degraded 10 ways: clean, −30 dB quiet, +15 dB clipped, pink noise at 25 and 12 dB SNR, 50 Hz hum, traffic noise
swinging ±7.5 dB, breaths + mouth clicks + room tone in every pause, 400 ms reverb, music bed at −20 dB. Ground truth
comes from the clean signal. Metrics per max-blank X: audible speech removed (frames within 30 dB of the speech peak),
% of pause time removed, missed pauses. Raw output: `docs/quickcut/results_pad.txt`. Reproduce: `docs/quickcut/gen_corpus.sh <out>` (macOS `say` +
ffmpeg), then `swiftc -O docs/quickcut/bench.swift -o <out>/bench && <out>/bench <out>`.

| Strategy | Result |
|---|---|
| S1 fixed −40 dBFS | Breaks as soon as levels change: deletes all speech at −30 dB, finds 0 % of the pauses with noise at 12 dB SNR or with traffic. |
| S0 app's `ActivityProfile` (50 ms RMS, global 10th/90th percentile threshold) | Fine on clean audio. Traffic: 43 % of pauses found. In noise and hum it cuts 0.5–1 s of audible speech at X = 0.3–0.5. |
| S2 global adaptive threshold on speech-band (150–4000 Hz) energy | Good, but a varying background defeats it (traffic 58 %) and breaths split pauses. |
| S3 voicing (pitch periodicity) defines the speech edges | Pauses found, but cuts unvoiced consonants (s, f, t). |
| **S5 hybrid** (chosen) | Speech-band energy against a **local** noise floor gives the edges; **voicing** decides whether a loud run is speech or a breath / click / noise swell. At X = 0.5: 0 ms audible speech cut in 7 of 10 conditions, ≤ 90 ms in noisy ones; 89–94 % of pause time removed (the rest is the protective handles) everywhere except under a music bed (44 %, conservative by design). |

Speed (M-series, one core, naive Swift + vDSP): audio-only decode with `AVAssetReader` at 16 kHz mono ≈ 1000× realtime
(30 min file in 1.6 s, per-file overhead ≈ 0.15–0.5 s); feature extraction ≈ 3000× realtime. 2.5 h of rushes ≈ 10 s on
one core, ~3 s with 4 parallel files. Recomputing the cut plan for a new X is a linear pass over a cached bit mask:
microseconds per clip.

## 4. Algorithm (S5, the reference implementation is `Hybrid(attach: true)` in docs/quickcut/bench.swift)

Per **media** (source time, cached by content hash, independent of any clip):
1. Decode the first audio track to 16 kHz mono Float32 (audio track only, never the video).
2. Band-pass 150 Hz HP + 4 kHz LP (biquads). Per 10 ms hop, 25 ms window: band energy `e` (dB).
3. Voicing, only for frames with `e > p10(e) + 4 dB`: max normalised autocorrelation for lags of 67–400 Hz on the
   band signal decimated to 8 kHz, 32 ms window (vDSP dot products).
4. Local floor `lf`: 210 ms moving mean of `e`, then a sliding minimum over ±1.5 s, clamped to ≥ −90 dB. Speech peak
   `pk = p97(e)`.
5. Loud: `e > lf + max(6, 0.3·(pk − lf))`, extended frame by frame on both sides while
   `e > lf + max(3, 0.3·(pk − lf)) − 6` (hysteresis); gaps ≤ 40 ms closed.
6. A loud run is **speech** if it has ≥ 4 voiced frames (autocorr > 0.5), or lasts ≥ 80 ms with a peak > `pk − 12 dB`.
   An unvoiced run ≥ 30 ms within 200 ms of a speech run is kept as speech too (consonants, word tails).
7. **Speech edges** (TL-048-fix2, owner report on the "1018 (1)" iPhone rushes): the leading / trailing frames of each
   speech run whose **full-band** energy (same 25 ms window, fricatives above 4 kHz included) is more than 35 dB under
   the media's full-band p97 are dropped; an attached run (step 6) entirely under that level is dropped, a speech run
   entirely under it (quiet speaker) is kept whole. One level for both edges: onsets rise through it within a frame,
   but word endings decay over 200–300 ms (plus room reverb), and step 5's hysteresis followed that decay down to the
   floor, so ≈ 0.1 s more was kept after speech than before it. Measured on the owner's two clips (X = 0.3: 9 cuts before, 11 after since pauses get longer;
   reference = last / first frame within 35 dB of the full-band peak): kept after speech 0.10–0.16 s (mean 0.12 s)
   before vs 0.05 s after the fix; kept before speech 0.05–0.08 s before vs 0.05 s after. Bench corpus: no more audible
   speech cut than before in any condition (30 dB started clipping word endings, 25 dB more so).
8. Store: the speech mask (1 bit per 10 ms ≈ 750 B per minute) + `hasDynamics` (false when nothing qualifies or
   `pk − floor < 10 dB` → whole clip untouched).

Per **clip**, at every slider change (pure, MontageCore):
1. Take the mask over the clip's source range and map it to timeline time (speed / ramps).
2. Frames the clip makes inaudible (effective clip gain ≤ −40 dB: volume, volume keyframes, fades, clip mute) are
   blank too. Uniform volume changes don't matter: detection is relative per media.
3. A blank run qualifies when its **raw** timeline length > X (what the user means by "a blank of more than X").
4. Removed slice = the run minus handles: **50 ms after the previous speech and 50 ms before the next speech**, so a
   cut pause plays as 0.1 s in total, symmetric (owner decision 2026-10-23; `QuickCut.handleAfter` / `handleBefore`).
   Word tails stay audible because they are part of the detected speech run (down to 35 dB under the peak, step 7;
   step 6 attaches unvoiced consonants), not because of a longer end handle. A run that touches the clip's start or
   end keeps only the speech-side handle. Drop slices < 40 ms.
   Why the end used to leave a blank: the former handles (140 ms after, 60 ms before) measured on the bench corpus at
   X = 0.5 as a median of 140–160 ms kept after the end of speech vs 60–70 ms before its start. With 50 / 50 ms the
   medians are 50–70 ms after and 50–60 ms before in every condition except 400 ms reverb (the reverb tail is detected as
   sound). The 200 ms attach rule of step 6 made no measurable difference to the trailing pause.
5. Clips with no speech at all, no audio track, or no dynamics: no slices (owner decision).

## 5. Performance budget (acceptance)

- 30 clips × 5 min (2.5 h): first-time analysis ≤ 10 s wall on M1 with parallel files at utility QoS. Analysis starts
  in the background when media is imported (low priority, cancellable, never blocks the UI), and the popover requests
  whatever is still missing, with progress.
- Slider drag: plan for 30 clips + overlay redraw within one frame (plan computation < 2 ms total, measured in a unit
  test).
- Apply on 30 clips with ~300 cuts: < 300 ms, one undo step.
- Cache: `Caches/Montage/quickcut/<contentHash>.v2` (suffix bumped whenever the detector's output changes; v2 = step 7), memory + disk. Proxies are irrelevant (audio only).
