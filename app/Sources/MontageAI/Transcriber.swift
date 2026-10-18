@preconcurrency import AVFoundation
import Speech
import NaturalLanguage
import Foundation
import MontageCore
import MontageEngine

/// Speech engine choice (Auto captions ▸ engine, Settings ▸ AI).
public enum SpeechEngine: String, Sendable, CaseIterable, Codable {
    /// whisper.cpp when its model is installed, else Apple Speech.
    case automatic
    /// whisper.cpp large-v3-turbo (best accuracy, needs the model download).
    case whisper
    /// Apple on-device speech (SpeechAnalyzer on macOS 26, SFSpeechRecognizer before): fast, no download.
    case apple
    public var nameKey: String { "speech.engine.\(rawValue)" }
}

/// On-device speech-to-text with word timestamps. Preference order for `.automatic`: whisper.cpp (if the model and
/// runtime are installed) → SpeechAnalyzer/SpeechTranscriber (macOS 26) → DictationTranscriber → SFSpeechRecognizer
/// on-device. `language == nil` = auto-detect (whisper detects natively; Apple engines try the candidate languages
/// on an excerpt and keep the most confident).
public enum Transcriber {
    public struct Request: Sendable {
        public var language: String?
        public var engine: SpeechEngine
        public var keepFillers: Bool
        /// Languages tried by Apple-engine auto-detection.
        public var candidates: [String]
        public init(language: String? = nil, engine: SpeechEngine = .automatic, keepFillers: Bool = false, candidates: [String] = ["fr", "en"]) {
            self.language = language; self.engine = engine; self.keepFillers = keepFillers; self.candidates = candidates
        }
    }

    /// Transcribes a 16 kHz mono WAV (see `AudioExtractor`). `progress` 0…1.
    public static func transcribe(wav: URL, request r: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        var errors: [String] = []
        if r.engine != .apple, let cli = WhisperRuntime.cliURL, let model = ModelCatalog.installedWhisperModel {
            do {
                return try await WhisperEngine.transcribe(wav: wav, options: .init(language: r.language, model: model, cli: cli,
                                                                                    keepFillers: r.keepFillers), progress: progress)
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append("whisper: \(error)") }
        } else if r.engine == .whisper {
            throw AIToolError.unavailable("whisper model not installed")
        }
        let lang: String
        if let l = r.language { lang = l } else { lang = try await detectLanguageApple(wav: wav, candidates: r.candidates) }
        let locale = Locale(identifier: appleLocale(lang))
        progress?(0.1)
        if #available(macOS 26.0, *) {
            do { let t = try await speechAnalyzer(url: wav, locale: locale, language: lang); progress?(1); return t }
            catch is CancellationError { throw CancellationError() }
            catch { errors.append("SpeechAnalyzer: \(error)") }
        }
        do { let t = try await sfSpeech(url: wav, locale: locale, language: lang); progress?(1); return t }
        catch is CancellationError { throw CancellationError() }
        catch { errors.append("SFSpeech: \(error)") }
        throw AIToolError.unavailable(errors.joined(separator: "; "))
    }

    /// Region used for a spoken language by the Apple engines.
    static func appleLocale(_ lang: String) -> String {
        switch lang {
        case "fr": return "fr-FR"
        case "en": return "en-US"
        case "es": return "es-ES"
        case "de": return "de-DE"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "ja": return "ja-JP"
        case "zh": return "zh-CN"
        case "ko": return "ko-KR"
        case "nl": return "nl-NL"
        default: return lang
        }
    }

    /// Apple engines have no language identification: transcribe the first ≤ 15 s in each candidate language and
    /// keep the one whose result is most confident and whose text the language recogniser agrees with.
    static func detectLanguageApple(wav: URL, candidates: [String]) async throws -> String {
        guard candidates.count > 1 else { return candidates.first ?? "en" }
        let excerpt = try AudioExtractor.excerpt(wav, seconds: 15)
        defer { if excerpt != wav { try? FileManager.default.removeItem(at: excerpt) } }
        var best = (lang: candidates[0], score: -Double.infinity)
        for lang in candidates {
            try Task.checkCancellation()
            let locale = Locale(identifier: appleLocale(lang))
            var t: Transcript?
            if #available(macOS 26.0, *) { t = try? await speechAnalyzer(url: excerpt, locale: locale, language: lang) }
            if t == nil { t = try? await sfSpeech(url: excerpt, locale: locale, language: lang) }
            guard let t, !t.words.isEmpty else { continue }
            let conf = t.words.compactMap(\.confidence)
            let meanConf = conf.isEmpty ? 0.5 : conf.reduce(0, +) / Double(conf.count)
            let rec = NLLanguageRecognizer()
            rec.processString(t.text)
            let agree = rec.languageHypotheses(withMaximum: 3)[NLLanguage(rawValue: lang)] ?? 0
            let score = meanConf + agree
            if score > best.score { best = (lang, score) }
        }
        return best.lang
    }

    @available(macOS 26.0, *)
    static func speechAnalyzer(url: URL, locale: Locale, language: String) async throws -> Transcript {
        let bcp = locale.identifier(.bcp47)
        let file = try AVAudioFile(forReading: url)
        let module: any SpeechModule
        let engine: String
        let results: AsyncThrowingStream<AttributedString, any Error>
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                      attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            module = t; engine = "SpeechTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield(r.text) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else if await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
                                         attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            module = t; engine = "DictationTranscriber"
            results = AsyncThrowingStream { c in Task { do { for try await r in t.results { c.yield(r.text) }; c.finish() } catch { c.finish(throwing: error) } } }
        } else {
            throw AIToolError.unavailable("no installed SpeechAnalyzer model for \(bcp)")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await text in results {
                for run in text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let w = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if w.isEmpty { continue }
                    if w.allSatisfy({ $0.isPunctuation }) { if !words.isEmpty { words[words.count - 1].text += w }; continue }
                    // a run can hold several words when timing is coarse: spread them over the run
                    let parts = CaptionText.tokens(w)
                    let s = tr.start.seconds, e = tr.end.seconds
                    for (i, p) in parts.enumerated() {
                        let a = s + (e - s) * Double(i) / Double(parts.count), b = s + (e - s) * Double(i + 1) / Double(parts.count)
                        words.append(TranscriptWord(text: p, start: a, end: b, confidence: run.transcriptionConfidence))
                    }
                }
            }
            return words
        }
        try await withTaskCancellationHandler {
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        } onCancel: { collector.cancel() }
        let words = try await collector.value
        return Transcript(engine: engine, language: language, words: words)
    }

    static func sfSpeech(url: URL, locale: Locale, language: String) async throws -> Transcript {
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
        let taskBox = TaskBox()
        let boxed: UncheckedSendable<SFSpeechRecognitionResult> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let once = OnceFlag()
                let t = rec.recognitionTask(with: req) { r, e in
                    if let e { if once.take() { c.resume(throwing: e) } }
                    else if let r, r.isFinal { if once.take() { c.resume(returning: UncheckedSendable(r)) } }
                }
                taskBox.value = t
            }
        } onCancel: { taskBox.value?.cancel() }
        let result = boxed.value
        let words = result.bestTranscription.segments.map {
            TranscriptWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: Double($0.confidence))
        }
        return Transcript(engine: "SFSpeechRecognizer", language: language, words: words)
    }
}

final class TaskBox: @unchecked Sendable { var value: SFSpeechRecognitionTask? }

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Audio extraction for speech engines (16 kHz mono 16-bit WAV, the format whisper.cpp and Speech prefer).
public enum AudioExtractor {
    /// Writes the audio of `url` in `range` (media time) to a temporary WAV. Caller deletes it.
    public static func wav16k(_ url: URL, range: TimeRange?, audioStream: Int? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks[safe: audioStream ?? 0] ?? tracks.first else { throw AIToolError.noInput }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("montage-stt-\(UUID().uuidString).wav")
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range.cmTimeRange }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(ro)
        let writer = try AVAssetWriter(outputURL: out, fileType: .wav)
        let wi = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(wi)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        writer.startWriting(); writer.startSession(atSourceTime: (range?.start ?? .zero).cmTime)
        do {
            while let sb = ro.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !wi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                wi.append(sb)
            }
        } catch {
            reader.cancelReading(); writer.cancelWriting(); try? FileManager.default.removeItem(at: out); throw error
        }
        wi.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AIToolError.noInput }
        return out
    }

    /// First `seconds` of a WAV (for language detection); returns `url` itself if it is short enough.
    static func excerpt(_ url: URL, seconds: Double) throws -> URL {
        let f = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(min(Double(f.length), seconds * f.processingFormat.sampleRate))
        guard AVAudioFramePosition(frames) < f.length else { return url }
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames) else { return url }
        try f.read(into: buf, frameCount: frames)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("montage-lid-\(UUID().uuidString).wav")
        let w = try AVAudioFile(forWriting: out, settings: f.fileFormat.settings, commonFormat: f.processingFormat.commonFormat,
                                interleaved: f.processingFormat.isInterleaved)
        try w.write(from: buf)
        return out
    }

    /// Peak RMS check: true when the audio is (near) silent — "No speech in your video".
    public static func isSilent(_ wav: URL, threshold: Float = 0.003) -> Bool {
        guard let f = try? AVAudioFile(forReading: wav),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(min(f.length, 16000 * 600))),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return false }
        let n = Int(buf.frameLength)
        guard n > 0 else { return true }
        var acc: Float = 0
        for i in stride(from: 0, to: n, by: 4) { acc += ch[i] * ch[i] }
        return (acc / Float(max(n / 4, 1))).squareRoot() < threshold
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
