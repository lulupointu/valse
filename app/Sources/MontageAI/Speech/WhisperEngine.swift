import Foundation
import MontageCore
import MontageEngine

/// whisper.cpp transcription through the `whisper-cli` sidecar (Metal, flash attention, beam 5).
/// Word timestamps come from the full-JSON token offsets (tokens are merged into words: a token starting with a space
/// starts a new word, punctuation tokens attach to the previous word). Progress is parsed from `-pp`; cancelling the
/// Swift task terminates the process.
public enum WhisperEngine {
    public struct Options: Sendable {
        /// nil = auto-detect.
        public var language: String?
        public var model: URL
        public var cli: URL
        /// Keep disfluencies ("euh", "um") in the output: an initial prompt containing fillers makes Whisper keep them.
        public var keepFillers: Bool
        public var threads: Int
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
        }
        let p = Process()
        p.executableURL = o.cli
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
        let data = try Data(contentsOf: jsonURL)
        return try parse(data, fallbackLanguage: o.language ?? "en")
    }

    /// Parses `-ojf` output into words.
    public static func parse(_ data: Data, fallbackLanguage: String) throws -> Transcript {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIToolError.unavailable("bad json") }
        let lang = (obj["result"] as? [String: Any])?["language"] as? String ?? fallbackLanguage
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
