import Foundation
import ValseCore
import ValseEngine

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
        /// Silero VAD model for whisper.cpp's voice activity detection (`--vad -vm`, see `VADTimeMap`); nil = no VAD.
        public var vadModel: URL? = WhisperEngine.defaultVADModel
        /// PERF-CAPTIONS-2 background pre-transcription: launch through `taskpolicy -b` (darwin background policy:
        /// lowest CPU priority, efficiency cores, throttled I/O).
        public var background = false
        /// Gets the whisper process id at launch (background pre-transcription pauses it in place).
        public var onLaunch: (@Sendable (Int32) -> Void)?
        public init(language: String?, model: URL, cli: URL, keepFillers: Bool = false,
                    threads: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))) {
            self.language = language; self.model = model; self.cli = cli; self.keepFillers = keepFillers; self.threads = threads
        }
    }

    public static func transcribe(wav: URL, options o: Options, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        let outBase = FileManager.default.temporaryDirectory.appendingPathComponent("valse-whisper-\(UUID().uuidString)")
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
        let (exe, pre) = launcher(o)
        // PERF-CAPTIONS-4: with the VAD model installed, whisper decodes only the voiced parts (one attempt, with DTW
        // when available); any failure falls back to the run without VAD below.
        // PERF-CAPTIONS-5: only where VAD was proven (`VADGuard`): audio with quiet parts, and a run that dropped no
        // audio sounding like the speech it kept (else whole lines go missing under a music bed).
        let energy = o.vadModel == nil ? nil : VADGuard.frameDB(wav: wav)
        if let vad = o.vadModel, let energy, VADGuard.hasQuietParts(energy) {
            var vargs = args + ["--vad", "-vm", vad.path]
            if o.dtw, let preset = dtwPreset(model: o.model) { vargs += ["-nfa", "-dtw", preset] }
            let spans = VADTimeMap.Collector()
            do {
                try await run(exe, pre + vargs, progress: progress, onLine: spans.add, onLaunch: o.onLaunch)
                let t = try parse(Data(contentsOf: jsonURL), fallbackLanguage: o.language ?? "en", vad: spans.map)
                // Silero hears no voice under a loud music bed (speech 15 dB under a band: whole clip dropped → "No
                // speech", F4AITests lyricsCaptionsOnSeparatedVocalsBeatTheMix) — silent pieces never get here
                // (`AudioExtractor.isSilent`), so an empty VAD result is retried without VAD.
                guard !t.words.isEmpty else { throw SpeechFailure.other(detail: "whisper VAD: no words kept") }
                let map = spans.map
                guard !VADGuard.droppedSpeech(energy, map: map) else {
                    let d = VADGuard.nearSpeechDropped(energy, map: map)
                    throw SpeechFailure.other(detail: String(format: "whisper VAD dropped %.1f s near the speech level (kept %.1f s)", d.dropped, d.kept))
                }
                return t
            } catch is CancellationError { throw CancellationError() }
            catch let f as SpeechFailure where [.appIncomplete, .diskFull].contains(f) { throw f }
            catch { EngineLog.error("whisper VAD run failed (\(error)), retrying without VAD") }
        }
        if o.dtw, let preset = dtwPreset(model: o.model) {
            do {
                try await run(exe, pre + args + ["-nfa", "-dtw", preset], progress: progress, onLaunch: o.onLaunch)
                return try parse(Data(contentsOf: jsonURL), fallbackLanguage: o.language ?? "en")
            } catch is CancellationError { throw CancellationError() }
            catch let f as SpeechFailure where [.appIncomplete, .speechModelDamaged, .diskFull].contains(f) { throw f }   // no retry helps
            catch { EngineLog.error("whisper DTW run failed (\(error)), retrying without DTW") }
        }
        try await run(exe, pre + args, progress: progress, onLaunch: o.onLaunch)
        return try parse(Data(contentsOf: jsonURL), fallbackLanguage: o.language ?? "en")
    }

    /// Executable + leading arguments: `taskpolicy -b <cli>` for background runs (the CLI itself when taskpolicy is
    /// missing). taskpolicy execs the CLI in place, so terminating the process still stops whisper.
    static func launcher(_ o: Options) -> (URL, [String]) {
        let tp = "/usr/sbin/taskpolicy"
        guard o.background, FileManager.default.isExecutableFile(atPath: tp) else { return (o.cli, []) }
        return (URL(fileURLWithPath: tp), ["-b", o.cli.path])
    }

    static func run(_ cli: URL, _ args: [String], progress: (@Sendable (Double) -> Void)?,
                    onLine: (@Sendable (String) -> Void)? = nil, onLaunch: (@Sendable (Int32) -> Void)? = nil) async throws {
        // stderr (progress lines, error text) is read to EOF by ProcessPipes before the exit status is used
        // (FLAKY-PIPE: with a readabilityHandler the last chunks could arrive after `tail` was taken)
        let progressBox = LineBuffer()
        let stderr = ProcessPipes.Capture(keep: false) { d in
            for line in progressBox.append(d) {
                onLine?(line)
                if let r = line.range(of: "progress =") {
                    let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                    if let pct = Double(v) { progress?(pct / 100) }
                }
            }
        }
        let end: (status: Int32, signal: Bool)
        do {
            let r = try await ProcessPipes.run(cli, args, stderr: stderr, onLaunch: onLaunch)
            end = (r.status, r.uncaughtSignal)
        } catch {
            EngineLog.error("whisper-cli failed to launch: \(error)")
            throw classifyLaunch(error)
        }
        try Task.checkCancellation()
        guard end.status == 0 else {
            let tail = progressBox.tail
            EngineLog.error("whisper-cli \(end.signal ? "signal" : "exit") \(end.status): \(tail)")
            throw classifyExit(status: end.status, signal: end.signal, stderr: tail)
        }
    }

    /// `Process.run` failed: the helper is missing, not executable, quarantined or built for another CPU (EBADARCH on
    /// an Intel Mac): only an update of Valse fixes it.
    static func classifyLaunch(_ error: any Error) -> SpeechFailure {
        let ns = error as NSError
        if SpeechFailure.isDiskFull(ns) { return .diskFull }
        return .appIncomplete
    }

    /// whisper-cli ended badly: killed (SIGKILL = memory pressure / jetsam), illegal instruction (CPU without the
    /// instructions it was built for), model that doesn't load, or something else.
    static func classifyExit(status: Int32, signal: Bool, stderr: String) -> SpeechFailure {
        if signal {
            if status == SIGKILL { return .notEnoughMemory }
            if status == SIGILL { return .appIncomplete }
            return .other(detail: "whisper signal \(status)")
        }
        let s = stderr.lowercased()
        if s.contains("failed to load model") || s.contains("failed to initialize whisper context") || s.contains("invalid model") {
            return .speechModelDamaged
        }
        if s.contains("bad cpu type") { return .appIncomplete }
        if s.contains("no space left") { return .diskFull }
        if s.contains("failed to allocate") || s.contains("out of memory") { return .notEnoughMemory }
        return .other(detail: "whisper exit \(status): \(stderr)")
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
    /// `vad`: the run used whisper's VAD (nil = it didn't). Token times are then in the VAD's condensed audio (only the
    /// segment offsets are mapped back by whisper.cpp): words are built in that time base and mapped with `vad`.
    public static func parse(_ data: Data, fallbackLanguage: String, vad: VADTimeMap?) throws -> Transcript {
        let t = try parse(data, fallbackLanguage: fallbackLanguage, segmentStart: vad.map { m in { m.condensed($0) } } ?? { $0 })
        guard let vad else { return t }
        if vad.spans.isEmpty {
            // no speech found (empty output), or a whisper build that doesn't log its time map: can't place the words
            guard t.words.isEmpty else { throw SpeechFailure.other(detail: "whisper VAD: no time map") }
            return t
        }
        return Transcript(engine: t.engine, language: t.language, words: vad.original(t.words))
    }

    public static func parse(_ data: Data, fallbackLanguage: String) throws -> Transcript {
        try parse(data, fallbackLanguage: fallbackLanguage, segmentStart: { $0 })
    }

    static func parse(_ data: Data, fallbackLanguage: String, segmentStart: (Double) -> Double) throws -> Transcript {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpeechFailure.other(detail: "whisper: bad json") }
        let lang = (obj["result"] as? [String: Any])?["language"] as? String ?? fallbackLanguage
        let segments = obj["transcription"] as? [[String: Any]] ?? []
        func isSpecial(_ t: String) -> Bool { t.hasPrefix("[_") || t.hasPrefix("<|") }
        func dtw(_ tok: [String: Any]) -> Double? {
            guard let v = tok["t_dtw"] as? Double, v >= 0 else { return nil }
            return v / 100
        }
        let hasDTW = segments.contains { ($0["tokens"] as? [[String: Any]] ?? []).contains { t in
            !isSpecial(t["text"] as? String ?? "[_") && dtw(t) != nil } }
        if hasDTW { return Transcript(engine: "whisper.cpp", language: lang, words: dtwWords(segments, segmentStart: segmentStart)) }
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
    static func dtwWords(_ segments: [[String: Any]], segmentStart: (Double) -> Double = { $0 }) -> [TranscriptWord] {
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
            let segStart = segmentStart(((seg["offsets"] as? [String: Any])?["from"] as? Double ?? 0) / 1000)
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
    /// The last 6 lines, including an unterminated last line (an error message written without a final newline).
    var tail: String { lock.withLock { (pending.isEmpty ? last : Array((last + [pending]).suffix(6))).joined(separator: " | ") } }
}
