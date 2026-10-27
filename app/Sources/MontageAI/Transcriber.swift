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

    /// Transcribes a 16 kHz mono WAV (see `AudioExtractor`). `progress` 0…1. Word boundaries are snapped to the speech
    /// onsets / offsets found in the WAV (`SpeechActivity`), whatever the engine.
    public static func transcribe(wav: URL, request r: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        var t = try await recognize(wav: wav, request: r, progress: progress)
        if !t.words.isEmpty, let vad = SpeechActivity.analyze(wav: wav) { t.words = vad.refine(t.words) }
        return t
    }

    /// Raw engine output (no boundary snapping).
    /// Raw engine output (no boundary snapping). Throws a `SpeechFailure`: when every engine failed, the reason whose
    /// fix most likely works (`SpeechFailure.mostActionable`); the raw errors go to `EngineLog`.
    static func recognize(wav: URL, request r: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        var failures: [SpeechFailure] = []
        var log: [String] = []
        let helper = WhisperRuntime.cliURL
        let model = ModelCatalog.preferredWhisperModel
        if r.engine != .apple {
            if let cli = helper, let model {
                do {
                    return try await WhisperEngine.transcribe(wav: wav, options: .init(language: r.language, model: model, cli: cli,
                                                                                        keepFillers: r.keepFillers), progress: progress)
                } catch is CancellationError { throw CancellationError() }
                catch { log.append("whisper: \(error)"); failures.append(SpeechFailure.classify(error, language: r.language)) }
            } else if r.engine == .whisper {
                throw helper == nil ? SpeechFailure.appIncomplete : SpeechFailure.speechModelNeeded
            } else if model != nil {
                log.append("whisper: model installed, helper missing")
                failures.append(.appIncomplete)
            }
        }
        do {
            let lang: String
            if let l = r.language { lang = l } else { lang = try await detectLanguageApple(wav: wav, candidates: r.candidates) }
            let locale = Locale(identifier: appleLocale(lang))
            progress?(0.1)
            if #available(macOS 26.0, *) {
                do { let t = try await speechAnalyzer(url: wav, locale: locale, language: lang); progress?(1); return t }
                catch is CancellationError { throw CancellationError() }
                catch { log.append("SpeechAnalyzer: \(error)"); failures.append(SpeechFailure.classify(error, language: r.language)) }
            }
            do { let t = try await sfSpeech(url: wav, locale: locale, language: lang); progress?(1); return t }
            catch is CancellationError { throw CancellationError() }
            catch { log.append("SFSpeech: \(error)"); failures.append(SpeechFailure.classify(error, language: r.language)) }
        } catch is CancellationError { throw CancellationError() }
        catch { log.append("language detection: \(error)"); failures.append(SpeechFailure.classify(error, language: r.language)) }
        EngineLog.error("speech recognition failed: \(log.joined(separator: "; "))")
        throw SpeechFailure.mostActionable(failures, whisperUsable: helper != nil && model != nil).resolved(helperPresent: helper != nil)
    }

    /// Pre-flight for the captions panel (cheap: no audio is read). `language` nil = auto detect, judged on
    /// `uiLanguage` (the language the user most likely speaks).
    public static func readiness(language: String?, engine: SpeechEngine, uiLanguage: String) async -> SpeechReadiness {
        if let forced = SpeechTestHooks.forcedReadiness { return forced }
        let helper = WhisperRuntime.cliURL != nil
        let model = ModelCatalog.installedWhisperModel != nil
        if engine == .whisper {
            if !helper { return .blocked(.appIncomplete) }
            return model ? .ready : .blocked(.speechModelNeeded)
        }
        if engine == .automatic && helper && model { return .ready }
        let lang = language ?? uiLanguage
        let locale = Locale(identifier: appleLocale(lang))
        if #available(macOS 26.0, *), await analyzerInstalled(locale) { return .ready }
        let rec = SFSpeechRecognizer(locale: locale)
        guard let rec, rec.supportsOnDeviceRecognition else {
            return .blocked(SpeechFailure.languageUnavailable(language: lang, canAddDictation: rec != nil).resolved(helperPresent: helper))
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .ready
        case .notDetermined: return .needsPermissionPrompt
        case .denied: return .blocked(.permissionDenied)
        case .restricted: return .blocked(SpeechFailure.permissionRestricted.resolved(helperPresent: helper))
        @unknown default: return .ready
        }
    }

    @available(macOS 26.0, *)
    static func analyzerInstalled(_ locale: Locale) async -> Bool {
        let bcp = locale.identifier(.bcp47)
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp }) { return true }
        return await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == bcp })
    }

    /// True when transcribing `r` will show the macOS speech-recognition prompt (Apple engine, not asked yet): the
    /// caption job then shows "Waiting for permission…" and calls `requestAuthorization` first.
    public static func willAskPermission(_ r: Request) -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined, SpeechTestHooks.forcedFailure == nil else { return false }
        if r.engine == .whisper { return false }
        return !(r.engine == .automatic && WhisperRuntime.isAvailable)
    }

    /// Asks for speech recognition permission and waits for the user's answer (no time limit in the app: a first-time
    /// user reading the macOS prompt must not get a failure; unit-test processes, which never get an answer, give up
    /// after 3 s). Cancelling the task stops waiting.
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        let once = OnceFlag()
        let box = AuthContinuation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                box.set(c)
                SFSpeechRecognizer.requestAuthorization { s in if once.take() { box.resume(s) } }
                if MontageProcess.isUnitTest {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if once.take() { box.resume(.notDetermined) } }
                }
            }
        } onCancel: { if once.take() { box.resume(.notDetermined) } }
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
        var failures: [SpeechFailure] = []
        var answered = false
        for lang in candidates {
            try Task.checkCancellation()
            let locale = Locale(identifier: appleLocale(lang))
            var t: Transcript?
            if #available(macOS 26.0, *) {
                do { t = try await speechAnalyzer(url: excerpt, locale: locale, language: lang) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append(SpeechFailure.classify(error)) }
            }
            if t == nil {
                do { t = try await sfSpeech(url: excerpt, locale: locale, language: lang) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append(SpeechFailure.classify(error)) }
            }
            if t != nil { answered = true }
            guard let t, !t.words.isEmpty else { continue }
            let conf = t.words.compactMap(\.confidence)
            let meanConf = conf.isEmpty ? 0.5 : conf.reduce(0, +) / Double(conf.count)
            let rec = NLLanguageRecognizer()
            rec.processString(t.text)
            let agree = rec.languageHypotheses(withMaximum: 3)[NLLanguage(rawValue: lang)] ?? 0
            let score = meanConf + agree
            if score > best.score { best = (lang, score) }
        }
        // every candidate failed (no recognizer, no permission…): say why instead of guessing the first language
        if !answered, !failures.isEmpty {
            // "no speech" in one candidate is not a reason to stop: the full transcription decides
            let real = failures.filter { if case .noSpeech = $0 { return false }; return true }
            if !real.isEmpty, real.count == failures.count { throw SpeechFailure.mostActionable(real) }
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
            EngineLog.info("no installed SpeechAnalyzer model for \(bcp)")
            throw SpeechFailure.languageUnavailable(language: language, canAddDictation: SFSpeechRecognizer(locale: locale) != nil)
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
        // the recognizer first: a language this Mac can't do is the real problem even before permission
        let maybeRec = SFSpeechRecognizer(locale: locale)
        guard let rec = maybeRec, rec.supportsOnDeviceRecognition else {
            throw SpeechFailure.languageUnavailable(language: language, canAddDictation: maybeRec != nil)
        }
        // waits for the user's answer (BUG-CAPTION-ERRORS: a 3 s limit counted a prompt still open as a refusal)
        let status = await requestAuthorization()
        try Task.checkCancellation()
        switch status {
        case .authorized: break
        case .restricted: throw SpeechFailure.permissionRestricted
        case .denied: throw SpeechFailure.permissionDenied
        default: throw SpeechFailure.other(detail: "speech recognition permission not answered")
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

/// Continuation that may be resumed before it is installed (cancellation racing the prompt): the value is kept.
final class AuthContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
    private var value: SFSpeechRecognizerAuthorizationStatus?
    func set(_ c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) {
        let v: SFSpeechRecognizerAuthorizationStatus? = lock.withLock { if let v = value { return v }; self.c = c; return nil }
        if let v { c.resume(returning: v) }
    }
    func resume(_ v: SFSpeechRecognizerAuthorizationStatus) {
        let cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>? = lock.withLock {
            if let c { self.c = nil; return c }; value = v; return nil
        }
        cont?.resume(returning: v)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Audio extraction for speech engines (16 kHz mono 16-bit WAV, the format whisper.cpp and Speech prefer).
public enum AudioExtractor {
    /// Writes the audio of `url` in `range` (media time) to a temporary WAV. Caller deletes it.
    /// Throws `SpeechFailure.mediaOffline` (file gone), `.noSoundInFile` (no audio stream), `.diskFull`.
    public static func wav16k(_ url: URL, range: TimeRange?, audioStream: Int? = nil) async throws -> URL {
        do { return try await wav16kRaw(url, range: range, audioStream: audioStream) }
        catch is CancellationError { throw CancellationError() }
        catch let f as SpeechFailure { throw f }
        catch {
            let ns = error as NSError
            EngineLog.error("audio extraction failed for \(url.lastPathComponent): \(error)")
            if SpeechFailure.isDiskFull(ns) { throw SpeechFailure.diskFull }
            if !FileManager.default.fileExists(atPath: url.path) || SpeechFailure.isFileMissing(ns) {
                throw SpeechFailure.mediaOffline(name: url.lastPathComponent, media: nil)
            }
            throw SpeechFailure.noSoundInFile(name: url.lastPathComponent)
        }
    }

    static func wav16kRaw(_ url: URL, range: TimeRange?, audioStream: Int?) async throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SpeechFailure.mediaOffline(name: url.lastPathComponent, media: nil) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks[safe: audioStream ?? 0] ?? tracks.first else { throw SpeechFailure.noSoundInFile(name: url.lastPathComponent) }
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
            while let sb = await OffPool.next(ro) {
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
