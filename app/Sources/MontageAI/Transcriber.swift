@preconcurrency import AVFoundation
import Speech
import Foundation
import MontageCore
import MontageEngine

public struct WordStamp: Sendable, Equatable { public let text: String; public let start: Double; public let end: Double }

public struct Transcript: Sendable {
    public let engine: String
    public let text: String
    public let words: [WordStamp]
}

/// On-device speech-to-text with word timestamps (ported from the prototype). Preference order:
/// SpeechAnalyzer/SpeechTranscriber (macOS 26) → SpeechAnalyzer/DictationTranscriber (macOS 26) → SFSpeechRecognizer
/// on-device → whisper.cpp CLI if an AI pack is installed (best French accuracy, ≈3 % WER).
public enum Transcriber {
    /// whisper.cpp pack location: ~/Library/Application Support/Montage/AIPacks/whisper/{whisper-cli, model.bin}.
    public static var whisperPack: (cli: String, model: String)? {
        let dir = MontagePaths.supportDirectory.appendingPathComponent("AIPacks/whisper")
        let cli = dir.appendingPathComponent("whisper-cli").path, model = dir.appendingPathComponent("model.bin").path
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: cli) && fm.fileExists(atPath: model) ? (cli, model) : nil
    }

    public static func transcribe(url: URL, locale: Locale) async throws -> Transcript {
        var errors: [String] = []
        if let pack = whisperPack {
            do { return try whisper(url: url, cli: pack.cli, model: pack.model, language: String(locale.identifier.prefix(2))) }
            catch { errors.append("whisper: \(error)") }
        }
        if #available(macOS 26.0, *) {
            do { return try await speechAnalyzer(url: url, locale: locale) } catch { errors.append("SpeechAnalyzer: \(error)") }
        }
        do { return try await sfSpeech(url: url, locale: locale) } catch { errors.append("SFSpeech: \(error)") }
        throw AIToolError.unavailable(errors.joined(separator: "; "))
    }

    @available(macOS 26.0, *)
    static func speechAnalyzer(url: URL, locale: Locale) async throws -> Transcript {
        let bcp = locale.identifier(.bcp47)
        let file = try AVAudioFile(forReading: url)
        let module: any SpeechModule
        let engine: String
        let results: AsyncThrowingStream<AttributedString, any Error>
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t; engine = "SpeechTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield(r.text) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else if await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t; engine = "DictationTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield(r.text) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else {
            throw AIToolError.unavailable("no installed SpeechAnalyzer model for \(bcp)")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> ([String], [WordStamp]) in
            var texts: [String] = [], words: [WordStamp] = []
            for try await text in results {
                texts.append(String(text.characters))
                for run in text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let w = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if w.isEmpty || w.allSatisfy({ $0.isPunctuation }) { continue }
                    words.append(WordStamp(text: w, start: tr.start.seconds, end: tr.end.seconds))
                }
            }
            return (texts, words)
        }
        if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
        else { await analyzer.cancelAndFinishNow() }
        let (texts, words) = try await collector.value
        return Transcript(engine: engine, text: texts.joined(separator: " "), words: words)
    }

    static func sfSpeech(url: URL, locale: Locale) async throws -> Transcript {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withTaskGroup(of: SFSpeechRecognizerAuthorizationStatus.self) { g in
                g.addTask { await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } } }
                g.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return .notDetermined }
                let first = await g.next()!; g.cancelAll(); return first
            }
        }
        guard status == .authorized else { throw AIToolError.unavailable("speech recognition not authorized") }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.supportsOnDeviceRecognition else {
            throw AIToolError.unavailable("no on-device recognizer for \(locale.identifier)")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let boxed: UncheckedSendable<SFSpeechRecognitionResult> = try await withCheckedThrowingContinuation { c in
            let once = OnceFlag()
            rec.recognitionTask(with: req) { r, e in
                if let e { if once.take() { c.resume(throwing: e) } }
                else if let r, r.isFinal { if once.take() { c.resume(returning: UncheckedSendable(r)) } }
            }
        }
        let result = boxed.value
        let words = result.bestTranscription.segments.map { WordStamp(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
        return Transcript(engine: "SFSpeechRecognizer", text: result.bestTranscription.formattedString, words: words)
    }

    static func whisper(url: URL, cli: String, model: String, language: String) throws -> Transcript {
        let outBase = FileManager.default.temporaryDirectory.appendingPathComponent("montage-whisper-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-m", model, "-l", language, "-f", url.path, "-ml", "1", "-sow", "-oj", "-of", outBase.path, "-np"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AIToolError.unavailable("whisper exit \(p.terminationStatus)") }
        let jsonURL = outBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        var words: [WordStamp] = []
        for s in obj?["transcription"] as? [[String: Any]] ?? [] {
            let text = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let off = s["offsets"] as? [String: Any]
            if !text.isEmpty { words.append(WordStamp(text: text, start: (off?["from"] as? Double ?? 0) / 1000, end: (off?["to"] as? Double ?? 0) / 1000)) }
        }
        return Transcript(engine: "whisper.cpp", text: words.map(\.text).joined(separator: " "), words: words)
    }

    /// Groups words into caption lines (≤ `maxChars`, break on pauses > 0.6 s or sentence ends).
    public static func captionLines(_ words: [WordStamp], maxChars: Int = 32) -> [(text: String, start: Double, end: Double)] {
        var out: [(String, Double, Double)] = []
        var cur: [WordStamp] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append((cur.map(\.text).joined(separator: " "), f.start, max(l.end, f.start + 0.3)))
            cur.removeAll()
        }
        for w in words {
            if let l = cur.last {
                let len = cur.map(\.text.count).reduce(0, +) + cur.count + w.text.count
                if w.start - l.end > 0.6 || len > maxChars || l.text.last.map({ ".?!".contains($0) }) == true { flush() }
            }
            cur.append(w)
        }
        flush()
        return out
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
