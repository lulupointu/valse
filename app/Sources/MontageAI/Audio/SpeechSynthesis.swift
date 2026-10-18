@preconcurrency import AVFoundation
import Foundation
import CryptoKit
import MontageCore
import MontageEngine

/// A text-to-speech voice (system voices: Siri / premium / enhanced / compact, FR + EN first).
public struct TTSVoice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// BCP-47, e.g. "fr-FR".
    public let language: String
    /// 0 compact, 1 enhanced, 2 premium.
    public let quality: Int
    public let isNovelty: Bool
}

/// Text to speech (AI-006 / AU-030 / TX-016) with AVSpeechSynthesizer, written offline to an audio file.
/// Files are content-addressed (text + voice + rate + pitch) under Application Support/Montage/Generated/tts, so
/// a project keeps working after the cache is cleared and identical requests are instant.
public enum SpeechSynthesis {
    public static var directory: URL { MontagePaths.supportDirectory.appendingPathComponent("Generated/tts", isDirectory: true) }

    /// Voices for a UI language list, best quality first; novelty voices (Bells, Bubbles…) last.
    public static func voices(languages: [String] = ["fr", "en"]) -> [TTSVoice] {
        let novelty: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Wobble", "Good News", "Jester",
                                    "Organ", "Superstar", "Trinoids", "Whisper", "Zarvox", "Fred", "Junior", "Kathy", "Ralph"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { v in languages.contains { v.language.hasPrefix($0) } }
            .map { v in TTSVoice(id: v.identifier, name: v.name, language: v.language, quality: v.quality.rawValue - 1,
                                 isNovelty: novelty.contains(v.name)) }
            .sorted { a, b in
                let la = languages.firstIndex { a.language.hasPrefix($0) } ?? 9, lb = languages.firstIndex { b.language.hasPrefix($0) } ?? 9
                if la != lb { return la < lb }
                if a.isNovelty != b.isNovelty { return !a.isNovelty }
                let main: Set<String> = ["fr-FR", "en-US"]   // Parisian French / US English first (CapCut FR-Parisian, EN-US)
                if main.contains(a.language) != main.contains(b.language) { return main.contains(a.language) }
                if a.quality != b.quality { return a.quality > b.quality }
                return a.name < b.name
            }
    }

    /// Default voice for a language (best non-novelty).
    public static func defaultVoice(_ language: String) -> TTSVoice? {
        voices(languages: [String(language.prefix(2))]).first { !$0.isNovelty }
    }

    public static func cacheURL(text: String, voice: String, rate: Double, pitch: Double) -> URL {
        let key = "\(voice)|\(rate)|\(pitch)|\(text)"
        let h = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("tts-\(h).caf")
    }

    /// Synthesizes `text` (rate 0.5…2 = CapCut speed, pitch 0.5…2). Returns the audio file URL (cached).
    public static func synthesize(_ text: String, voice: String, rate: Double = 1, pitch: Double = 1) async throws -> URL {
        let url = cacheURL(text: text, voice: voice, rate: rate, pitch: pitch)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(identifier: voice) ?? AVSpeechSynthesisVoice(language: L10n.shared.language)
        // AVSpeech rate: 0.5 = normal; map CapCut speed 1× → default rate
        utt.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                             Double(AVSpeechUtteranceMaximumSpeechRate)))
        utt.pitchMultiplier = Float(min(max(pitch, 0.5), 2))
        let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).caf")
        let synth = AVSpeechSynthesizer()
        let writer = TTSWriter(url: tmp)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writer.continuation = c
                synth.write(utt) { buffer in writer.append(buffer) }
            }
        } onCancel: { synth.stopSpeaking(at: .immediate); writer.fail(CancellationError()) }
        guard writer.frames > 0 else { try? FileManager.default.removeItem(at: tmp); throw AIToolError.unavailable("no audio from voice \(voice)") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }
}

/// Receives AVSpeechSynthesizer buffers; an empty buffer marks the end.
final class TTSWriter: @unchecked Sendable {
    let url: URL
    var file: AVAudioFile?
    var frames = 0
    var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finish(nil); return }
            do {
                if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                                        interleaved: pcm.format.isInterleaved) }
                try file?.write(from: pcm)
                frames += Int(pcm.frameLength)
            } catch { finish(error) }
        }
    }

    func fail(_ e: Error) { lock.withLock { finish(e) } }

    private func finish(_ e: Error?) {
        file = nil   // closes the file
        guard let c = continuation else { return }
        continuation = nil
        if let e { c.resume(throwing: e) } else { c.resume() }
    }
}
