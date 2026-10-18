@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import MontageCore
import Observation

/// Dictate (TX-034): streaming speech input into a text field. Microphone → AVAudioEngine tap → Apple's on-device
/// speech recognizer (`requiresOnDeviceRecognition`, nothing leaves the Mac) with partial results, so words appear
/// while the user speaks. One session at a time; it ends on `stop()`, after 2.5 s of silence following speech, or after
/// 60 s (the recognizer's limit).
@MainActor
@Observable
public final class Dictation {
    public static let shared = Dictation()

    public enum Failure: Error, Sendable, Equatable {
        case notAuthorized, microphoneDenied, unsupportedLanguage, noMicrophone
        public var messageKey: String {
            switch self {
            case .notAuthorized: return "dictate.error.notAuthorized"
            case .microphoneDenied: return "dictate.error.microphone"
            case .unsupportedLanguage: return "dictate.error.language"
            case .noMicrophone: return "dictate.error.noMicrophone"
            }
        }
    }

    /// Identifies the field being dictated into (so only its mic button shows "listening").
    public private(set) var owner: String?
    public var isRunning: Bool { owner != nil }
    /// Microphone level 0…1 while listening (for the button's pulse).
    public private(set) var level: Double = 0

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var onEnd: (() -> Void)?
    private var heardSpeech = false

    /// Starts dictating; `onText(text, isFinal)` receives the full text so far of this session (append it to what the
    /// field held when dictation started, see `DictationText.merge`).
    public func start(owner: String, language: String, onText: @escaping @MainActor (String, Bool) -> Void,
                      onEnd: @escaping @MainActor () -> Void) async throws {
        stop()
        guard await Self.authorize() else { throw Failure.notAuthorized }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        let locale = Locale(identifier: language == "fr" ? "fr-FR" : (language == "en" ? "en-US" : language))
        guard let rec = SFSpeechRecognizer(locale: locale), rec.supportsOnDeviceRecognition else { throw Failure.unsupportedLanguage }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        let levelBox = LevelBox()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            req.append(buf)
            levelBox.update(buf)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.request = req
        self.owner = owner
        self.onEnd = onEnd
        heardSpeech = false
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.owner == owner else { return }
                if let text { onText(text, final); self.heardSpeech = true; self.armSilenceTimer() }
                if final || error != nil { self.stop() }
            }
        }
        // level meter + hard limit
        silenceTimer = nil
        Task { [weak self] in
            let started = Date()
            while let self, self.owner == owner {
                self.level = levelBox.value
                if Date().timeIntervalSince(started) > 60 { self.stop(); break }
                if !self.heardSpeech, Date().timeIntervalSince(started) > 8 { self.stop(); break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// Ends the session (the last partial result stays in the field).
    public func stop() {
        guard owner != nil else { return }
        silenceTimer?.cancel(); silenceTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.finish()
        engine = nil; request = nil; task = nil
        owner = nil
        level = 0
        let end = onEnd
        onEnd = nil
        end?()
    }

    private func armSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    static func authorize() async -> Bool {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        return status == .authorized
    }

    final class LevelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Double = 0
        var value: Double { lock.withLock { v } }
        func update(_ buf: AVAudioPCMBuffer) {
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(buf.frameLength))
            let db = 20 * log10(max(rms, 1e-5))
            lock.withLock { v = Double(min(max((db + 50) / 40, 0), 1)) }
        }
    }
}

/// How dictated text joins what the field already held.
public enum DictationText {
    /// `base` + a separating space when needed + the session's text so far.
    public static func merge(base: String, dictated: String) -> String {
        let d = dictated.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return base }
        guard !base.isEmpty else { return d }
        let sep = base.last.map { $0.isWhitespace || $0.isNewline } ?? true ? "" : " "
        return base + sep + d
    }
}
