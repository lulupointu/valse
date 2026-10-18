@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Energy voice-activity detection on the speech WAV, used to snap recognised word boundaries to the real speech
/// onsets / offsets (owner bug: captions early / late, cut at wrong places).
///
/// Whisper's word times come from its 20 ms attention frames (DTW) or, without DTW, from interpolated timestamp tokens
/// that routinely start a word inside the preceding pause and stretch its end over the next one. A word whose start lies
/// in silence is moved forward to the next speech onset; a word whose end lies in silence is moved back to the last
/// speech offset — so pauses become visible to the caption segmenter and captions appear with the voice. Words inside
/// continuous speech (no silence around) keep their engine timing. No model needed (works for every engine); a quiet
/// recording, music bed or room noise only makes the detector more conservative (nothing counts as silence → no snap).
public struct SpeechActivity: Sendable {
    /// Frame hop (seconds).
    public static let hop = 0.01
    /// Per-frame "speech" flags.
    public let speech: [Bool]
    public let thresholdDB: Double

    public init(speech: [Bool], thresholdDB: Double = 0) { self.speech = speech; self.thresholdDB = thresholdDB }

    /// Frame energies (dB) → speech flags. Threshold: 35 dB under the loud speech level (98th percentile), but at least
    /// 12 dB over the noise floor (10th percentile); runs shorter than 30 ms are ignored.
    public init(frameDB db: [Double]) {
        guard !db.isEmpty else { self.init(speech: []); return }
        let sorted = db.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)], peak = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let thr = max(floor + 12, peak - 35)
        var sp = db.map { $0 > thr }
        // a breath / click shorter than 30 ms is not a speech onset
        var i = 0
        while i < sp.count {
            guard sp[i] else { i += 1; continue }
            var j = i
            while j < sp.count, sp[j] { j += 1 }
            if j - i < 3 { for k in i..<j { sp[k] = false } }
            i = j
        }
        if peak - floor < 10 { sp = Array(repeating: true, count: db.count) }   // no dynamics: can't tell silence
        self.init(speech: sp, thresholdDB: thr)
    }

    /// Reads a mono PCM WAV (any rate) and computes 10 ms frame energies.
    public static func analyze(wav: URL) -> SpeechActivity? {
        guard let f = try? AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let sr = f.processingFormat.sampleRate
        let hopN = max(1, Int(sr * hop))
        let chunk = AVAudioFrameCount(hopN * 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { return nil }
        var db: [Double] = []
        db.reserveCapacity(Int(Double(f.length) / Double(hopN)) + 1)
        var acc = 0.0, n = 0
        while (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 {
            guard let ch = buf.floatChannelData?[0] else { break }
            for i in 0..<Int(buf.frameLength) {
                let x = Double(ch[i]); acc += x * x; n += 1
                if n == hopN { db.append(10 * log10(acc / Double(n) + 1e-12)); acc = 0; n = 0 }
            }
        }
        return SpeechActivity(frameDB: db)
    }

    func isSpeech(_ i: Int) -> Bool { i >= 0 && i < speech.count && speech[i] }
    func frame(_ t: Double) -> Int { Int((t / Self.hop).rounded()) }

    /// Snaps word starts in silence forward to the next onset and word ends in silence back to the last offset, within
    /// the word's own span (keeping ≥ 40 ms of word): whisper often starts a segment's first word seconds early, at the
    /// segment start in the preceding silence. Times are in the WAV's timeline (seconds from its first sample).
    public func refine(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard !speech.isEmpty, speech.contains(false) else { return words }
        let minWord = 0.04
        var out = words
        for k in out.indices {
            var w = out[k]
            // start
            var i = frame(w.start)
            if i < speech.count, !isSpeech(i) {
                let lim = min(speech.count, frame(w.end - minWord))
                while i < lim, !isSpeech(i) { i += 1 }
                if i < lim {
                    w.start = Double(i) * Self.hop
                } else {
                    // the whole word lies in silence (whisper placed it before the voice): it belongs to the next
                    // onset, searched up to the next word's end
                    let far = min(speech.count, frame(k + 1 < out.count ? out[k + 1].end : w.end + 2))
                    var m = i
                    while m < far, !isSpeech(m) { m += 1 }
                    if m < far {
                        let d = min(w.end - w.start, 0.3)
                        w.start = Double(m) * Self.hop
                        w.end = w.start + d
                    }
                }
            }
            // end (the frame just before the end time)
            var j = frame(w.end) - 1
            if j >= 0, j < speech.count, !isSpeech(j) {
                let lim = frame(w.start + minWord)
                while j > lim, !isSpeech(j) { j -= 1 }
                if j > lim { w.end = Double(j + 1) * Self.hop }
            }
            if k > 0 { w.start = max(w.start, out[k - 1].start) }
            w.end = max(w.end, w.start + 0.02)
            out[k] = w
        }
        return out
    }
}
