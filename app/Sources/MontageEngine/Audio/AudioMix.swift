@preconcurrency import AVFoundation
import Foundation
import os
import MontageCore

/// Live audio parameters shared with the audio-mix taps (the audio analogue of `RenderState`).
/// `update(project:)` runs on every edit; taps read the latest live chain of their clip at each buffer, so EQ / voice
/// filter / channel edits are heard immediately without rebuilding the composition.
public final class AudioMixState: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [ClipID: [LiveNode]] = [:]
    private var version = 0

    public init(project: Project? = nil) { if let project { update(project: project) } }

    /// Live chains per track (recomputed only for tracks whose clips changed).
    private let perTrack = TrackMemo<[ClipID: [LiveNode]]> { clips in
        var m: [ClipID: [LiveNode]] = [:]
        for c in clips where c.mediaID != nil {
            let plan = ClipAudioPlan.make(c)
            if plan.hasLive { m[c.id] = plan.live }
        }
        return m
    }

    public func update(project: Project) {
        var m: [ClipID: [LiveNode]] = [:]
        for t in perTrack.values(project.timeline.tracks) { m.merge(t) { a, _ in a } }
        lock.withLock { if m != live { live = m; version &+= 1 } }
    }

    var currentVersion: Int { lock.withLock { version } }
    func liveChain(_ id: ClipID) -> [LiveNode] { lock.withLock { live[id] ?? [] } }

    /// What the lane taps see (tests / diagnostics): called on the audio render thread, keep it cheap.
    public enum TapEvent: Sendable { case prepare, reset, buffer(time: Double, frames: Int) }
    private var _tapObserver: (@Sendable (TapEvent) -> Void)?
    public var tapObserver: (@Sendable (TapEvent) -> Void)? {
        get { lock.withLock { _tapObserver } }
        set { lock.withLock { _tapObserver = newValue } }
    }
}

/// The tap processor of one composition audio lane: routes each buffer to the live chain of the clip playing at that
/// composition time. The tap runs AFTER the time-pitch stage ("post-effects"), so frames are composition-rate; a clip
/// boundary inside a buffer splits it.
final class LaneProcessor: AudioTapProcessor, @unchecked Sendable {
    struct Entry { let id: ClipID; let start: Double; let end: Double; let clip: Clip }
    let entries: [Entry]
    let state: AudioMixState
    private var chains: [ClipID: LiveChain] = [:]
    private var seenVersion = -1
    private var sampleRate: Double = 48000
    private let scratch = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    private let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    private var last: ClipID?

    /// `skip`: timeline ranges the composition leaves out (quick cut preview) — entries are in composition time.
    init(clips: [Clip], state: AudioMixState, skip: SkipTimeMap = .identity) {
        entries = clips.sorted { $0.start < $1.start }.flatMap { c in
            skip.kept(c.range).map { k in
                let s = skip.item(k.start)
                return Entry(id: c.id, start: s.seconds, end: (s + k.duration).seconds, clip: c)
            }
        }
        self.state = state
        for e in entries { chains[e.id] = LiveChain(state.liveChain(e.id), sampleRate: 48000) }
        seenVersion = state.currentVersion
    }
    deinit { scratch.deallocate(); table.deallocate() }

    func prepare(sampleRate: Double, channels: Int, maxFrames: Int) {
        self.sampleRate = sampleRate
        for c in chains.values { c.prepare(sampleRate: sampleRate); c.reset() }
        state.tapObserver?(.prepare)
    }

    func reset() { for c in chains.values { c.reset() }; last = nil; state.tapObserver?(.reset) }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: CMTime) {
        guard frames > 0, buffers.count > 0 else { return }
        if let o = state.tapObserver { o(.buffer(time: time.isNumeric ? time.seconds : .nan, frames: frames)) }
        let v = state.currentVersion
        if v != seenVersion {
            seenVersion = v
            for e in entries { chains[e.id]?.update(state.liveChain(e.id)) }
        }
        let channels = min(buffers.count, 8)
        for c in 0..<channels { table[c] = buffers[c].mData!.assumingMemoryBound(to: Float.self) }
        let block = AudioBlock(channels: channels, frames: frames, pointers: table)
        var t = time.isNumeric ? time.seconds : 0
        var offset = 0
        while offset < frames {
            guard let i = entries.firstIndex(where: { $0.end > t + 1e-6 }) else { break }
            let e = entries[i]
            if e.start > t + 1e-6 {
                // gap before the next clip: skip those frames
                let gap = Int(((e.start - t) * sampleRate).rounded(.up))
                offset += gap; t = e.start
                continue
            }
            let rate = 1.0   // post-effects tap: frames are composition-rate (after time-pitch)
            let n = min(frames - offset, max(1, Int(((e.end - t) * sampleRate * rate).rounded(.up))))
            if last != e.id { chains[e.id]?.reset(); last = e.id }
            if let chain = chains[e.id], !chain.isEmpty {
                chain.process(block.slice(offset, n, scratch: scratch))
            }
            offset += n
            t += Double(n) / sampleRate / rate
        }
    }
}

/// "Auto ducking": lowers a clip while OTHER audible, non-ducked clips are active (voice over music). The trigger is the
/// waveform peak envelope (100 Hz) of those clips; attack 60 ms, release 350 ms. Result: gain multiplier over time.
public enum Ducking {
    public struct Envelope: Sendable {
        /// Timeline start of the samples, step 20 ms.
        public let start: Time
        public let step: Double
        public let gains: [Float]
        public func gain(at t: Time) -> Float {
            guard !gains.isEmpty else { return 1 }
            let x = (t - start).seconds / step
            let i = max(0, min(gains.count - 1, Int(x)))
            let j = min(gains.count - 1, i + 1)
            let f = Float(min(max(x - Double(i), 0), 1))
            return gains[i] * (1 - f) + gains[j] * f
        }
    }

    static let threshold = 0.06   // ≈ −24 dBFS peak

    /// Gain envelope for `clip` (which has `audio.ducking`), or nil if nothing triggers it.
    public static func envelope(for clip: Clip, in project: Project, waveforms: [MediaID: Waveform]) -> Envelope? {
        guard let duck = clip.audio.ducking else { return nil }
        let triggers = project.timeline.tracks.filter { project.timeline.isAudible($0) }.flatMap(\.clips).filter { c in
            (c.id != clip.id && c.audio.ducking == nil && c.audio.isAudible && c.isEnabled
                && c.mediaID.flatMap { waveforms[$0] } != nil && c.range.intersection(clip.range) != nil)
        }
        guard !triggers.isEmpty else { return nil }
        let step = 0.02
        let n = Int((clip.duration.seconds / step).rounded(.up)) + 1
        let floorGain = Float(pow(10, min(0, duck.amountDB) / 20))
        let att = Float(1 - exp(-step / 0.06)), rel = Float(1 - exp(-step / 0.35))
        var env: Float = 0
        var out = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let t = clip.start + Time(Double(i) * step)
            var active = false
            for c in triggers where c.range.contains(t) {
                let s = c.sourceTime(at: t).seconds
                if let w = c.mediaID.flatMap({ waveforms[$0] }), w.peak(from: s - 0.03, to: s + 0.03) * c.audio.volume > threshold { active = true; break }
            }
            let target: Float = active ? 1 : 0
            env += (target - env) * (target > env ? att : rel)
            out[i] = 1 - (1 - floorGain) * env
        }
        return Envelope(start: clip.start, step: step, gains: out)
    }

    /// Loads (or computes) waveforms for every audible media in the project.
    public static func waveforms(for project: Project) async -> [MediaID: Waveform] {
        guard project.timeline.allClips.contains(where: { $0.audio.ducking != nil }) else { return [:] }
        var out: [MediaID: Waveform] = [:]
        for a in project.media where a.hasAudio {
            if let w = WaveformCache.shared.cached(a) { out[a.id] = w; continue }
            if let w = await WaveformCache.shared.waveform(a) { out[a.id] = w; continue }
            if let w = try? await WaveformCache.compute(a.url) { out[a.id] = w }
        }
        return out
    }
}
