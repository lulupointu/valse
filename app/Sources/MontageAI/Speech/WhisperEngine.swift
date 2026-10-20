import Foundation
import MontageCore
import MontageEngine

/// whisper.cpp transcription through the `whisper-cli` sidecar (Metal, beam 5).
/// Word timestamps come from DTW token-level timestamps (`-dtw <preset>`, cross-attention alignment; needs flash
/// attention off): a token's `t_dtw` marks where its sound ends, so a word starts just after the previous token
/// (`dtwStartBias` of the way towards its own first token) and ends at its last token. Without DTW data (old
/// whisper-cli builds) the interpolated token offsets are used. Tokens merge into words (a token starting with a space
/// starts a new word, punctuation attaches to the previous word). Progress is parsed from `-pp`; cancelling the Swift
/// task terminates the process. Measured on bench/speech_fr.wav (ground truth from the synthesizer's word callbacks):
/// mean |onset error| 230 ms with offsets → ~40 ms with DTW (+ `SpeechActivity` snapping).
public enum WhisperEngine {
    public struct Options: Sendable {
        /// nil = auto-detect.
        public var language: String?
        public var model: URL
        public var cli: URL
        /// Keep disfluencies ("euh", "um") in the output: an initial prompt containing fillers makes Whisper keep them.
        public var keepFillers: Bool
        public var threads: Int
        /// DTW token timestamps (accurate word times; off = whisper's interpolated timestamps, the pre-2026-10 behaviour).
        public var dtw = true
        public init(language: String?, model: URL, cli: URL, keepFillers: Bool = false,
                    threads: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))) {
            self.language = language; self.model = model; self.cli = cli; self.keepFillers = keepFillers; self.threads = threads
        }
    }

    public static func transcribe(wav: URL, options o: Options, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        let outBase = FileManager.default.temporaryDirectory.appendingPathComponent("montage-whisper-\(UUID().uuidString)")
        let jsonURL = outBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        var args = ["-m", o.model.path, "-f", wav.path, "-l", o.language ?? "auto", "-ojf", "-of", outBase.path,
                    "-pp", "-t", String(o.threads), "-bs", "5"]
        if o.keepFillers {
            args += ["--prompt", o.language == "en" ? "Um, so, uh, I mean, like, you know." : "Euh, alors, bah, en fait, du coup, hein."]
        } else {
            // Style prompt: with timestamps on, large-v3-turbo often drops capitals and punctuation (seen on clear
            // English speech: "hello and welcome to this video editing tutorial today we…"). A short punctuated prompt
            // keeps sentence case + punctuation; bilingual when auto-detecting (detection itself ignores the prompt).
            let prompt: String
            switch o.language {
            case "en": prompt = "Hello, welcome. This is a sentence."
            case "fr": prompt = "Bonjour, bienvenue. Voici une phrase."
            case nil: prompt = "Hello, welcome. Bonjour, bienvenue."
            default: prompt = ""
            }
            if !prompt.isEmpty { args += ["--prompt", prompt] }
        }
        if o.dtw, let preset = dtwPreset(model: o.model) {
            do {
                try await run(o.cli, args + ["-nfa", "-dtw", preset], progress: progress)
                return try parse(Data(contentsOf: jsonURL), fallbackLanguage: o.language ?? "en")
            } catch is CancellationError { throw CancellationError() }
            catch { EngineLog.error("whisper DTW run failed (\(error)), retrying without DTW") }
        }
        try await run(o.cli, args, progress: progress)
        return try parse(Data(contentsOf: jsonURL), fallbackLanguage: o.language ?? "en")
    }

    static func run(_ cli: URL, _ args: [String], progress: (@Sendable (Double) -> Void)?) async throws {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let progressBox = LineBuffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            for line in progressBox.append(d) {
                if let r = line.range(of: "progress =") {
                    let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                    if let pct = Double(v) { progress?(pct / 100) }
                }
            }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
        err.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard status == 0 else { throw AIToolError.unavailable("whisper-cli exit \(status): \(progressBox.tail)") }
    }

    /// whisper.cpp DTW alignment-heads preset for a ggml model file (nil = unknown model → no DTW).
    public static func dtwPreset(model: URL) -> String? {
        let n = model.lastPathComponent.lowercased()
        let en = n.contains(".en") ? ".en" : ""
        if n.contains("large-v3-turbo") || n.contains("large-v3_turbo") { return "large.v3.turbo" }
        if n.contains("large-v3") { return "large.v3" }
        if n.contains("large-v2") { return "large.v2" }
        if n.contains("large") { return "large.v1" }
        for size in ["medium", "small", "base", "tiny"] where n.contains(size) { return size + en }
        return nil
    }

    /// Fraction of the way from the previous token's DTW time to the word's own first token where the word starts
    /// (DTW marks token ends; measured on synthetic French speech: 0 → −47 ms bias, 0.15 → ≈ 0).
    static let dtwStartBias = 0.15

    /// Longest plausible duration of one token, from its spelling: ≈ 90 ms per letter + 250 ms (≤ 1.2 s), digits ×3
    /// (spoken numbers are long), hesitations ("euh", "um") 1.5 s. A word can't start earlier than its first token's
    /// DTW time minus this: the start anchor is the previous token, and for a segment's first word that is the segment
    /// start — the 30 s window start or the previous segment's end, seconds before the voice after a silence (U2, owner
    /// clip IMG_7251: "Vous" anchored at 0 s, DTW 3.74 s → started at 0.56 s). DTW also bunches the first tokens of a
    /// segment after a long silence, which drags the next word's anchor back the same way.
    static func maxTokenDuration(_ token: String) -> Double {
        let t = token.trimmingCharacters(in: .whitespaces)
        if FillerWords.isHesitation(t) { return 1.5 }
        let letters = t.unicodeScalars.reduce(0) { n, u in
            CharacterSet.decimalDigits.contains(u) ? n + 3 : CharacterSet.letters.contains(u) ? n + 1 : n
        }
        return min(1.2, 0.25 + 0.09 * Double(letters))
    }

    /// Parses `-ojf` output into words.
    public static func parse(_ data: Data, fallbackLanguage: String) throws -> Transcript {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIToolError.unavailable("bad json") }
        let lang = (obj["result"] as? [String: Any])?["language"] as? String ?? fallbackLanguage
        let segments = obj["transcription"] as? [[String: Any]] ?? []
        func isSpecial(_ t: String) -> Bool { t.hasPrefix("[_") || t.hasPrefix("<|") }
        func dtw(_ tok: [String: Any]) -> Double? {
            guard let v = tok["t_dtw"] as? Double, v >= 0 else { return nil }
            return v / 100
        }
        let hasDTW = segments.contains { ($0["tokens"] as? [[String: Any]] ?? []).contains { t in
            !isSpecial(t["text"] as? String ?? "[_") && dtw(t) != nil } }
        if hasDTW { return Transcript(engine: "whisper.cpp", language: lang, words: dtwWords(segments)) }
        var words: [TranscriptWord] = []
        var cur: (text: String, start: Double, end: Double, p: [Double])?
        func flush() {
            if let c = cur {
                let t = c.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.allSatisfy({ $0.isPunctuation }) {
                    words.append(TranscriptWord(text: t, start: c.start, end: max(c.end, c.start + 0.02),
                                                confidence: c.p.isEmpty ? nil : c.p.reduce(0, +) / Double(c.p.count)))
                } else if !t.isEmpty, let last = words.indices.last {
                    words[last].text += t
                }
            }
            cur = nil
        }
        for seg in obj["transcription"] as? [[String: Any]] ?? [] {
            for tok in seg["tokens"] as? [[String: Any]] ?? [] {
                guard let text = tok["text"] as? String else { continue }
                if text.hasPrefix("[_") || text.hasPrefix("<|") { continue }     // [_BEG_], [_TT_123], special tokens
                let off = tok["offsets"] as? [String: Any]
                let s = (off?["from"] as? Double ?? 0) / 1000, e = (off?["to"] as? Double ?? 0) / 1000
                let p = tok["p"] as? Double
                let startsWord = text.hasPrefix(" ")
                let isPunct = text.trimmingCharacters(in: .whitespaces).allSatisfy { $0.isPunctuation || $0.isSymbol }
                if cur == nil || (startsWord && !isPunct) {
                    flush()
                    cur = (text, s, e, p.map { [$0] } ?? [])
                } else {
                    cur!.text += text
                    cur!.end = max(cur!.end, e)
                    if let p, !isPunct { cur!.p.append(p) }
                }
            }
            flush()
        }
        return Transcript(engine: "whisper.cpp", language: lang, words: words)
    }

    /// Words from DTW token times (see the type comment).
    static func dtwWords(_ segments: [[String: Any]]) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        var cur: (text: String, start: Double, end: Double, p: [Double])?
        func flush() {
            if let c = cur {
                let t = c.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.allSatisfy({ $0.isPunctuation || $0.isSymbol }) {
                    let s = max(c.start, words.last?.start ?? 0)
                    words.append(TranscriptWord(text: t, start: s, end: max(c.end, s + 0.02),
                                                confidence: c.p.isEmpty ? nil : c.p.reduce(0, +) / Double(c.p.count)))
                } else if !t.isEmpty, let last = words.indices.last {
                    words[last].text += t
                }
            }
            cur = nil
        }
        for seg in segments {
            let segStart = ((seg["offsets"] as? [String: Any])?["from"] as? Double ?? 0) / 1000
            var prev: Double? = nil
            for tok in seg["tokens"] as? [[String: Any]] ?? [] {
                guard let text = tok["text"] as? String, !(text.hasPrefix("[_") || text.hasPrefix("<|")) else { continue }
                let off = tok["offsets"] as? [String: Any]
                let d = (tok["t_dtw"] as? Double).flatMap { $0 >= 0 ? $0 / 100 : nil } ?? ((off?["to"] as? Double ?? 0) / 1000)
                let p = tok["p"] as? Double
                let isPunct = text.trimmingCharacters(in: .whitespaces).allSatisfy { $0.isPunctuation || $0.isSymbol }
                if cur == nil || (text.hasPrefix(" ") && !isPunct) {
                    flush()
                    let from = prev ?? segStart
                    let start = max(from + dtwStartBias * max(0, d - from), d - maxTokenDuration(text))
                    cur = (text, start, d, p.map { [$0] } ?? [])
                } else {
                    cur!.text += text
                    if !isPunct { cur!.end = max(cur!.end, d); if let p { cur!.p.append(p) } }
                }
                prev = d
            }
            flush()
        }
        return words
    }
}

/// Splits a byte stream into lines (whisper prints progress on stderr, sometimes with \r).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var last: [String] = []
    func append(_ d: Data) -> [String] {
        lock.withLock {
            pending += String(decoding: d, as: UTF8.self)
            var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
            pending = lines.removeLast()
            last = Array((last + lines).suffix(6))
            return lines
        }
    }
    var tail: String { lock.withLock { last.joined(separator: " | ") } }
}
