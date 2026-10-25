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

    /// What a lane hands to the mixer (tests / diagnostics, BUG-METALLIC-AUDIO): composition time of the first frame
    /// (NaN = no timestamp), first channel's samples AFTER the lane processing, sample rate, composition time one frame
    /// covers (what the gains used). Audio render thread: copy and return.
    public typealias TapCapture = @Sendable (_ time: Double, _ samples: UnsafeBufferPointer<Float>, _ sampleRate: Double,
                                             _ step: Double) -> Void
    /// Lane taps' time jumps while sounding (BUG-METALLIC-AUDIO probe, `PlaybackEngine.reportLaneAudio`).
    private var jumps = 0, worstJump = 0.0, worstJumpAt = 0.0
    func noteLaneJump(_ d: Double, at t: Double) {
        lock.withLock { jumps += 1; if abs(d) > abs(worstJump) { worstJump = d; worstJumpAt = t } }
    }
    /// Jumps since the last call: count, largest (seconds, negative = audio repeated), composition time of it.
    public func takeLaneJumps() -> (count: Int, worst: Double, at: Double) {
        lock.withLock {
            defer { jumps = 0; worstJump = 0; worstJumpAt = 0 }
            return (jumps, worstJump, worstJumpAt)
        }
    }
    private var _tapCapture: TapCapture?
    public var tapCapture: TapCapture? {
        get { lock.withLock { _tapCapture } }
        set { lock.withLock { _tapCapture = newValue } }
    }
}

/// Linear gain from `from` to `to` over `[start, end)` (composition / item time): one audio-mix volume ramp.
struct GainRamp: Equatable, Sendable {
    let start: Time, end: Time
    let from: Float, to: Float
}

/// The tap processor of one composition audio lane: routes each buffer to the live chain of the clip playing at that
/// composition time, then applies the lane's clip volumes. The tap runs AFTER the time-pitch stage ("post-effects"):
/// at a playback rate ≠ 1 a frame covers `rate / sampleRate` of composition time; a clip boundary inside a buffer
/// splits it.
final class LaneProcessor: AudioTapProcessor, @unchecked Sendable {
    struct Entry { let id: ClipID; let start: Double; let end: Double; let clip: Clip }
    let entries: [Entry]
    let state: AudioMixState
    /// Clip volumes (fades, keyframes, ducking, loudness): the lane's ramps, applied here sample by sample; silence
    /// outside them (what an audio mix does with its ramps + `setVolume(0)` at each clip end). nil = the audio mix
    /// applies them (no tap). PB-DROP: AVPlayer's mixer delivers each audio-mix ramp as a parameter event in its render
    /// slice, and when the output device runs at another rate than the composition (48 kHz media on built-in speakers at
    /// 44.1 kHz: 557-frame slices) many events land outside their slice and are dropped ("MCM ignoring event at invalid
    /// buffer offset 3556/557"): at a cut, the next clip's ramp was lost and its lane stayed at the 0 of the previous
    /// clip end — lanes silent or at the wrong level until the next seek. With no volume events nothing is dropped.
    let gains: [(start: Double, end: Double, from: Float, to: Float)]?
    private var gainIndex = 0
    /// Gain at the end of the last buffer: held over a buffer that has no timestamp.
    private var lastGain: Float = 1
    /// Composition time expected at the next buffer (routing of a buffer without timestamp).
    private var nextTime: Double?
    private var chains: [ClipID: LiveChain] = [:]
    private var seenVersion = -1
    private var sampleRate: Double = 48000
    private let scratch = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    private let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
    private var last: ClipID?
    /// The previous buffer was stamped and not silent (jump probe).
    private var lastSounded = false

    @inline(__always) static func hasSound(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Bool {
        for i in 0..<n where p[i] != 0 { return true }
        return false
    }

    /// BUG-METALLIC-AUDIO: in AVPlayer playback a post-effects tap's timestamp is the start of the PREVIOUS pull — the
    /// samples it carries begin one buffer later (4096 frames = 85 ms, measured on the content: lane output vs source,
    /// `MetallicAudioTests`). Read as is, the clip gains muted the first 85 ms of every clip after a gap or a cut on its
    /// lane and ran every fade / volume keyframe / live effect switch 85 ms late. Export (AVAssetReaderAudioMixOutput)
    /// stamps exactly. true = preview builds: the buffer's time is its stamp + its own span.
    let labelsLeadOneBuffer: Bool

    /// `skip`: timeline ranges the composition leaves out (quick cut preview) — entries are in composition time.
    init(clips: [Clip], state: AudioMixState, skip: SkipTimeMap = .identity, gains: [GainRamp]? = nil,
         labelsLeadOneBuffer: Bool = false) {
        self.labelsLeadOneBuffer = labelsLeadOneBuffer
        entries = clips.sorted { $0.start < $1.start }.flatMap { c in
            skip.kept(c.range).map { k in
                let s = skip.item(k.start)
                return Entry(id: c.id, start: s.seconds, end: (s + k.duration).seconds, clip: c)
            }
        }
        self.gains = gains?.sorted { $0.start < $1.start }.map { (start: $0.start.seconds, end: $0.end.seconds, from: $0.from, to: $0.to) }
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

    func reset() {
        for c in chains.values { c.reset() }
        last = nil; nextTime = nil; gainIndex = 0; lastSounded = false
        state.tapObserver?(.reset)
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: CMTime, duration: CMTime = .invalid) {
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
        // composition time per frame: 1 / sampleRate at rate 1, `rate` times that after the time-pitch stage
        let d = duration.isNumeric ? duration.seconds : 0
        let step = d > 0 ? d / Double(frames) : 1 / sampleRate
        let stamped = time.isNumeric
        let t0 = stamped ? time.seconds + (labelsLeadOneBuffer ? Double(frames) * step : 0) : nextTime ?? 0
        // probe: a stamped buffer with sound that does not follow the previous one (which had sound too) by < 0.5 s.
        // Seeks reset the taps; the buffers a paused item repeats are silent.
        let sounding = Self.hasSound(table[0], frames)
        if stamped, sounding, lastSounded, let e = nextTime, abs(t0 - e) > 0.001, abs(t0 - e) < 0.5 { state.noteLaneJump(t0 - e, at: t0) }
        lastSounded = sounding && stamped
        nextTime = t0 + Double(frames) * step
        routeLive(block, frames: frames, from: t0, step: step)
        if gains != nil {
            if stamped { applyGains(channels: channels, frames: frames, from: t0, step: step) } else { hold(lastGain, channels: channels, frames: frames) }
        }
        if let capture = state.tapCapture {
            capture(stamped ? t0 : .nan, UnsafeBufferPointer(start: table[0], count: frames), sampleRate, step)
        }
    }

    /// Multiplies the buffer by the lane's gain curve (linear inside each ramp, 0 outside every ramp).
    private func applyGains(channels: Int, frames: Int, from t0: Double, step dt: Double) {
        guard let gains else { return }
        // ramps are sorted and disjoint; time mostly moves forward, so resume the search where the last buffer ended
        if gainIndex >= gains.count || (gainIndex > 0 && gains[gainIndex - 1].end > t0) { gainIndex = 0 }
        var offset = 0
        /// Frames from `offset` that `span` seconds cover (≥ 1, at most the rest of the buffer; `span` may be infinite).
        func cover(_ span: Double) -> Int {
            let rest = frames - offset, n = (span / dt).rounded(.up)
            return n >= Double(rest) ? rest : max(1, Int(n))
        }
        while offset < frames {
            let t = t0 + Double(offset) * dt
            while gainIndex < gains.count, gains[gainIndex].end <= t + 1e-9 { gainIndex += 1 }
            let n: Int, g0: Float, step: Float
            if gainIndex < gains.count, gains[gainIndex].start <= t + 1e-9 {
                let r = gains[gainIndex]
                let len = max(r.end - r.start, 1e-9)
                n = cover(r.end - t)
                g0 = r.from + (r.to - r.from) * Float((t - r.start) / len)
                step = (r.to - r.from) * Float(dt / len)
            } else {
                // silence until the next ramp (or the end of the buffer)
                let next = gainIndex < gains.count ? gains[gainIndex].start : .infinity
                n = cover(next - t)
                g0 = 0; step = 0
            }
            lastGain = g0 + step * Float(n - 1)
            if !(step == 0 && g0 == 1) {
                for c in 0..<channels {
                    let p = table[c] + offset
                    var g = g0
                    for i in 0..<n { p[i] *= g; g += step }
                }
            }
            offset += n
        }
    }

    /// A buffer without timestamp (rare: around a seek or an item start) keeps the last gain rather than guessing a time.
    private func hold(_ g: Float, channels: Int, frames: Int) {
        guard g != 1 else { return }
        for c in 0..<channels { let p = table[c]; for i in 0..<frames { p[i] *= g } }
    }

    private func routeLive(_ block: AudioBlock, frames: Int, from t0: Double, step dt: Double) {
        var t = t0
        var offset = 0
        while offset < frames {
            guard let i = entries.firstIndex(where: { $0.end > t + 1e-6 }) else { break }
            let e = entries[i]
            if e.start > t + 1e-6 {
                // gap before the next clip: skip those frames
                let gap = Int(((e.start - t) / dt).rounded(.up))
                offset += gap; t += Double(gap) * dt
                continue
            }
            let n = min(frames - offset, max(1, Int(((e.end - t) / dt).rounded(.up))))
            if last != e.id { chains[e.id]?.reset(); last = e.id }
            if let chain = chains[e.id], !chain.isEmpty {
                chain.process(block.slice(offset, n, scratch: scratch))
            }
            offset += n
            t += Double(n) * dt
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
