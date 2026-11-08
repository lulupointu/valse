@preconcurrency import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ValseCore

/// What a compound clip shows on the timeline (BUG-COMPOUND-PREVIEW): filmstrip frames rendered through the real
/// compositor from the compound's nested timeline (every layer, effect, text…, like `OfflineRenderer`) and the waveform
/// of its mixed audio (the export mixdown, `AudioMixdown`: inner volumes, mutes, solo, fades, keyframes).
/// Everything is keyed by a content key of the nested timeline (`key(of:in:)`), so any change inside the compound gives
/// new frames / a new waveform; while they are being made, the previous content of the same compound is shown
/// (`noteKey` → stale fallback) so editing inside a compound does not blank its filmstrip.
/// `cached…` lookups are synchronous (drawing); `thumbnail` / `waveform` generate in the background.
public final class CompoundPreviewCache: @unchecked Sendable {
    public static let shared = CompoundPreviewCache()

    /// Thumbnail time quantum (s, nested-timeline time), same as media filmstrips.
    public static let quantum = ThumbnailCache.quantum
    /// Generators (built compositions) kept alive, most recent first.
    static let maxGenerators = 6
    /// Mixed waveforms kept in memory.
    static let maxWaves = 48

    private let memory = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var waves: [String: Waveform] = [:]
    private var waveOrder: [String] = []
    private var inflight: Set<String> = []
    private var current: [CompoundID: String] = [:]
    private var previous: [CompoundID: String] = [:]
    private var generators: [(key: String, task: Task<GeneratorBox?, Never>)] = []
    private var made = 0
    private let thumbGate = AsyncSemaphore(limit: 2)
    private let waveGate = AsyncSemaphore(limit: 1)

    init() {
        memory.totalCostLimit = MemoryBudget.thumbnailCacheBytes / 2
    }

    // MARK: Content key

    private struct KeyInput: Encodable {
        let settings: ProjectSettings
        let timeline: Timeline
        let compounds: [CompoundClip]?
        let media: [String]
    }

    /// Content key of what compound `c` renders inside `project`: its nested timeline, the project settings, the nested
    /// compounds and the content of every media they use. Not the compound clip's own placement / look on the parent.
    public static func key(of c: CompoundClip, in project: Project) -> String {
        var ids = Set<MediaID>()
        func collect(_ tl: Timeline) { for t in tl.tracks { for x in t.clips { if let m = x.mediaID { ids.insert(m) } } } }
        collect(c.timeline)
        let nestedCompounds = project.compounds.flatMap { $0.isEmpty ? nil : $0 }
        for n in nestedCompounds ?? [] { collect(n.timeline) }
        let media = ids.compactMap { id in project.asset(id).map { "\(id.raw.uuidString):\($0.contentHash):\($0.url.path)" } }.sorted()
        let input = KeyInput(settings: project.settings, timeline: c.timeline, compounds: nestedCompounds, media: media)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(input)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Records that compound `id` now shows content `key`: until frames / waveform of `key` exist, those of the
    /// previous key are returned by the `cached…` lookups.
    public func noteKey(_ key: String, for id: CompoundID) {
        lock.withLock {
            guard current[id] != key else { return }
            if let c = current[id] { previous[id] = c }
            current[id] = key
        }
    }

    // MARK: Thumbnails

    public static func quantize(_ t: Time) -> Int { max(0, Int((t.seconds / quantum).rounded(.down))) }

    private func thumbKey(_ key: String, _ q: Int, _ h: Int) -> String { "\(key)-\(q)-\(h)" }

    /// Memory-cached composite frame at nested time `t` (the previous content of `compound` while `key`'s is pending).
    public func cachedThumbnail(key: String, compound: CompoundID? = nil, at t: Time, height: Int) -> CGImage? {
        let q = Self.quantize(t)
        if let img = memory.object(forKey: thumbKey(key, q, height) as NSString) { return img }
        guard let id = compound, let prev = lock.withLock({ previous[id] }), prev != key else { return nil }
        return memory.object(forKey: thumbKey(prev, q, height) as NSString)
    }

    /// Exact (not stale) cached frame.
    public func hasThumbnail(key: String, at t: Time, height: Int) -> Bool {
        memory.object(forKey: thumbKey(key, Self.quantize(t), height) as NSString) != nil
    }

    /// Composite frame of `nested` (the project seen from inside the compound, `Project.nested`) at nested time `t`,
    /// `height` pixels high, rendered through the compositor. `key` = `key(of:in:)`.
    public func thumbnail(_ nested: Project, key: String, at t: Time, height: Int) async -> CGImage? {
        let q = Self.quantize(t)
        let k = thumbKey(key, q, height)
        if let img = memory.object(forKey: k as NSString) { return img }
        guard nested.duration > .zero, height > 0, lock.withLock({ inflight.insert(k).inserted }) else { return nil }
        defer { _ = lock.withLock { inflight.remove(k) } }
        await thumbGate.wait()
        defer { Task { await thumbGate.signal() } }
        guard let gen = await generator(nested, key: key, height: height) else { return nil }
        let last = max(.zero, nested.duration - nested.settings.frameRate.frameDuration)
        let at = min(Time(Double(q) * Self.quantum + Self.quantum / 2), last)
        guard let raw = try? await gen.image(at: at.cmTime).image, let img = ThumbnailCache.flatten(raw) else { return nil }
        memory.setObject(img, forKey: k as NSString, cost: img.bytesPerRow * img.height)
        lock.withLock { made += 1 }
        return img
    }

    /// One built composition per (content, height), reused for every tile.
    private func generator(_ nested: Project, key: String, height: Int) async -> AVAssetImageGenerator? {
        await generatorBox(nested, key: key, height: height)?.gen
    }

    private func generatorBox(_ nested: Project, key: String, height: Int) async -> GeneratorBox? {
        let gk = "\(key)-\(height)"
        let task: Task<GeneratorBox?, Never> = lock.withLock {
            if let i = generators.firstIndex(where: { $0.key == gk }) {
                let e = generators.remove(at: i)
                generators.insert(e, at: 0)
                return e.task
            }
            let t = Task<GeneratorBox?, Never> { await Self.makeGenerator(nested, height: height) }
            generators.insert((gk, t), at: 0)
            if generators.count > Self.maxGenerators { generators.removeLast(generators.count - Self.maxGenerators) }
            return t
        }
        return await task.value
    }

    static func renderSize(_ settings: ProjectSettings, height: Int) -> CGSize {
        let c = settings.canvasSize
        let aspect = c.height > 0 ? c.width / c.height : 16.0 / 9
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(Double(height) * aspect), height: even(Double(height)))
    }

    /// Same set-up as `OfflineRenderer.renderFrame` (export composition, SDR thumbnails, exact frames).
    private static func makeGenerator(_ nested: Project, height: Int) async -> GeneratorBox? {
        var p = nested
        p.settings.colorSpace = .sdr709
        let size = renderSize(p.settings, height: height)
        guard let built = try? await CompositionBuilder.build(project: p, purpose: .export, renderSize: size) else { return nil }
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = size
        return GeneratorBox(gen)
    }

    final class GeneratorBox: @unchecked Sendable {
        let gen: AVAssetImageGenerator
        init(_ g: AVAssetImageGenerator) { gen = g }
    }

    // MARK: Waveform

    /// Memory-cached mixed waveform (the previous content of `compound` while `key`'s is pending).
    public func cachedWaveform(key: String, compound: CompoundID? = nil) -> Waveform? {
        lock.withLock {
            if let w = waves[key] { return w }
            guard let id = compound, let prev = previous[id], prev != key else { return nil }
            return waves[prev]
        }
    }

    /// Waveform (100 peaks/s, nested-timeline time) of `nested`'s audio mix, through the export mixdown.
    public func waveform(_ nested: Project, key: String) async -> Waveform? {
        if let w = lock.withLock({ waves[key] }) { return w }
        let k = "wave-\(key)"
        guard nested.duration > .zero, lock.withLock({ inflight.insert(k).inserted }) else { return nil }
        defer { _ = lock.withLock { inflight.remove(k) } }
        await waveGate.wait()
        defer { Task { await waveGate.signal() } }
        guard let w = try? await Self.mixWaveform(nested) else { return nil }
        lock.withLock {
            waves[key] = w
            waveOrder.removeAll { $0 == key }
            waveOrder.append(key)
            while waveOrder.count > Self.maxWaves { waves[waveOrder.removeFirst()] = nil }
            made += 1
        }
        return w
    }

    /// Peak / RMS levels of the mixed audio of `project` (louder channel, 10 ms windows).
    public static func mixWaveform(_ project: Project) async throws -> Waveform {
        let per = Int(AudioFileIO.sampleRate) / Waveform.peaksPerSecond
        var peaks: [UInt8] = [], rms: [UInt8] = []
        var cur: Float = 0, n = 0, sq: Double = 0
        func flush() {
            peaks.append(UInt8(min(255, (min(1, cur) * 255).rounded())))
            rms.append(UInt8(min(255, ((sq / Double(max(n, 1))).squareRoot() * 255).rounded())))
        }
        try await AudioMixdown.stream(project) { b in
            let l = b[0], r = b[b.channels > 1 ? 1 : 0]
            for i in 0..<b.frames {
                let v = max(abs(l[i]), abs(r[i]))
                if v > cur { cur = v }
                sq += Double(v) * Double(v)
                n += 1
                if n == per { flush(); cur = 0; n = 0; sq = 0 }
            }
        }
        if n > 0 { flush() }
        return Waveform(peaks: peaks, rms: rms)
    }

    // MARK: State

    /// Requests running now (UI tests wait for 0) and outputs made so far.
    public var stats: (pending: Int, made: Int) { lock.withLock { (inflight.count, made) } }

    public func clearMemory() {
        memory.removeAllObjects()
        lock.withLock { waves.removeAll(); waveOrder.removeAll(); generators.removeAll() }
    }
}
