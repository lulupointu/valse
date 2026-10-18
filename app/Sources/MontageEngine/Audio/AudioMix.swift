@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Live audio parameters shared between the editor (writer, main actor) and the audio taps (readers, audio thread).
/// Holds each clip's live chain spec so EQ / voice-filter / channel edits are heard without rebuilding the
/// composition (like `RenderState` for video).
public final class AudioMixState: @unchecked Sendable {
    private let lock = NSLock()
    private var specs: [ClipID: [LiveNode]] = [:]
    private var version = 0

    public init(project: Project? = nil) { if let project { update(project: project) } }

    public func update(project: Project) {
        var next: [ClipID: [LiveNode]] = [:]
        for t in project.timeline.tracks {
            for c in t.clips where c.mediaID != nil {
                let live = ClipAudioPlan.make(c.audio).live
                if !live.isEmpty { next[c.id] = live }
            }
        }
        lock.withLock { if next != specs { specs = next; version &+= 1 } }
    }

    /// (spec, version) — called on the audio thread; the lock is only held for a dictionary lookup.
    func spec(_ id: ClipID) -> ([LiveNode], Int) { lock.withLock { (specs[id] ?? [], version) } }
    var currentVersion: Int { lock.withLock { version } }
}

/// Tap processor of one composition audio lane: finds the clip playing at each block and runs its live chain.
/// The tap is installed pre-effects, so it sees source-rate audio stamped with composition time (before the
/// time-pitch stage and the mix volume ramps).
final class LaneProcessor: AudioTapProcessor, @unchecked Sendable {
    struct Entry { let id: ClipID; let start: Double; let end: Double; let rate: Double }
    private let entries: [Entry]
    private let state: AudioMixState
    private var chains: [ClipID: LiveChain] = [:]
    private var seen: [ClipID: Int] = [:]
    private var sampleRate: Double = 48000
    private var cursor = 0
    private let scratch = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    private let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)

    init(clips: [Clip], state: AudioMixState) {
        entries = clips.map { Entry(id: $0.id, start: $0.start.seconds, end: $0.end.seconds, rate: max($0.speed.averageRate, 0.01)) }
            .sorted { $0.start < $1.start }
        self.state = state
        for e in entries { chains[e.id] = LiveChain(state.spec(e.id).0, sampleRate: sampleRate); seen[e.id] = state.spec(e.id).1 }
    }
    deinit { scratch.deallocate(); table.deallocate() }

    func prepare(sampleRate: Double, channels: Int, maxFrames: Int) {
        self.sampleRate = sampleRate
        for c in chains.values { c.prepare(sampleRate: sampleRate) }
    }

    func reset() { for c in chains.values { c.reset() } }

    private func entryIndex(at t: Double) -> Int? {
        if cursor < entries.count, entries[cursor].start <= t + 1e-6, t < entries[cursor].end { return cursor }
        var lo = 0, hi = entries.count
        while lo < hi { let m = (lo + hi) / 2; if entries[m].end <= t { lo = m + 1 } else { hi = m } }
        guard lo < entries.count, entries[lo].start <= t + 1e-6 else { return nil }
        cursor = lo
        return lo
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: CMTime) {
        guard !entries.isEmpty, frames > 0, time.isNumeric else { return }
        let channels = min(buffers.count, 8)
        for c in 0..<channels {
            guard let d = buffers[c].mData else { return }
            table[c] = d.assumingMemoryBound(to: Float.self)
        }
        let block = AudioBlock(channels: channels, frames: frames, pointers: table)
        var t = time.seconds
        var offset = 0
        while offset < frames {
            guard let idx = entryIndex(at: t) else {
                // gap: advance to the next clip start, if it falls inside this block
                guard let next = entries.first(where: { $0.start > t }) else { return }
                let skip = Int(((next.start - t) * sampleRate).rounded(.up))
                offset += max(1, skip); t = next.start
                continue
            }
            let e = entries[idx]
            // frames until the clip ends (source-rate frames: composition seconds × speed)
            let left = Int(((e.end - t) * sampleRate * e.rate).rounded(.up))
            let n = min(frames - offset, max(1, left))
            run(e.id, block.slice(offset, n, scratch: scratch))
            offset += n
            t += Double(n) / (sampleRate * e.rate)
        }
    }

    private func run(_ id: ClipID, _ b: AudioBlock) {
        guard let chain = chains[id] else { return }
        let (spec, v) = state.spec(id)
        if seen[id] != v { chain.update(spec); seen[id] = v }
        if !chain.isEmpty { chain.process(b) }
    }
}

/// Ducking (AU-017): lowers a clip while other audible clips (voice) are active. Computed at build time from the
/// cached waveform peaks of the triggering media, then folded into the clip's volume ramps (identical in preview and
/// export).
enum Ducking {
    static let step = 0.05
    static let threshold = 0.06        // ≈ −24 dBFS peak
    static let attack = 0.08, release = 0.5

    /// Gain curve (step-sampled, clip-local) for `clip`, or nil if it doesn't duck.
    static func curve(for clip: Clip, in project: Project, waveforms: [MediaID: Waveform]) -> [Double]? {
        guard let duck = clip.audio.ducking else { return nil }
        let floorGain = pow(10, min(0, duck.amountDB) / 20)
        let n = max(1, Int((clip.duration.seconds / step).rounded(.up)) + 1)
        // trigger activity
        var active = [Bool](repeating: false, count: n)
        for t in project.timeline.tracks where !t.isMuted {
            for o in t.clips where o.id != clip.id && o.audio.ducking == nil && o.audio.isAudible && o.isEnabled {
                guard let mid = o.mediaID, let w = waveforms[mid], o.range.intersection(clip.range) != nil else { continue }
                for i in 0..<n {
                    let tl = clip.start + Time(Double(i) * step)
                    guard o.range.contains(tl) else { continue }
                    let s = o.sourceTime(at: tl).seconds
                    if w.peak(from: s - step / 2, to: s + step / 2) * o.audio.volume > threshold { active[i] = true }
                }
            }
        }
        // attack / release smoothing
        var out = [Double](repeating: 1, count: n)
        var g = 1.0
        let ka = 1 - exp(-step / attack), kr = 1 - exp(-step / release)
        for i in 0..<n {
            let target = active[i] ? floorGain : 1
            g += (target - g) * (target < g ? ka : kr)
            out[i] = g
        }
        return out.allSatisfy({ $0 > 0.999 }) ? nil : out
    }
}
