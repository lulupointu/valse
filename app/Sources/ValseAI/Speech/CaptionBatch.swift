@preconcurrency import AVFoundation
import Foundation
import ValseCore
import ValseEngine

/// Batch transcription of the media ranges of one caption request (PERF-CAPTIONS-1).
///
/// Every engine run pays the model load and at least one full 30 s whisper window, so captioning 26 short ranges one by
/// one cost ~2.3 s each (owner's "Episode 6": 47 s of whisper for 109 s of audio). The ranges' 16 kHz WAVs are joined
/// into one file with `gap` seconds of digital silence between them and recognised in ONE engine run (measured on
/// Episode 6: 13.5 s instead of 47 s, no word placed in a gap, and more accurate thanks to the context across pieces).
/// The words are then split back into their pieces by time and snapped to speech onsets on each piece's own audio
/// (`SpeechActivity`, as for a single range: its thresholds follow that recording's own levels).
enum CaptionBatch {
    /// Raw speech engine on one WAV (`Transcriber.recognize`; tests inject a fake).
    typealias Recognizer = @Sendable (URL, Transcriber.Request, (@Sendable (Double) -> Void)?) async throws -> Transcript

    static let defaultRecognizer: Recognizer = { wav, request, progress in
        try await Transcriber.recognize(wav: wav, request: request, progress: progress)
    }

    /// Digital silence between two pieces (1 s: whisper put no word in it on Episode 6, and the next piece starts a new
    /// segment).
    static let gap = 1.0
    /// Longest joined WAV per engine run; longer requests take several runs (a failure or a hallucination loop then
    /// stays within one run; 5 min measured fine).
    static let maxJoinedSeconds = 600.0

    /// Pieces (by index) per engine run, in order: each group's joined length (pieces + gaps) ≤ `maxSeconds`; a piece
    /// longer than that is a group of its own.
    static func groups(_ durations: [Double], gap: Double = gap, maxSeconds: Double = maxJoinedSeconds) -> [[Int]] {
        var out: [[Int]] = []
        var length = 0.0
        for (i, d) in durations.enumerated() {
            if var last = out.last, length + gap + d <= maxSeconds {
                last.append(i); out[out.count - 1] = last; length += gap + d
            } else {
                out.append([i]); length = d
            }
        }
        return out
    }

    /// Start of each piece in the joined WAV.
    static func offsets(_ durations: [Double], gap: Double = gap) -> [Double] {
        var t = 0.0
        return durations.map { d in defer { t += d + gap }; return t }
    }

    /// The piece a word (joined-WAV time) belongs to: the one it starts in. A word starting in a gap (DTW starts words a
    /// little early) goes to the next piece when it reaches into it, else to the nearer piece. Never nil: nothing is
    /// dropped.
    static func pieceIndex(start: Double, end: Double, offsets: [Double], durations: [Double]) -> Int {
        var i = 0
        for k in offsets.indices where offsets[k] <= start { i = k }
        let pieceEnd = offsets[i] + durations[i]
        guard start > pieceEnd, i + 1 < offsets.count else { return i }
        if end > offsets[i + 1] { return i + 1 }
        return start - pieceEnd <= offsets[i + 1] - end ? i : i + 1
    }

    /// Words recognised on the joined WAV → each piece's words in piece time (seconds from the piece's first sample),
    /// clamped into the piece (a word straddling a gap stays in the piece it belongs to, ending at that piece's end).
    static func split(_ words: [TranscriptWord], offsets: [Double], durations: [Double]) -> [[TranscriptWord]] {
        var out = [[TranscriptWord]](repeating: [], count: offsets.count)
        guard !offsets.isEmpty else { return out }
        for w in words {
            let i = pieceIndex(start: w.start, end: w.end, offsets: offsets, durations: durations)
            let d = durations[i], minWord = 0.02
            let s = min(max(0, w.start - offsets[i]), max(0, d - minWord))
            let e = min(max(w.end - offsets[i], s + minWord), max(d, s + minWord))
            out[i].append(TranscriptWord(text: w.text, start: s, end: e, confidence: w.confidence))
        }
        return out
    }

    /// Length of a WAV in seconds (0 if unreadable).
    static func duration(_ wav: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: wav) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Writes `wavs` (same format: `AudioExtractor.wav16k` output) end to end with `gap` seconds of digital silence in
    /// between to a temporary WAV (caller deletes it). Returns each piece's start in it (exact, from frame counts).
    static func join(_ wavs: [URL], gap: Double = gap) throws -> (url: URL, offsets: [Double]) {
        let first = try AVAudioFile(forReading: wavs[0])
        let fmt = first.processingFormat
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("valse-stt-joined-\(UUID().uuidString).wav")
        var offsets: [Double] = []
        do {
            let w = try AVAudioFile(forWriting: out, settings: first.fileFormat.settings, commonFormat: fmt.commonFormat,
                                    interleaved: fmt.isInterleaved)
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw SpeechFailure.other(detail: "join: buffer") }
            let gapFrames = AVAudioFrameCount((gap * fmt.sampleRate).rounded())
            var written: AVAudioFramePosition = 0
            for (k, url) in wavs.enumerated() {
                try Task.checkCancellation()
                let f = k == 0 ? first : try AVAudioFile(forReading: url)
                guard f.processingFormat.sampleRate == fmt.sampleRate, f.processingFormat.channelCount == fmt.channelCount else {
                    throw SpeechFailure.other(detail: "join: piece \(k) has another format")
                }
                offsets.append(Double(written) / fmt.sampleRate)
                while f.framePosition < f.length {
                    try f.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(f.length - f.framePosition)))
                    if buf.frameLength == 0 { break }
                    try w.write(from: buf)
                    written += AVAudioFramePosition(buf.frameLength)
                }
                if k < wavs.count - 1, gapFrames > 0 {
                    var left = gapFrames
                    while left > 0 {
                        let n = min(left, chunk)
                        buf.frameLength = n
                        for c in 0..<Int(fmt.channelCount) {
                            if let p = buf.floatChannelData?[c] { p.update(repeating: 0, count: Int(n)) }
                            else if let p = buf.int16ChannelData?[c] { p.update(repeating: 0, count: Int(n)) }
                        }
                        try w.write(from: buf)
                        left -= n; written += AVAudioFramePosition(n)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out); throw error
        }
        return (out, offsets)
    }

    /// Recognises `wavs` (16 kHz pieces) in as few engine runs as `groups` allows. Returns one transcript per piece, in
    /// piece time, boundary-snapped on the piece's own audio. `progress` 0…1 over all runs.
    static func transcribe(_ wavs: [URL], request: Transcriber.Request, recognizer: Recognizer = defaultRecognizer,
                           timings tm: inout CaptionTimings, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Transcript] {
        let durations = wavs.map(duration)
        let total = max(durations.reduce(0, +), 0.001)
        var out = [Transcript?](repeating: nil, count: wavs.count)
        var done = 0.0
        for g in groups(durations) {
            try Task.checkCancellation()
            let j0 = CaptionTimings.now()
            let input: URL, offs: [Double]
            if g.count == 1 { input = wavs[g[0]]; offs = [0] }
            else { (input, offs) = try join(g.map { wavs[$0] }) }
            defer { if g.count > 1 { try? FileManager.default.removeItem(at: input) } }
            let e0 = CaptionTimings.now()
            tm.joining += e0 - j0
            let length = g.reduce(0.0) { $0 + durations[$1] }
            let base = done
            let t = try await recognizer(input, request) { f in progress?((base + f * length) / total) }
            let s0 = CaptionTimings.now()
            tm.engine += s0 - e0; tm.engineRuns += 1
            let parts = split(t.words, offsets: offs, durations: g.map { durations[$0] })
            for (k, idx) in g.enumerated() {
                var words = parts[k]
                if !words.isEmpty, let vad = SpeechActivity.analyze(wav: wavs[idx]) { words = vad.refine(words) }
                out[idx] = Transcript(engine: t.engine, language: t.language, words: words)
            }
            tm.snapping += CaptionTimings.now() - s0
            done += length
            progress?(done / total)
        }
        return out.map { $0 ?? Transcript(engine: "", language: request.language ?? "", words: []) }
    }
}
