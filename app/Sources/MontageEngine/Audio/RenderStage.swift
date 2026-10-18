@preconcurrency import AVFoundation
import Foundation
import MontageCore

final class IdentityTransform: SpectralTransform {
    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {}
}

/// Streaming processor for a `RenderStageSpec`: separation → denoise → enhance → pitch/formant (+ harmony) →
/// robot / whisper. In place; output is delayed by `latency` frames (the renderer compensates).
public final class RenderStageProcessor {
    public let spec: RenderStageSpec
    public let channels: Int
    public let sampleRate: Double
    private var stages: [(AudioBlock) -> Void] = []
    public private(set) var latency = 0
    private var scratch: [AudioBuffer] = []
    private var tables: [UnsafeMutablePointer<UnsafeMutablePointer<Float>>] = []
    private let maxChunk: Int
    private var denoiser: DenoiseTransform?
    deinit { tables.forEach { $0.deallocate() } }

    /// `noiseProfile`: per-bin power from `NoiseProfiler` (n = 2048) to seed the denoiser (optional).
    public init(spec: RenderStageSpec, sampleRate: Double = AudioFileIO.sampleRate, channels: Int = 2,
                noiseProfile: [Float]? = nil, maxChunk: Int = 8192) {
        self.spec = spec; self.channels = channels; self.sampleRate = sampleRate; self.maxChunk = maxChunk
        let n = 2048
        if let sep = spec.separation, channels >= 2 {
            add(StreamingSTFT(n: 4096, hop: 1024, channels: channels, transform: VocalSeparationTransform(mode: sep, n: 4096, sampleRate: sampleRate)))
        }
        let denoise = spec.mlVoice == true ? 0 : max(spec.denoise ?? 0, spec.enhance.map { 0.25 + 0.5 * $0 } ?? 0)
        if denoise > 0 {
            let t = DenoiseTransform(strength: denoise, n: n, hop: 512, sampleRate: sampleRate, channels: channels)
            if let noiseProfile, noiseProfile.count == n / 2 + 1 { t.seed(noiseProfile) }
            denoiser = t
            add(StreamingSTFT(n: n, hop: 512, channels: channels, transform: t))
        }
        if let e = spec.enhance {
            let chain = LiveChain(Self.enhanceChain(e), sampleRate: sampleRate)
            stages.append { chain.process($0) }
        }
        let pn = 4096, hop = 512
        if !spec.harmony.isEmpty {
            // dry (pitch-shifted main voice) + harmony voices, all with the same latency
            let voices = [0.0] + spec.harmony
            let stfts = voices.map { semis in
                StreamingSTFT(n: pn, hop: hop, channels: channels,
                              transform: PitchShiftTransform(pitch: spec.pitch * pow(2, semis / 12), formant: spec.formant, n: pn, hop: hop,
                                                             sampleRate: sampleRate, channels: channels))
            }
            latency += stfts[0].latency
            let bufs = voices.map { _ in AudioBuffer(channels: channels, frames: maxChunk, sampleRate: sampleRate) }
            scratch += bufs
            let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
            tables.append(table)
            let gain = Float(1 / (1 + 0.45 * Double(spec.harmony.count)))
            stages.append { b in
                for (v, stft) in stfts.enumerated() {
                    for c in 0..<channels { table[c] = bufs[v].pointer(c); table[c].update(from: b[min(c, b.channels - 1)], count: b.frames) }
                    stft.process(AudioBlock(channels: channels, frames: b.frames, pointers: table))
                }
                for c in 0..<min(channels, b.channels) {
                    let o = b[c]
                    for i in 0..<b.frames {
                        var s = bufs[0][c, i]
                        for v in 1..<bufs.count { s += bufs[v][c, i] * 0.8 }
                        o[i] = s * gain
                    }
                }
            }
        } else if abs(spec.pitch - 1) > 1e-4 || abs(spec.formant - 1) > 1e-4 {
            add(StreamingSTFT(n: pn, hop: hop, channels: channels,
                              transform: PitchShiftTransform(pitch: spec.pitch, formant: spec.formant, n: pn, hop: hop, sampleRate: sampleRate, channels: channels)))
        }
        if let hz = spec.robotHz {
            let rh = max(64, min(1024, Int((sampleRate / max(hz, 20)).rounded())))
            add(StreamingSTFT(n: 2048, hop: rh, channels: channels, transform: RobotTransform()))
        }
        if spec.whisper {
            add(StreamingSTFT(n: 512, hop: 128, channels: channels, transform: WhisperTransform()))
        }
    }

    private func add(_ s: StreamingSTFT) {
        latency += s.latency
        stages.append { s.process($0) }
    }

    /// Voice enhancement colour (after denoise): rumble cut, mud cut, presence and air lift, gentle compression.
    static func enhanceChain(_ s: Double) -> [LiveNode] {
        [.highPass(hz: 80), .lowShelf(hz: 220, db: -2 * s), .peak(hz: 3200, q: 0.9, db: 3 * s), .highShelf(hz: 10000, db: 2 * s),
         .compressor(thresholdDB: -24, ratio: 1 + 2.5 * s, attackMs: 5, releaseMs: 120, makeupDB: 4 * s), .limiter]
    }

    public func process(_ b: AudioBlock) {
        precondition(b.frames <= maxChunk)
        for s in stages { s(b) }
    }

    /// Processes a whole in-memory buffer with latency compensation (tests, short clips).
    public func render(_ input: AudioBuffer) -> AudioBuffer {
        if let denoiser {
            // same two-pass scheme as the file renderer: profile from the quietest stretch of the first 60 s
            let profiler = NoiseProfiler(n: 2048, hop: 512, sampleRate: input.sampleRate)
            let scan = AudioBuffer(channels: input.channels, frames: min(input.frames, Int(60 * input.sampleRate)), sampleRate: input.sampleRate)
            for c in 0..<input.channels { scan.pointer(c).update(from: input.pointer(c), count: scan.frames) }
            scan.process(chunk: 4096) { profiler.feed($0) }
            if let p = profiler.profile { denoiser.seed(p) }
        }
        let out = AudioBuffer(channels: input.channels, frames: input.frames, sampleRate: input.sampleRate)
        let work = AudioBuffer(channels: input.channels, frames: maxChunk, sampleRate: input.sampleRate)
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: input.channels)
        defer { table.deallocate() }
        var readPos = 0, produced = 0, skip = latency
        while produced < input.frames {
            let n = min(maxChunk, input.frames + latency - readPos)
            guard n > 0 else { break }
            for c in 0..<input.channels {
                for i in 0..<n { work[c, i] = readPos + i < input.frames ? input[c, readPos + i] : 0 }
                table[c] = work.pointer(c)
            }
            process(AudioBlock(channels: input.channels, frames: n, pointers: table))
            readPos += n
            var i = 0
            if skip > 0 { let d = min(skip, n); skip -= d; i = d }
            while i < n && produced < input.frames {
                for c in 0..<input.channels { out[c, produced] = work[c, i] }
                produced += 1; i += 1
            }
        }
        return out
    }
}

/// Renders and caches the offline stage of clip audio: whole media file × `RenderStageSpec` → lossless CAF in
/// ~/Library/Caches/Montage/audio/<contentHash>-<specKey>.caf (shared by every clip/project using the same settings).
/// Preview picks a render up as soon as it is ready (`onReady` → rebuild); export awaits it.
public final class AudioRenderCache: @unchecked Sendable {
    public static let shared = AudioRenderCache()

    public let directory: URL
    private let lock = NSLock()
    private var ready: Set<String> = []
    private var inflight: [String: Task<URL, Error>] = [:]
    private var progressByKey: [String: Double] = [:]
    /// Called on the main actor when a render finishes (argument = media content hash).
    @MainActor public var onReady: ((String) -> Void)?
    /// Called on the main actor when the set of in-flight renders or their progress changes.
    @MainActor public var onProgress: (() -> Void)?

    init(directory: URL = MontagePaths.cacheDirectory.appendingPathComponent("audio", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ready = Set(files.filter { $0.hasSuffix(".caf") }.map { String($0.dropLast(4)) })
    }

    func key(_ a: MediaAsset, _ spec: RenderStageSpec) -> String { "\(a.contentHash)-\(spec.cacheKey)" }
    public func url(for a: MediaAsset, spec: RenderStageSpec) -> URL { directory.appendingPathComponent("\(key(a, spec)).caf") }

    /// Rendered file if ready (synchronous, used while building compositions).
    public func readyURL(for a: MediaAsset, spec: RenderStageSpec) -> URL? {
        if spec.isIdentity { return a.url }
        let k = key(a, spec)
        return lock.withLock { ready.contains(k) } ? url(for: a, spec: spec) : nil
    }

    /// Progress of an in-flight render (nil if none).
    public func progress(for a: MediaAsset, spec: RenderStageSpec) -> Double? { lock.withLock { progressByKey[key(a, spec)] } }
    public var isBusy: Bool { lock.withLock { !inflight.isEmpty } }
    /// Content hashes with a render in flight.
    public var busyMedia: Set<String> { lock.withLock { Set(inflight.keys.map { String($0.prefix { $0 != "-" }) }) } }

    /// Renders (or returns the cached) file. Concurrent calls for the same key share one render.
    public func render(_ a: MediaAsset, spec: RenderStageSpec) async throws -> URL {
        if let u = readyURL(for: a, spec: spec) { return u }
        let k = key(a, spec)
        let dst = url(for: a, spec: spec)
        let task: Task<URL, Error> = lock.withLock {
            if let t = inflight[k] { return t }
            let t = Task.detached(priority: .userInitiated) { [weak self] () throws -> URL in
                let owner = self
                if spec.mlVoice == true, let stems = AudioML.voiceStems {
                    // W10 ML pre-pass: voice / remaining stems, mixed per setting, then the rest of the DSP chain
                    try await stems(a) { p in owner?.setProgress(k, 0.6 * p) }
                    let sep = spec.separation
                    let strength = Float(spec.denoise ?? (spec.enhance != nil ? 0.9 : 1))
                    let vg: Float = sep == .removeVocals ? 0 : 1
                    let rg: Float = sep == .keepVocals ? 0 : (sep == .removeVocals ? 1 : 1 - strength)
                    let mixed = dst.deletingLastPathComponent().appendingPathComponent("ml-\(UUID().uuidString).caf")
                    defer { try? FileManager.default.removeItem(at: mixed) }
                    try AudioML.mix(a, voiceGain: vg, restGain: rg, to: mixed)
                    var rest = spec
                    rest.separation = nil; rest.denoise = nil
                    try await Self.renderFile(source: mixed, spec: rest, to: dst, duration: a.duration) { p in
                        owner?.setProgress(k, 0.6 + 0.4 * p)
                    }
                } else {
                    try await Self.renderFile(source: a.url, spec: spec, to: dst, duration: a.duration) { p in
                        owner?.setProgress(k, p)
                    }
                }
                return dst
            }
            inflight[k] = t
            progressByKey[k] = 0
            return t
        }
        notifyProgress()
        do {
            let u = try await task.value
            lock.withLock { ready.insert(k); inflight[k] = nil; progressByKey[k] = nil }
            let hash = a.contentHash
            await MainActor.run { onReady?(hash); onProgress?() }
            return u
        } catch {
            lock.withLock { inflight[k] = nil; progressByKey[k] = nil }
            notifyProgress()
            throw error
        }
    }

    /// Fire-and-forget render for preview.
    public func request(_ a: MediaAsset, spec: RenderStageSpec) {
        guard readyURL(for: a, spec: spec) == nil else { return }
        if lock.withLock({ inflight[key(a, spec)] != nil }) { return }
        Task { do { _ = try await render(a, spec: spec) } catch { EngineLog.error("audio render failed: \(error)") } }
    }

    private func setProgress(_ k: String, _ p: Double) {
        let changed: Bool = lock.withLock {
            let old = progressByKey[k] ?? 0
            guard p - old >= 0.02 || p >= 1 else { return false }
            progressByKey[k] = p; return true
        }
        if changed { notifyProgress() }
    }

    private func notifyProgress() { Task { @MainActor in self.onProgress?() } }

    /// Removes every rendered file (tests / "clear cache").
    public func purge() {
        lock.withLock { ready.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Two passes when denoising (noise profile from the quietest 150 ms of the first 60 s), then the stage, with
    /// latency compensated so the output is sample-aligned with the source.
    static func renderFile(source: URL, spec: RenderStageSpec, to dst: URL, duration: Time,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let sr = AudioFileIO.sampleRate
        var profile: [Float]?
        if spec.denoise != nil || spec.enhance != nil {
            let profiler = NoiseProfiler(n: 2048, hop: 512, sampleRate: sr)
            try await AudioFileIO.stream(source, range: TimeRange(start: .zero, duration: min(duration, Time(60)))) { profiler.feed($0) }
            profile = profiler.profile
        }
        let proc = RenderStageProcessor(spec: spec, sampleRate: sr, channels: 2, noiseProfile: profile)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).caf")
        let writer = try AudioFileIO.Writer(url: tmp, format: .alac, sampleRate: sr, channels: 2)
        var skip = proc.latency
        let total = max(1, duration.seconds * sr)
        var done = 0
        func emit(_ b: AudioBlock) throws {
            proc.process(b)
            let d = min(skip, b.frames); skip -= d
            if d < b.frames { try writer.write(b, offset: d, count: b.frames - d) }
            done += b.frames
            progress(min(0.99, Double(done) / total))
        }
        let frames = try await AudioFileIO.stream(source) { try emit($0) }
        // flush the latency tail
        let tail = AudioBuffer(channels: 2, frames: 8192, sampleRate: sr)
        var left = proc.latency
        while left > 0 {
            let n = min(8192, left)
            for c in 0..<2 { tail.pointer(c).update(repeating: 0, count: n) }
            let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            table[0] = tail.pointer(0); table[1] = tail.pointer(1)
            try emit(AudioBlock(channels: 2, frames: n, pointers: table))
            table.deallocate()
            left -= n
        }
        writer.close()
        _ = frames
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        progress(1)
    }
}
