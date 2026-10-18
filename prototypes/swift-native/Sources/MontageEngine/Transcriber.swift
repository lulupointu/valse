import AVFoundation
import Speech

public struct WordStamp: Sendable { public let text: String; public let start: Double; public let end: Double }

public struct Transcript: Sendable {
    public let engine: String
    public let text: String
    public let words: [WordStamp]
    public let elapsed: Double
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unavailable(String)
    public var description: String { if case .unavailable(let s) = self { return s }; return "" }
}

/// On-device French STT with word timestamps.
/// Order of preference: SpeechAnalyzer/SpeechTranscriber (macOS 26, best model, needs an OS-managed
/// language asset) → SpeechAnalyzer/DictationTranscriber (macOS 26, uses the installed dictation model)
/// → SFSpeechRecognizer on-device (needs TCC authorization) → whisper.cpp.
public enum Transcriber {
    public static func audioDuration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    public static func best(url: URL, locale: Locale = Locale(identifier: "fr-FR"),
                            whisperCLI: String?, whisperModel: String?, log: (String) -> Void) async -> Transcript? {
        if #available(macOS 26.0, *) {
            do { return try await speechAnalyzer(url: url, locale: locale) }
            catch { log("SpeechAnalyzer unavailable: \(error)") }
        }
        do { return try await sfSpeech(url: url, locale: locale) }
        catch { log("SFSpeechRecognizer unavailable: \(error)") }
        if let whisperCLI, let whisperModel {
            do { return try whisper(url: url, cli: whisperCLI, model: whisperModel, language: "fr") }
            catch { log("whisper.cpp failed: \(error)") }
        }
        return nil
    }

    @available(macOS 26.0, *)
    public static func speechAnalyzer(url: URL, locale: Locale) async throws -> Transcript {
        let bcp = locale.identifier(.bcp47)
        let file = try AVAudioFile(forReading: url)
        let t0 = CACurrentMediaTime()
        let module: any SpeechModule
        let engine: String
        let results: AsyncThrowingStream<(AttributedString, Bool), Error>
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t; engine = "SpeechAnalyzer.SpeechTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield((r.text, r.isFinal)) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else if await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = t; engine = "SpeechAnalyzer.DictationTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield((r.text, r.isFinal)) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else {
            // A production app would call AssetInventory.assetInstallationRequest(supporting:) here
            // (one-time OS-managed download, the only non-local step).
            throw TranscriberError.unavailable("no installed SpeechAnalyzer model for \(bcp)")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> ([String], [WordStamp]) in
            var texts: [String] = []; var words: [WordStamp] = []
            for try await (text, _) in results {
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
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let (texts, words) = try await collector.value
        return Transcript(engine: engine, text: texts.joined(separator: " "), words: words, elapsed: CACurrentMediaTime() - t0)
    }

    public static func sfSpeech(url: URL, locale: Locale) async throws -> Transcript {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            // Never block a headless run on a TCC prompt: wait at most 3 s.
            status = await withTaskGroup(of: SFSpeechRecognizerAuthorizationStatus.self) { g in
                g.addTask { await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } } }
                g.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return .notDetermined }
                let first = await g.next()!; g.cancelAll(); return first
            }
        }
        guard status == .authorized else { throw TranscriberError.unavailable("speech recognition not authorized (status \(status.rawValue))") }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.supportsOnDeviceRecognition else {
            throw TranscriberError.unavailable("no on-device recognizer for \(locale.identifier)")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let t0 = CACurrentMediaTime()
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            var resumed = false
            rec.recognitionTask(with: req) { r, e in
                if resumed { return }
                if let e { resumed = true; c.resume(throwing: e) }
                else if let r, r.isFinal { resumed = true; c.resume(returning: r) }
            }
        }
        let words = result.bestTranscription.segments.map { WordStamp(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
        return Transcript(engine: "SFSpeechRecognizer(onDevice)", text: result.bestTranscription.formattedString, words: words, elapsed: CACurrentMediaTime() - t0)
    }

    /// whisper.cpp via its CLI (Metal-accelerated). A production build would link libwhisper
    /// (whisper.cpp ships an xcframework / SwiftPM package) and keep the model resident.
    public static func whisper(url: URL, cli: String, model: String, language: String) throws -> Transcript {
        let outBase = FileManager.default.temporaryDirectory.appendingPathComponent("montage-whisper-\(getpid())")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-m", model, "-l", language, "-f", url.path, "-ml", "1", "-sow", "-oj", "-of", outBase.path, "-np"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t0 = CACurrentMediaTime()
        try p.run(); p.waitUntilExit()
        let elapsed = CACurrentMediaTime() - t0
        guard p.terminationStatus == 0 else { throw TranscriberError.unavailable("whisper-cli exit \(p.terminationStatus)") }
        let jsonURL = outBase.appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        try? FileManager.default.removeItem(at: jsonURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segs = obj?["transcription"] as? [[String: Any]] ?? []
        var words: [WordStamp] = []
        for s in segs {
            let text = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let off = s["offsets"] as? [String: Any]
            let from = (off?["from"] as? Double ?? 0) / 1000, to = (off?["to"] as? Double ?? 0) / 1000
            if !text.isEmpty { words.append(WordStamp(text: text, start: from, end: to)) }
        }
        return Transcript(engine: "whisper.cpp(\(URL(fileURLWithPath: model).lastPathComponent))",
                          text: words.map(\.text).joined(separator: " "), words: words, elapsed: elapsed)
    }
}
