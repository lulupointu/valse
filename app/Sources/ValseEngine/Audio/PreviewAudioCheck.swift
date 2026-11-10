@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import ValseCore

/// Measurements of `PreviewAudio` on what it ENQUEUES (the mixed chunks handed to the renderer, labelled by their
/// presentation time), against the source content (BUG-CUT-AUDIO-HOLE phase A). The same code runs in the unit tests
/// (PreviewAudioTests, which assert on the numbers) and in a release app on macOS 13 (`Valse --preview-audio-check
/// <dir>`, scripts/audio_probe.sh --vm --app): the renderer output itself is not captured (Core Audio process taps need
/// macOS 14.2; part 5 measured renderer output vs its clock at −7 ms at 1×, a fixed device latency).
/// Media: 3 ms noise bursts at irregular times whose first sample is 0.8 after silence (onsets exact to the sample),
/// and white noise (gains, fades, live effects), written to `dir`.
public enum PreviewAudioCheck {
    static let sr = PreviewAudio.sampleRate

    // MARK: - Media and projects

    /// Burst start times (s) in the source: irregular 120-320 ms apart (a periodic train aliases a lead of a period).
    public static let burstTimes: [Double] = {
        var t = 0.05, seed: UInt64 = 12345, out: [Double] = []
        while t < 7.9 {
            out.append(t)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            t += 0.12 + Double((seed >> 33) % 1000) / 1000 * 0.2
        }
        return out
    }()

    public static func burstSignal(rate: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(8 * rate))
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for b in burstTimes {
            let i0 = Int((b * rate).rounded())
            for i in i0..<(i0 + Int(0.03 * rate)) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                s[i] = i == i0 ? 0.8 : Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.5
            }
        }
        return s
    }

    static func noiseSignal(seconds: Double) -> [Float] {
        var s: UInt64 = 7 &* 0x9E3779B97F4A7C15 | 1
        var out = [Float](repeating: 0, count: Int(seconds * sr))
        let scale: Double = 1 / Double(UInt64(1) << 53)
        for i in out.indices {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let u: Double = Double(s >> 11) * scale
            out[i] = Float((u * 2 - 1) * 0.2 * 1.7320508)
        }
        return out
    }

    /// Writes `name` once (temp file + atomic rename: the media cache rule).
    static func file(_ name: String, in dir: URL, rate: Double, _ make: () -> [Float]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try AudioFileIO.write(AudioBuffer([make()], sampleRate: rate), to: tmp, format: .wav24)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }
    public static func burstFile(rate: Double = 48000, in dir: URL) throws -> URL {
        try file("preview-audio-bursts-\(Int(rate)).wav", in: dir, rate: rate) { burstSignal(rate: rate) }
    }
    public static func noiseFile(in dir: URL) throws -> URL {
        try file("preview-audio-noise.wav", in: dir, rate: sr) { noiseSignal(seconds: 6) }
    }

    static func emptyProject() -> Project {
        Project(name: "PreviewAudioCheck", settings: ProjectSettings(canvasSize: Size2(320, 180), frameRate: .fps30, backgroundColor: .black))
    }

    @discardableResult
    static func add(_ url: URL, at start: Time, duration: Time? = nil, target: InsertTarget = .automatic, to p: inout Project) async throws -> ClipID {
        var asset = try await MediaProbe.probe(url)
        if let existing = p.media.first(where: { $0.contentHash == asset.contentHash }) { asset = existing } else { p.media.append(asset) }
        var clip = TimelineOps.makeClip(for: asset, at: start)
        if let duration { clip.duration = duration }
        try TimelineOps.insert(clip, into: &p, target: target)
        return clip.id
    }

    /// A bursts clip at 1 s (6 s of source from 0) at constant `speed` (a clip after a 1 s gap).
    public static func burstProject(sourceRate: Double = 48000, speed: Double = 1, dir: URL) async throws -> (Project, Clip) {
        var p = emptyProject()
        let id = try await add(try burstFile(rate: sourceRate, in: dir), at: Time(1.0), duration: Time(6.0), to: &p)
        if speed != 1 { try TimelineOps.setSpeed(id, .constant(speed), in: &p.timeline) }
        return (p, p.timeline.clip(id)!)
    }

    /// The owner's cut: main track A [0, 2) fading out 0.3 s | B [2, 4) fading in 0.3 s (noise), and a bursts clip at
    /// 2.5 s on another track (after a gap, with a 0.1 s fade-in).
    public static func cutProject(dir: URL) async throws -> Project {
        var p = emptyProject()
        let noise = try noiseFile(in: dir)
        let a = try await add(noise, at: .zero, duration: Time(2.0), to: &p)
        let main = p.timeline.tracks[p.timeline.locate(a)!.track].id
        let b = try await add(noise, at: Time(2.0), duration: Time(2.0), target: .track(main), to: &p)
        p.timeline[clip: a]?.audio.fadeOut = Time(0.3)
        p.timeline[clip: b]?.sourceStart = Time(2.5)
        p.timeline[clip: b]?.audio.fadeIn = Time(0.3)
        let c = try await add(try burstFile(in: dir), at: Time(2.5), duration: Time(1.5), target: .newTrack, to: &p)
        p.timeline[clip: c]?.audio.fadeIn = Time(0.1)
        return p
    }

    public static func build(_ project: Project, state: AudioMixState) async throws -> BuiltComposition {
        try await CompositionBuilder.build(project: project, purpose: .preview, audioState: state, audioTaps: false,
                                           sources: { MediaSourceChoice(video: $0.url, audio: $0.url) })
    }

    // MARK: - Recording

    /// Every enqueued chunk (label, host time when enqueued, left / right).
    public final class Recording: @unchecked Sendable {
        public struct Chunk: Sendable { public let time: Double; public let host: Double; public let left: [Float]; public let right: [Float] }
        private let lock = NSLock()
        private var chunks: [Chunk] = []
        public init() {}
        public var snapshot: [Chunk] { lock.withLock { chunks } }
        public func clear() { lock.withLock { chunks = [] } }
        public var hook: PreviewAudio.Capture {
            { [weak self] t, s in
                let n = s.count / 2
                var l = [Float](repeating: 0, count: n), r = l
                for i in 0..<n { l[i] = s[2 * i]; r[i] = s[2 * i + 1] }
                let c = Chunk(time: t, host: CACurrentMediaTime(), left: l, right: r)
                self?.lock.withLock { self?.chunks.append(c) }
            }
        }
        /// Labels that do not continue the previous chunk (s): a flush / seek / swap shows here.
        public var discontinuities: [Double] {
            let c = snapshot
            return zip(c, c.dropFirst()).compactMap { a, b in
                let end = PreviewAudioLanes.frame(a.time) + a.left.count
                return PreviewAudioLanes.frame(b.time) == end ? nil : b.time
            }
        }
        /// The chunks laid out by label (later chunks overwrite earlier ones), from the first label: (first frame, left, right).
        public func stream(from t0: Double = -.infinity) -> (start: Int, left: [Float], right: [Float]) {
            let c = snapshot.filter { $0.time >= t0 - 1e-9 }
            guard let first = c.map({ PreviewAudioLanes.frame($0.time) }).min(),
                  let last = c.map({ PreviewAudioLanes.frame($0.time) + $0.left.count }).max() else { return (0, [], []) }
            var l = [Float](repeating: 0, count: last - first), r = l
            for ch in c {
                let o = PreviewAudioLanes.frame(ch.time) - first
                for i in ch.left.indices { l[o + i] = ch.left[i]; r[o + i] = ch.right[i] }
            }
            return (first, l, r)
        }
    }

    // MARK: - Playing

    /// Polls `cond` every 2 ms until true or `timeout` (wall seconds). Returns whether it became true.
    @discardableResult
    public static func wait(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let t0 = CACurrentMediaTime()
        while !cond() {
            if CACurrentMediaTime() - t0 > timeout { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    public struct CheckError: Error, CustomStringConvertible { public let description: String }

    /// Loads `project` at `seek`, plays at `rate` until the clock reaches `until` (bounded by `timeout` wall seconds).
    /// `during` runs once the clock moves (edits, pauses). Returns the recording and the engine (paused).
    public static func play(_ project: Project, seek: Double, until: Double, rate: Double = 1, timeout: Double = 30,
                            state: AudioMixState? = nil,
                            during: ((PreviewAudio) async throws -> Void)? = nil) async throws -> (Recording, PreviewAudio) {
        let state = state ?? AudioMixState()
        let built = try await build(project, state: state)
        let audio = PreviewAudio(audioState: state)
        let rec = Recording()
        audio.capture = rec.hook
        audio.load(built, at: seek)
        audio.play(rate: rate)
        guard await wait(timeout, { audio.currentTime > seek + 0.001 }) else {
            audio.stop()
            throw CheckError(description: "the clock never started (seek \(seek), \(audio.stats))")
        }
        try await during?(audio)
        let ok = await wait(timeout) { audio.currentTime >= until }
        audio.pause()
        guard ok else { audio.stop(); throw CheckError(description: "the clock did not reach \(until) (at \(audio.currentTime))") }
        return (rec, audio)
    }

    // MARK: - Analysis

    /// Burst onsets in the enqueued stream (frame), each against the burst's expected frame: lead = expected − found
    /// (frames; positive = the content comes later than its label). Speed 1 clips only.
    public static func onsetLeads(_ rec: Recording, clip: Clip, sourceRate: Double = 48000, from t0: Double = -.infinity) -> [Double] {
        let s = rec.stream(from: t0)
        var out: [Double] = []
        var calm = 0
        let start = clip.start.seconds, src0 = clip.sourceStart.seconds
        for (i, v) in s.left.enumerated() {
            if abs(v) > 0.4 {
                if calm >= 240 {
                    let f = Double(s.start + i)
                    // expected: the burst's first source sample, at its composition time
                    let near = burstTimes.map { b -> Double in
                        let srcSample = (b * sourceRate).rounded() / sourceRate
                        return (start + srcSample - src0) * sr
                    }.min { abs($0 - f) < abs($1 - f) }
                    if let e = near, abs(e - f) < 0.02 * sr, e > start * sr + 240, e < clip.end.seconds * sr - 240 { out.append(e - f) }
                }
                calm = 0
            } else if abs(v) < 0.1 { calm += 1 } else { calm = 0 }   // (resampled media rings ahead of an onset)
        }
        return out
    }

    /// Lead (ms, positive = content later than its label) from 1 ms energy envelopes, enqueued stream vs the source
    /// mapped through the clip's constant speed (robust to the spectral stretch of scaled segments), and the correlation.
    public static func envelopeLead(_ rec: Recording, clip: Clip, from t0: Double) -> (ms: Double, corr: Double) {
        let s = rec.stream(from: t0)
        let src = burstSignal(rate: sr)
        let speed = clip.speed.averageRate
        let a = max(Double(s.start) / sr, clip.start.seconds + 0.1), b = min(Double(s.start + s.left.count) / sr, clip.end.seconds - 0.1)
        let bins = Int((b - a) * 1000)
        guard bins > 200 else { return (.nan, 0) }
        var got = [Double](repeating: 0, count: bins), want = got
        for k in 0..<bins {
            let f0 = Int(((a + Double(k) / 1000) * sr).rounded()) - s.start
            for i in f0..<(f0 + 48) where i >= 0 && i < s.left.count { got[k] += Double(s.left[i] * s.left[i]) }
            let t = a + Double(k) / 1000
            let s0 = Int(((clip.sourceStart.seconds + (t - clip.start.seconds) * speed) * sr).rounded())
            let s1 = Int(((clip.sourceStart.seconds + (t + 0.001 - clip.start.seconds) * speed) * sr).rounded())
            for j in max(0, s0)..<min(src.count, max(s0, s1)) { want[k] += Double(src[j] * src[j]) }
        }
        var best = (ms: 0.0, corr: -1.0)
        for lag in -60...60 {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for k in 0..<bins where k + lag >= 0 && k + lag < bins { xy += got[k] * want[k + lag]; xx += got[k] * got[k]; yy += want[k + lag] * want[k + lag] }
            let c = xx > 0 && yy > 0 ? xy / (xx * yy).squareRoot() : 0
            if c > best.corr { best = (Double(lag), c) }
        }
        return best
    }

    /// The enqueued stream over [from, to) against the export mixdown of the same project (exact labels, same gains):
    /// largest |difference| at lag 0, and the lag (frames, ±48) with the smallest mean |difference|.
    public static func compareToExport(_ rec: Recording, project: Project, from: Double, to: Double) async throws -> (maxDiff: Float, lag: Int) {
        let export = try await AudioMixdown.render(project, range: TimeRange(start: .zero, duration: Time(to + 0.1)))
        let s = rec.stream()
        let f0 = PreviewAudioLanes.frame(from), f1 = PreviewAudioLanes.frame(to)
        guard s.start <= f0, s.start + s.left.count >= f1, export.frames >= f1 + 48 else {
            throw CheckError(description: "recording [\(Double(s.start) / sr), \(Double(s.start + s.left.count) / sr)) does not cover [\(from), \(to))")
        }
        let el = export.channel(0), er = export.channel(1)
        var maxDiff: Float = 0
        for f in f0..<f1 { maxDiff = max(maxDiff, abs(s.left[f - s.start] - el[f]), abs(s.right[f - s.start] - er[f])) }
        var best = (lag: 0, cost: Float.infinity)
        for lag in -48...48 {
            var cost: Float = 0
            for f in stride(from: f0 + 48, to: f1 - 48, by: 3) { cost += abs(s.left[f - s.start] - el[f + lag]) }
            if cost < best.cost { best = (lag, cost) }
        }
        return (maxDiff, best.lag)
    }

    // MARK: - Scenarios (shared by the unit tests and the macOS 13 run)

    public struct Timing: Sendable { public var leads: [Double]; public var envelopeMs = Double.nan; public var corr = 0.0; public var clockRate = Double.nan; public var debug = "" }

    /// Bursts clip, seek 1.3, play to 2.6 at `rate`: onset leads (speed 1) or envelope lead (scaled).
    public static func timing(sourceRate: Double = 48000, speed: Double = 1, rate: Double = 1, dir: URL) async throws -> Timing {
        let (p, clip) = try await burstProject(sourceRate: sourceRate, speed: speed, dir: dir)
        var marks: [(Double, Double)] = []
        let (rec, audio) = try await play(p, seek: 1.3, until: min(2.6, clip.end.seconds - 0.2), rate: rate) { a in
            marks.append((CACurrentMediaTime(), a.currentTime))
        }
        marks.append((CACurrentMediaTime(), audio.currentTime))
        audio.stop()
        var t = Timing(leads: speed == 1 ? onsetLeads(rec, clip: clip, sourceRate: sourceRate) : [])
        if speed != 1 { (t.envelopeMs, t.corr) = envelopeLead(rec, clip: clip, from: 1.3) }
        let s = rec.stream()
        let peak = s.left.map(abs).max() ?? 0
        let firstLoud = s.left.firstIndex { abs($0) > 0.4 }.map { Double(s.start + $0) / sr } ?? .nan
        t.debug = "stream [\(Double(s.start) / sr), +\(Double(s.left.count) / sr)) peak \(peak) first>0.4 at \(firstLoud)"
        if marks.count == 2, marks[1].0 > marks[0].0 { t.clockRate = (marks[1].1 - marks[0].1) / (marks[1].0 - marks[0].0) }
        return t
    }

    public struct SeekResult: Sendable { public var toFirstChunkMs: [Double] = []; public var toClockMs: [Double] = []; public var leads: [Double] = [] }

    /// Seeks while playing (each one waits for the clock to move, then 80 ms): seek → first enqueued chunk, seek → moving clock.
    public static func seekLatency(count: Int = 6, dir: URL) async throws -> SeekResult {
        let (p, clip) = try await burstProject(dir: dir)
        var r = SeekResult()
        let (rec, audio) = try await play(p, seek: 1.2, until: 1.3) { _ in }
        audio.play()
        for k in 0..<count {
            let target = 1.5 + Double(k) * 0.53
            rec.clear()
            let t0 = CACurrentMediaTime()
            audio.seek(to: target)
            guard await wait(10, { audio.currentTime > target + 0.0005 }) else { throw CheckError(description: "seek \(k): no clock") }
            let moved = CACurrentMediaTime() - (audio.currentTime - target)
            r.toClockMs.append((moved - t0) * 1000)
            let s = audio.stats
            if s.firstChunkAfterSeek > 0 { r.toFirstChunkMs.append((s.firstChunkAfterSeek - t0) * 1000) }
            _ = await wait(1) { audio.currentTime > target + 0.25 }
            r.leads += onsetLeads(rec, clip: clip, from: target)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        audio.stop()
        return r
    }

    public struct StormResult: Sendable { public var seeksPerformed = 0; public var settledMs = 0.0; public var readersWhilePlaying = 0; public var readersAfter = 0; public var leads: [Double] = []; public var released = false }

    /// 12 seeks 80 ms apart while playing, without waiting: then the clock must run from the last target with exact
    /// labels, one reader open, and the engine must deallocate once dropped.
    public static func seekStorm(dir: URL) async throws -> StormResult {
        let (p, clip) = try await burstProject(dir: dir)
        var r = StormResult()
        weak var released: PreviewAudio?
        var readersAfterStop = 0
        do {
            let (rec, audio) = try await play(p, seek: 1.2, until: 1.3) { _ in }
            audio.play()
            let before = audio.stats.seeks
            var last = 0.0, t0 = 0.0
            for k in 0..<12 {
                last = 1.5 + (Double(k) * 0.31).truncatingRemainder(dividingBy: 3.5)
                if k == 11 { rec.clear(); t0 = CACurrentMediaTime() }
                audio.seek(to: last)
                if k < 11 { try await Task.sleep(nanoseconds: 80_000_000) }
            }
            // the last seek: time to a moving clock, then 0.8 s of audio checked
            guard await wait(10, { audio.currentTime > last + 0.0005 }) else { throw CheckError(description: "storm: clock stuck at \(audio.currentTime)") }
            r.settledMs = (CACurrentMediaTime() - t0 - (audio.currentTime - last)) * 1000
            _ = await wait(10) { audio.currentTime > last + 0.8 }
            r.seeksPerformed = audio.stats.seeks - before
            r.readersWhilePlaying = audio.openReaderCount
            r.leads = onsetLeads(rec, clip: clip, from: last)
            audio.stop()
            _ = await wait(5) { audio.openReaderCount == 0 }
            readersAfterStop = audio.openReaderCount
            released = audio
        }
        _ = await wait(5) { released == nil }
        r.released = released == nil
        r.readersAfter = readersAfterStop
        return r
    }

    public struct LiveEditResult: Sendable { public var heardAfterMs = Double.nan; public var ratioBefore = Double.nan; public var ratioAfter = Double.nan }

    /// Noise clip; while playing, an EQ of −12 dB on every band reaches the AudioMixState: how long (media time) after
    /// the clock at the edit the enqueued audio changes (what is heard, since the renderer plays labels at the clock).
    public static func liveEdit(dir: URL) async throws -> LiveEditResult {
        var p = emptyProject()
        let id = try await add(try noiseFile(in: dir), at: .zero, duration: Time(6), to: &p)
        let state = AudioMixState(project: p)
        let reference = try await AudioMixdown.render(p, range: TimeRange(start: .zero, duration: Time(3))).channel(0)
        var editClock = 0.0
        let (rec, audio) = try await play(p, seek: 0.5, until: 2.2, state: state) { a in
            _ = await wait(10) { a.currentTime > 1.0 }
            var edited = p
            edited.timeline[clip: id]?.audio.eq = AudioEQ(gains: Array(repeating: -12, count: AudioEQ.frequencies.count))
            editClock = a.currentTime
            state.update(project: edited)
        }
        audio.stop()
        func ratio(_ c: Recording.Chunk) -> Double {
            let f = PreviewAudioLanes.frame(c.time)
            var a = 0.0, b = 0.0
            for i in c.left.indices where f + i < reference.count { a += Double(c.left[i] * c.left[i]); b += Double(reference[f + i] * reference[f + i]) }
            return b > 0 ? (a / b).squareRoot() : .nan
        }
        let chunks = rec.snapshot.sorted { $0.time < $1.time }
        var r = LiveEditResult()
        let before = chunks.filter { $0.time > 0.6 && $0.time < editClock - 0.01 }.map(ratio)
        r.ratioBefore = before.isEmpty ? .nan : before.reduce(0, +) / Double(before.count)
        if let first = chunks.first(where: { $0.time > editClock - 0.3 && ratio($0) < 0.6 }) {
            r.heardAfterMs = (first.time - editClock) * 1000
            let after = chunks.filter { $0.time > first.time + 0.1 && $0.time < 2.1 }.map(ratio)
            r.ratioAfter = after.isEmpty ? .nan : after.reduce(0, +) / Double(after.count)
        }
        return r
    }

    public struct PauseResult: Sendable {
        public var clockDriftWhilePausedMs = Double.nan; public var discontinuities: [Double] = []; public var seeksDuring = 0
        public var leads: [Double] = []; public var resumedMs = Double.nan
    }

    /// Play, pause 300 ms, resume: the clock holds still, nothing is flushed (labels continue chunk to chunk), the
    /// content stays exact across the pause.
    public static func pauseResume(dir: URL) async throws -> PauseResult {
        let (p, clip) = try await burstProject(dir: dir)
        var r = PauseResult()
        var seeks = 0
        let (rec, audio) = try await play(p, seek: 1.3, until: 2.6) { a in
            seeks = a.stats.seeks
            _ = await wait(10) { a.currentTime > 1.7 }
            a.pause()
            let held = a.currentTime
            try await Task.sleep(nanoseconds: 300_000_000)
            r.clockDriftWhilePausedMs = (a.currentTime - held) * 1000
            let t0 = CACurrentMediaTime()
            a.play()
            _ = await wait(10) { a.currentTime > held + 0.0005 }
            r.resumedMs = (CACurrentMediaTime() - t0) * 1000
        }
        r.seeksDuring = audio.stats.seeks - seeks
        audio.stop()
        r.discontinuities = rec.discontinuities
        r.leads = onsetLeads(rec, clip: clip)
        return r
    }

    public struct SwapResult: Sendable { public var discontinuities: [Double] = []; public var swaps = 0; public var heardAfterMs = Double.nan; public var leads: [Double] = [] }

    /// `replace` while playing (the bursts clip's volume halved): the new gains are heard ≈ 100 ms after the clock at
    /// the swap, with at most one discontinuity (the flush point) and exact content around it.
    public static func swapWhilePlaying(dir: URL) async throws -> SwapResult {
        let (p, clip) = try await burstProject(dir: dir)
        let state = AudioMixState(project: p)
        var r = SwapResult()
        var swapClock = 0.0
        // built BEFORE playing: a slow build under load used to let the clock reach `until` (pause → the edit became a
        // re-seek, swaps 0) before the replace was even requested
        var edited = p
        edited.timeline[clip: clip.id]?.audio.volume = 0.5
        let built = try await build(edited, state: state)
        let (rec, audio) = try await play(p, seek: 1.3, until: 3.0, state: state) { a in
            _ = await wait(10) { a.currentTime > 1.8 }
            swapClock = a.currentTime
            a.replace(built)
            // the swap runs on the feeder queue: wait for it, then for the new gain to have played (load-robust)
            _ = await wait(20) { a.stats.swaps >= 1 }
            _ = await wait(20) { a.currentTime > swapClock + 1.0 }
        }
        let s = audio.stats
        audio.stop()
        r.swaps = s.swaps
        r.discontinuities = rec.discontinuities
        r.leads = onsetLeads(rec, clip: clip)
        // first burst onset at half level after the swap
        let st = rec.stream()
        var calm = 0
        for (i, v) in st.left.enumerated() {
            if abs(v) > 0.2 {
                if calm >= 240, abs(abs(v) - 0.4) < 0.05, Double(st.start + i) / sr > swapClock - 0.2 { r.heardAfterMs = (Double(st.start + i) / sr - swapClock) * 1000; break }
                calm = 0
            } else if abs(v) < 0.02 { calm += 1 } else { calm = 0 }
        }
        return r
    }

    // MARK: - CLI (macOS 13 VM: scripts/audio_probe.sh --vm --app)

    /// `Valse --preview-audio-check <dir>`: runs every scenario, prints one line each, exit 0 when all pass.
    public static func runCLI(_ args: [String]) -> Int32 {
        let dir = URL(fileURLWithPath: args.first ?? NSTemporaryDirectory() + "/valse-preview-audio", isDirectory: true)
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var code: Int32 = 0
            var _finished = false
            var finished: Bool { get { lock.withLock { _finished } } set { lock.withLock { _finished = newValue } } }
        }
        let box = Box()
        Task.detached {
            let log: @Sendable (String) -> Void = { print($0); fflush(stdout) }
            var ok = await runAll(dir: dir, log: log)
            // phase B: the same scenarios through PlaybackEngine (main actor: served by the run loop below)
            ok = await PlaybackEngineCheck.runAll(dir: dir, log: log) && ok
            box.code = ok ? 0 : 1
            box.finished = true
        }
        // the main run loop serves the main actor (PlaybackEngine, AVPlayer notifications) while the checks run
        while !box.finished { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return box.code
    }

    static func stats(_ x: [Double]) -> String {
        guard !x.isEmpty else { return "none" }
        let s = x.sorted()
        return String(format: "median %.2f, min %.2f, max %.2f (n %d)", s[s.count / 2], s.first!, s.last!, s.count)
    }

    /// Every scenario with the unit tests' thresholds; `log` gets one line per result.
    public static func runAll(dir: URL, log: @escaping @Sendable (String) -> Void) async -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            ok = ok && pass
            log("PREVIEWAUDIO \(pass ? "PASS" : "FAIL") \(name): \(detail)")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let out = AudioDevices.defaultOutputFormat().map { "default output \(Int($0.sampleRate)) Hz / \($0.bufferFrames) frames" } ?? "no default output"
        log("PREVIEWAUDIO macOS \(os), \(out)")
        do {
            for (rate, srcRate) in [(1.0, 48000.0), (2.0, 48000.0), (0.5, 48000.0), (1.0, 44100.0)] {
                let t = try await timing(sourceRate: srcRate, rate: rate, dir: dir)
                let ok = t.leads.count >= 3 && t.leads.allSatisfy { abs($0) <= 3 }
                check("timing rate \(rate) src \(Int(srcRate))", ok, "onset lead frames \(stats(t.leads)); clock rate \(String(format: "%.3f", t.clockRate))")
            }
            for speed in [2.0, 0.5] {
                let t = try await timing(speed: speed, dir: dir)
                check("timing speed \(speed)", abs(t.envelopeMs) <= 2 && t.corr > 0.5, String(format: "envelope lead %.0f ms, corr %.3f", t.envelopeMs, t.corr))
            }
            let p = try await cutProject(dir: dir)
            let (rec, audio) = try await play(p, seek: 1.4, until: 3.2)
            audio.stop()
            let c = try await compareToExport(rec, project: p, from: 1.45, to: 3.1)
            check("cut with fades + clip after a gap vs export", c.maxDiff < 1e-3 && c.lag == 0, "max |diff| \(c.maxDiff), lag \(c.lag) frames")
            let s = try await seekLatency(dir: dir)
            check("seek latency", s.leads.allSatisfy { abs($0) <= 3 } && !s.toClockMs.isEmpty,
                  "seek→first chunk ms \(stats(s.toFirstChunkMs)); seek→moving clock ms \(stats(s.toClockMs)); onset leads \(stats(s.leads))")
            let st = try await seekStorm(dir: dir)
            check("seek storm", st.readersWhilePlaying <= 1 && st.readersAfter <= 0 && st.released && st.leads.allSatisfy { abs($0) <= 3 },
                  "seeks performed \(st.seeksPerformed)/12, settled \(String(format: "%.0f", st.settledMs)) ms, readers while playing \(st.readersWhilePlaying) / after release \(st.readersAfter), released \(st.released), leads \(stats(st.leads))")
            let l = try await liveEdit(dir: dir)
            check("live edit", l.heardAfterMs < 250, String(format: "heard %.0f ms after the edit (level %.2f → %.2f)", l.heardAfterMs, l.ratioBefore, l.ratioAfter))
            let pr = try await pauseResume(dir: dir)
            check("pause / resume", pr.discontinuities.isEmpty && pr.seeksDuring == 0 && abs(pr.clockDriftWhilePausedMs) < 1,
                  String(format: "clock drift paused %.2f ms, resume %.0f ms, discontinuities %d, leads %@", pr.clockDriftWhilePausedMs, pr.resumedMs, pr.discontinuities.count, stats(pr.leads)))
            let sw = try await swapWhilePlaying(dir: dir)
            check("replace while playing", sw.discontinuities.isEmpty && sw.leads.allSatisfy { abs($0) <= 3 },
                  String(format: "swaps %d, discontinuities %d, new gain heard %.0f ms after, leads %@", sw.swaps, sw.discontinuities.count, sw.heardAfterMs, stats(sw.leads)))
        } catch {
            check("run", false, "\(error)")
        }
        return ok
    }
}
