import Foundation
import ValseCore

/// CapCut "Export audio" (EX-008 / EX-009 / AU-022): MP3 / WAV / AAC / FLAC (+ ALAC), bit rate, bit depth, sample rate.
/// WAV/AAC/FLAC/ALAC use W8's `AudioExporter` (system encoders, 48 kHz). MP3 is encoded by the FFmpeg sidecar's
/// `libmp3lame` (LAME is LGPL; FFmpeg runs as a separate process, never linked — ARCHITECTURE §6.1).
public struct AudioOutputSettings: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case mp3, wav, aac, flac, alac
        /// CapCut menu: MP3, WAV, AAC, FLAC.
        public static let menuOrder: [Format] = [.mp3, .wav, .aac, .flac, .alac]
        public var label: String { self == .alac ? "ALAC" : rawValue.uppercased() }
        public var fileExtension: String {
            switch self { case .mp3: "mp3"; case .wav: "wav"; case .aac: "m4a"; case .flac: "flac"; case .alac: "m4a" }
        }
        public var isLossy: Bool { self == .mp3 || self == .aac }
        public var hasBitDepth: Bool { self == .wav || self == .flac || self == .alac }
    }
    public static let bitrates = [128, 192, 256, 320]
    public static let sampleRates = [44100, 48000]

    public var format: Format = .mp3
    public var bitrateKbps: Int = 320
    /// WAV: 16 / 24 bit (FLAC/ALAC are written at 24-bit).
    public var bitDepth: Int = 16
    /// MP3 can be resampled to 44.1 kHz; native formats are rendered at 48 kHz.
    public var sampleRate: Int = 48000
    public init() {}

    enum CodingKeys: String, CodingKey { case format, bitrateKbps, bitDepth, sampleRate }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(Format.self, forKey: .format)) ?? .mp3
        bitrateKbps = (try? c.decodeIfPresent(Int.self, forKey: .bitrateKbps)) ?? 320
        bitDepth = (try? c.decodeIfPresent(Int.self, forKey: .bitDepth)) ?? 16
        sampleRate = (try? c.decodeIfPresent(Int.self, forKey: .sampleRate)) ?? 48000
    }

    public var effectiveSampleRate: Int { format == .mp3 ? sampleRate : 48000 }

    public func estimatedBytes(duration: Time) -> Int64 {
        let s = duration.seconds
        switch format {
        case .mp3, .aac: return Int64(Double(bitrateKbps) * 125 * s)
        case .wav: return Int64(Double(effectiveSampleRate) * 2 * Double(bitDepth / 8) * s)
        case .flac, .alac: return Int64(Double(effectiveSampleRate) * 2 * 3 * s * 0.6)
        }
    }
}

public enum AudioOnlyExporter {
    public static func export(project: Project, settings: AudioOutputSettings, to url: URL, range: TimeRange? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        switch settings.format {
        case .mp3:
            try await MP3Encoder.export(project: project, settings: settings, to: url, range: range, progress: progress)
        case .wav, .aac, .flac, .alac:
            let f: AudioFileIO.Format
            switch settings.format {
            case .wav: f = settings.bitDepth >= 24 ? .wav24 : .wav16
            case .aac: f = .aac
            case .flac: f = .flac
            default: f = .alac
            }
            try? FileManager.default.removeItem(at: url)
            try await AudioExporter.export(project: project, settings: AudioExportSettings(format: f, bitrateKbps: settings.bitrateKbps),
                                           to: url, range: range, progress: progress)
        }
    }
}

/// MP3 through the FFmpeg sidecar: the export mix is streamed as raw float PCM into `ffmpeg -c:a libmp3lame`.
public enum MP3Encoder {
    private static let cache = AvailabilityCache()

    /// True when an FFmpeg sidecar with the LGPL LAME encoder is installed (checked once).
    public static func isAvailable() async -> Bool {
        if let v = cache.value { return v }
        guard let exe = FFmpegSidecar.executableURL,
              let (out, status) = try? await FFmpegSidecar.run(exe, ["-hide_banner", "-encoders"]), status == 0 else {
            cache.value = false; return false
        }
        let ok = String(decoding: out, as: UTF8.self).contains("libmp3lame")
        cache.value = ok
        return ok
    }

    public static func export(project: Project, settings: AudioOutputSettings, to url: URL, range: TimeRange? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        guard await isAvailable(), let exe = FFmpegSidecar.executableURL else { throw ExportError.encoderUnavailable("mp3") }
        try? FileManager.default.removeItem(at: url)
        signal(SIGPIPE, SIG_IGN)   // a dying ffmpeg must surface as a write error, not kill the app
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-hide_banner", "-loglevel", "error", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "pipe:0",
                       "-c:a", "libmp3lame", "-b:a", "\(settings.bitrateKbps)k", "-ar", "\(settings.effectiveSampleRate)",
                       "-id3v2_version", "3", "-y", url.path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = ProcessWaiter()
        p.terminationHandler = { done.finish($0.terminationStatus) }
        try p.run()
        let total = max(1, (range?.duration ?? project.duration).seconds * 48000)
        var frames = 0
        var scratch = [Float]()
        let writer = stdin.fileHandleForWriting
        do {
            try await AudioMixdown.stream(project, range: range) { b in
                try Task.checkCancellation()
                if scratch.count < b.frames * 2 { scratch = [Float](repeating: 0, count: b.frames * 2) }
                for i in 0..<b.frames { scratch[2 * i] = b[0][i]; scratch[2 * i + 1] = b[1][i] }
                let data = scratch.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<(b.frames * 2)])) }
                try writer.write(contentsOf: data)
                frames += b.frames
                progress?(min(0.999, Double(frames) / total))
            }
        } catch {
            try? writer.close(); p.terminate()
            _ = await done.wait()
            try? FileManager.default.removeItem(at: url)
            throw (error is CancellationError) ? ExportError.cancelled : error
        }
        try? writer.close()
        let status = await done.wait()
        guard status == 0 else { try? FileManager.default.removeItem(at: url); throw ExportError.failed("ffmpeg mp3 exit \(status)") }
        progress?(1)
    }
}

final class AvailabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    var value: Bool? { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

/// Awaitable process termination (the handler may fire before or after `wait()`).
final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    func finish(_ s: Int32) {
        let w: [CheckedContinuation<Int32, Never>] = lock.withLock { status = s; let w = waiters; waiters = []; return w }
        w.forEach { $0.resume(returning: s) }
    }
    func wait() async -> Int32 {
        await withCheckedContinuation { c in
            let s: Int32? = lock.withLock { if let s = status { return s }; waiters.append(c); return nil }
            if let s { c.resume(returning: s) }
        }
    }
}
