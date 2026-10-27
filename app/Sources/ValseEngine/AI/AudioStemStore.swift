@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Model-based audio stems produced by ValseAI (W10) for the audio engine (W8), like `MatteStore` for video.
///
/// A stem is a 48 kHz stereo float CAF aligned with the **whole media** (stem time t = media time t), stored at
/// `~/Library/Caches/Valse/stems/<contentHash>-<kind>.caf`. Kinds:
/// - `voice`: isolated speech (Apple's on-device ML `AUSoundIsolation`) — "Isolate voice ▸ Keep vocal", the source for
///   "Reduce noise" (mixed with the original by strength) and "Enhance voice".
/// - `novoice`: the original minus the isolated voice — "Remove vocal" / background music.
/// The audio pipeline substitutes a ready stem for the clip's media audio (same time mapping), falling back to its
/// DSP processing while the stem is being made. `onStemReady` lets the store rebuild the composition.
public final class AudioStemStore: @unchecked Sendable {
    public static let shared = AudioStemStore()
    public let directory: URL
    @MainActor public var onStemReady: ((String, String) -> Void)?

    init() {
        directory = ValsePaths.cacheDirectory.appendingPathComponent("stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func stemURL(media a: MediaAsset, kind: String) -> URL {
        directory.appendingPathComponent("\(a.contentHash)-\(kind).caf")
    }

    /// Ready stem file, if any (sync stat, cheap).
    public func readyStem(media a: MediaAsset, kind: String) -> URL? {
        let u = stemURL(media: a, kind: kind)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    @MainActor public func didWriteStem(media a: MediaAsset, kind: String) { onStemReady?(a.contentHash, kind) }
}

/// Model-based processors plugged into the audio engine's rendered stage (W8 chain) by ValseAI at startup.
/// When `voiceStems` is installed, Isolate voice / Reduce noise / Enhance voice start from the ML voice stem
/// (`RenderStageSpec.mlVoice`) instead of the DSP separation/denoiser; the rest of the chain (enhance EQ/compressor,
/// pitch, voice changer, live FX) is unchanged.
public enum AudioML {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _voiceStems: (@Sendable (MediaAsset, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    /// Makes the `voice` / `novoice` stems of a media item in `AudioStemStore` (cached; progress 0…1).
    public static var voiceStems: (@Sendable (MediaAsset, @escaping @Sendable (Double) -> Void) async throws -> Void)? {
        get { lock.withLock { _voiceStems } }
        set { lock.withLock { _voiceStems = newValue } }
    }
    nonisolated(unsafe) private static var _usedByPlans = false
    /// Whether `ClipAudioPlan` routes clips through the ML stems (set by the app with the provider; tests may install
    /// a provider without enabling it for every plan).
    public static var usedByPlans: Bool {
        get { lock.withLock { _usedByPlans } }
        set { lock.withLock { _usedByPlans = newValue } }
    }
    public static var isAvailable: Bool { voiceStems != nil && usedByPlans }

    /// AI-009 Reduce noise strength → gain of the non-voice residual, as an attenuation limit in dB (DeepFilterNet's
    /// `atten_lim_db` semantics): strength s removes up to `maxReductionDB · s` dB of noise, 100 % removes it all.
    /// A linear wet/dry (1 − s) only reached −6 dB at 50 %, so the slider did little until the very end.
    public static let maxReductionDB: Float = 40
    public static func residualGain(strength s: Float) -> Float {
        if s <= 0 { return 1 }
        if s >= 0.999 { return 0 }
        return powf(10, -maxReductionDB * s / 20)
    }

    nonisolated(unsafe) private static var _musicStems: (@Sendable (MediaAsset, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    /// AU-009 (F3): makes the `demucs-vocals` / `demucs-novocals` stems of a media item (HTDemucs; installed by ValseAI).
    public static var musicStems: (@Sendable (MediaAsset, @escaping @Sendable (Double) -> Void) async throws -> Void)? {
        get { lock.withLock { _musicStems } }
        set { lock.withLock { _musicStems = newValue } }
    }

    /// Writes `voiceGain·voice + restGain·novoice` (48 kHz stereo float CAF) for the rendered stage.
    static func mix(_ a: MediaAsset, voiceGain: Float, restGain: Float, to dst: URL,
                    voiceKind: String = "voice", restKind: String = "novoice") throws {
        let s = AudioStemStore.shared
        guard let vu = s.readyStem(media: a, kind: voiceKind), let ru = s.readyStem(media: a, kind: restKind) else {
            throw NSError(domain: "Valse.AudioML", code: 1)
        }
        let v = try AVAudioFile(forReading: vu), r = try AVAudioFile(forReading: ru)
        let fmt = v.processingFormat
        let out = try AVAudioFile(forWriting: dst, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        let chunk: AVAudioFrameCount = 65_536
        guard let vb = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk), let rb = AVAudioPCMBuffer(pcmFormat: r.processingFormat, frameCapacity: chunk)
        else { throw NSError(domain: "Valse.AudioML", code: 2) }
        while v.framePosition < v.length {
            try v.read(into: vb, frameCount: chunk)
            rb.frameLength = 0
            if r.framePosition < r.length { try r.read(into: rb, frameCount: vb.frameLength) }
            let n = Int(vb.frameLength), m = Int(rb.frameLength)
            for c in 0..<Int(fmt.channelCount) {
                let vp = vb.floatChannelData![c]
                let rp = rb.floatChannelData![min(c, Int(r.processingFormat.channelCount) - 1)]
                for i in 0..<n { vp[i] = vp[i] * voiceGain + (i < m ? rp[i] * restGain : 0) }
            }
            try out.write(from: vb)
            if n == 0 { break }
        }
    }
}
