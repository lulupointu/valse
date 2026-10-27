import Foundation
import ValseCore
import ValseEngine

/// Auto lyrics (AI-002): vocal pre-separation before speech recognition. Words over a loud band are badly recognised
/// (whisper hears the band, drops or invents words), so the music is removed first: Apple's on-device voice isolation
/// (`AUSoundIsolation`, macOS 13+) by default — measured on bench speech under a synthetic band 15 dB louder than the
/// voice, whisper's WER drops 0.28 → 0.21, while HTDemucs `vocals` made it worse (0.64: its vocal stem is tuned for
/// singing and smears speech-like vocals). Demucs is the fallback when voice isolation is missing, then the original mix.
/// Stems are cached per media in `AudioStemStore` (shared with Separate audio / Isolate voice), aligned with the media,
/// so the caption ranges map 1:1.
public enum LyricsVocals {
    public enum Method: String, Sendable, CaseIterable {
        case demucs, voiceIsolation, none
    }

    /// Tests: forces a method.
    nonisolated(unsafe) public static var forcedMethod: Method?

    /// Best separation this Mac can run.
    public static var preferred: Method {
        if let f = forcedMethod { return f }
        if VoiceIsolator.isAvailable { return .voiceIsolation }
        if DemucsRuntime.isAvailable { return .demucs }
        return .none
    }

    /// Cache-key suffix so lyrics transcripts of the separated vocals never mix with plain captions of the same range.
    public static func cacheSuffix(_ m: Method) -> String { m == .none ? "-lyr" : "-lyr-\(m.rawValue)" }

    /// Stem store kind of a method's vocal stem.
    static func stemKind(_ m: Method) -> String? {
        switch m {
        case .demucs: return StemSeparator.Stem.vocals.storeKind
        case .voiceIsolation: return VoiceIsolator.Stem.voice.rawValue
        case .none: return nil
        }
    }

    /// Ready (cached) vocal stem of `a` for `m`, nil when it still has to be separated.
    public static func readyVocals(_ a: MediaAsset, method m: Method) -> URL? {
        stemKind(m).flatMap { AudioStemStore.shared.readyStem(media: a, kind: $0) }
    }

    /// Vocal-only audio of the whole media (separating it when needed) and the method actually used. Falls back to
    /// voice isolation when demucs fails, and to the original mix (`.none`, nil URL) when nothing can separate.
    public static func vocals(_ a: MediaAsset, method: Method = preferred,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> (url: URL?, method: Method) {
        var order: [Method] = []
        if method == .demucs { order = [.demucs, .voiceIsolation] } else if method == .voiceIsolation { order = DemucsRuntime.isAvailable ? [.voiceIsolation, .demucs] : [.voiceIsolation] }
        for m in order {
            if let u = readyVocals(a, method: m) { progress?(1); return (u, m) }
            do {
                switch m {
                case .demucs: try await StemSeparator.separate(a, progress: progress)
                case .voiceIsolation: try await VoiceIsolator.separate(a, progress: progress)
                case .none: break
                }
                if let u = readyVocals(a, method: m) { return (u, m) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                EngineLog.error("lyrics vocal separation (\(m.rawValue)) failed: \(error.localizedDescription)")
            }
        }
        return (nil, .none)
    }
}
