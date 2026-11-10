@preconcurrency import AVFoundation
import Foundation
import os
import QuartzCore
import Testing
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-PLAY-SILENT (owner 2026-11-07, project "Episode 5"): "when I hit play, sometimes there is no sound" — video
/// plays, the lanes carry sound, the output is silent; pause / play, a seek or the next cut on another lane brings it back.
/// Measured at the output (`OutputCapture`: a muted process tap on this process, player routed to a virtual device)
/// against the lane taps (`AudioMixState.tapCapture`: what AVPlayer was given).
@MainActor @Suite(.serialized) struct PlaybackSilenceTests {
    static let env = ProcessInfo.processInfo.environment
    /// Virtual output the player is routed to (nothing reaches the speakers; the capture is muted anyway).
    static let virtualOutput = env["VALSE_SILENT_OUTPUT"] ?? "SteamStreamingSpeakers_UID"

    final class LanePeaks: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(host: Double, peak: Float)] = []
        func add(_ h: Double, _ p: Float) { lock.withLock { items.append((h, p)) } }
        func peak(from: Double, to: Double) -> Float { lock.withLock { items.filter { $0.host >= from && $0.host < to }.map(\.peak).max() ?? 0 } }
    }

    struct PlayResult { var loudWindows = 0; var silentWindows = 0; var silent: Bool { loudWindows >= 5 && Double(silentWindows) >= 0.5 * Double(loudWindows) } }

    /// 100 ms windows of `[from, to)` where the lanes were loud: how many of them the output left silent. The lane taps run
    /// ahead of the output (AudioQueue latency ≤ ~0.3 s): a window counts as loud when the lanes were loud over it and the
    /// 0.3 s before.
    @available(macOS 14.2, *)
    static func classify(lanes: LanePeaks, output: OutputCapture, from: Double, to: Double) -> PlayResult {
        var r = PlayResult()
        var t = from
        while t + 0.1 <= to {
            if lanes.peak(from: t - 0.3, to: t + 0.1) > 0.02, lanes.peak(from: t - 0.3, to: t - 0.2) > 0.02 {
                r.loudWindows += 1
                let out = output.chunks(from: t, to: t + 0.1).map(\.peak).max() ?? 0
                if out < 0.0005 { r.silentWindows += 1 }
            }
            t += 0.1
        }
        return r
    }

    static func drive(_ engine: PlaybackEngine, seconds: Double) async throws {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Runs `plays` plays (seek + play, pause + play in place, seek while playing), each `seconds` long, and returns how
    /// many of them were silent while the lanes sounded.
    @available(macOS 14.2, *)
    static func playMany(_ engine: PlaybackEngine, plays: Int, seconds: Double = 3, seed: UInt64, label: String,
                         range: ClosedRange<Double>? = nil) async throws -> (silent: Int, measured: Int, lines: [String]) {
        let lanes = LanePeaks()
        engine.audioState.tapCapture = { _, s, _, _ in
            var p: Float = 0
            for v in s { p = max(p, abs(v)) }
            lanes.add(CACurrentMediaTime(), p)
        }
        defer { engine.audioState.tapCapture = nil }
        engine.outputDeviceUID = virtualOutput
        engine.audio.renderer.volume = 1   // tests export VALSE_MUTE_AUDIO (volume 0): the capture is muted and the device virtual
        defer { engine.audio.renderer.volume = AudioOutput.volume(1) }
        let capture = try OutputCapture(clockDeviceUID: virtualOutput)
        defer { capture.stop() }
        var rng = SplitMix(seed: seed)
        let span = range ?? 0...max(0, engine.duration.seconds - seconds - 0.5)
        var silent = 0, measured = 0
        var lines: [String] = []
        for i in 0..<plays {
            let kind = rng.next() % 4
            let at = span.lowerBound + Double(rng.next() % 10_000) / 10_000 * (span.upperBound - span.lowerBound)
            switch kind {
            case 0, 1:   // seek, then play
                engine.pause()
                engine.seek(to: Time(at))
                try await drive(engine, seconds: 0.4)
                engine.play()
            case 2:      // pause + play in place
                engine.play()
                try await drive(engine, seconds: 0.6)
                engine.pause()
                try await drive(engine, seconds: 0.3)
                engine.play()
            default:     // seek while playing
                engine.play()
                try await drive(engine, seconds: 0.3)
                engine.seek(to: Time(at))
            }
            let start = CACurrentMediaTime()
            let from = engine.currentTime.seconds
            try await drive(engine, seconds: seconds)
            let r = classify(lanes: lanes, output: capture, from: start + 0.5, to: CACurrentMediaTime())
            if r.loudWindows >= 5 { measured += 1 }
            if r.silent { silent += 1 }
            let line = String(format: "%@ play %d kind %d from %.2f: loud windows %d, silent %d %@", label, i, Int(kind), from,
                              r.loudWindows, r.silentWindows, r.silent ? "SILENT" : "")
            print("PLAYSILENT " + line)
            lines.append(line)
        }
        engine.pause()
        return (silent, measured, lines)
    }

    struct SplitMix { var s: UInt64; init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }

    static func waitSettled(_ engine: PlaybackEngine) async throws {
        try await PlaybackProbe.waitReady(engine, timeout: 120)
        var waited = 0
        while (AudioRenderCache.shared.isBusy || engine.isBuilding) && waited < 6000 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        try await PlaybackProbe.waitReady(engine, timeout: 120)
    }

    static func audioTrackCount(_ project: Project, separates: Bool = false) async throws -> Int {
        let built = try await CompositionBuilder.build(project: project, purpose: .preview, separatesTrackAudio: separates,
                                                       sources: PlaybackEngine.originalSources)
        return built.composition.tracks.filter { $0.mediaType == .audio }.count
    }

    /// Plays `plays` times with the old layout (composition audio tracks per decode track: `VALSE_SILENT_LEGACY=1`)
    /// and then the shipped one; returns the shipped layout's silent plays.
    @available(macOS 14.2, *)
    static func compareLayouts(_ project: Project, plays: Int, label: String) async throws -> Int {
        let engine = PlaybackEngine(project: project)
        engine.usesProxies = false
        var silent = 0
        for legacy in env["VALSE_SILENT_LEGACY"] != nil ? [true, false] : [false] {
            engine.separatesTrackAudioForTesting = legacy
            engine.forceRebuild()
            try await waitSettled(engine)
            let tracks = try await audioTrackCount(project, separates: legacy)
            let r = try await playMany(engine, plays: plays, seed: 7, label: "\(label) legacy=\(legacy)")
            print("PLAYSILENT \(label) legacy=\(legacy): \(tracks) audio composition tracks, \(r.silent) silent of \(r.measured) measured plays")
            if !legacy { silent = r.silent }
        }
        return silent
    }

    /// Manual repro on a copy of the owner's project: `VALSE_SILENT_PROJECT=<copy of a .valse> scripts/test.sh --filter
    /// PlaybackSilenceTests` (the package is only read). `VALSE_SILENT_PLAYS` (default 30), `VALSE_SILENT_LEGACY=1`
    /// plays the old layout first (measured 2026-11-07: 13 audio tracks, 5 and 7 silent plays of 25).
    @Test func realProjectPlaysAreNeverSilent() async throws {
        guard let path = Self.env["VALSE_SILENT_PROJECT"] else { print("skip: VALSE_SILENT_PROJECT"); return }
        guard #available(macOS 14.2, *) else { return }
        let project = try ProjectPackage.load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let plays = Int(Self.env["VALSE_SILENT_PLAYS"] ?? "30") ?? 30
        #expect(try await Self.compareLayouts(project, plays: plays, label: "real") == 0)
    }

    // MARK: Generated media

    /// Main track of `2 × compounds + 1` butted 1.5 s clips of one 440 Hz video (jump cuts), every odd clip turned into
    /// a compound clip of its own — like "Episode 5" (each compound's nested track is a decode track of its own).
    static func compoundProject(compounds: Int) async throws -> Project {
        var p = TestProject(frameRate: .fps25)
        let id = try await p.addVideo(.frameIndex, seconds: Double(3 * compounds + 4), audioHz: 440)
        let ti = try #require(p.project.timeline.tracks.firstIndex { $0.clips.contains { $0.id == id } })
        let base = p[id]
        var clips: [Clip] = []
        for i in 0..<(2 * compounds + 1) {
            var c = base
            c.id = ClipID()
            c.start = Time(Double(i) * 1.5); c.duration = Time(1.5); c.sourceStart = Time(Double(i) * 1.5 + (i % 2 == 0 ? 0 : 0.2))
            clips.append(c)
        }
        p.project.timeline.tracks[ti].clips = clips
        for (i, c) in clips.enumerated() where i % 2 == 1 { try TimelineOps.createCompound([c.id], name: "C\(i)", in: &p.project) }
        #expect(p.project.compounds?.count == compounds)
        return p.project
    }

    @Test func compoundAudioSharesTheMainTracksCompositionTrack() async throws {
        let project = try await Self.compoundProject(compounds: 6)
        #expect(try await Self.audioTrackCount(project, separates: true) == 7)   // the layout that went silent
        #expect(try await Self.audioTrackCount(project) == 1)
        // an overlapping audio clip (music under the main track) needs a second track, and only one
        var tp = TestProject(frameRate: .fps25)
        tp.project = project
        try await tp.addVideo(.frameIndex, seconds: 8, audioHz: 660, at: Time(1), target: .newTrack)
        #expect(try await Self.audioTrackCount(tp.project) == 2)
    }

    @Test func lanePlanSharesFreeTracksAndKeepsSplitsTogether() {
        typealias S = CompositionBuilder.AudioSpan
        func s(_ a: Double, _ b: Double, _ g: Int, _ f: String = "aac") -> S { S(start: Time(a), end: Time(b), format: f, group: g) }
        // butted clips of one track, then a compound's clips (other decode tracks) after them: one track
        #expect(CompositionBuilder.audioLanePlan([s(0, 1, 0), s(1, 2, 0), s(2, 3, 1), s(3, 4, 0), s(4, 5, 2)]) == [0, 0, 0, 0, 0])
        // overlaps take another track; formats never share one
        #expect(CompositionBuilder.audioLanePlan([s(0, 4, 0), s(1, 2, 1), s(2, 3, 2), s(3, 5, 3, "caf")]) == [0, 1, 1, 2])
        // a track's next clip goes back on the track it used last when that one is free (BUG-CUT-AUDIO-ARTEFACT)
        #expect(CompositionBuilder.audioLanePlan([s(0, 1, 0), s(0, 2, 1), s(2, 3, 0)]) == [0, 1, 0])
        // the old layout: tracks per decode track
        #expect(CompositionBuilder.audioLanePlan([s(0, 1, 0), s(1, 2, 1), s(2, 3, 0)], sharesAcrossTracks: false) == [0, 1, 0])
        // input order does not matter (spans are placed in time order)
        #expect(CompositionBuilder.audioLanePlan([s(2, 3, 1), s(0, 1, 0), s(1, 2, 0)]) == [0, 0, 0])
    }

    /// Output-level regression on generated media (opt-in: needs macOS 14.2 and a virtual output, plays ~2 min):
    /// `VALSE_SILENT_REPRO=1 [VALSE_SILENT_LEGACY=1] scripts/test.sh --filter PlaybackSilenceTests`.
    @Test func compoundProjectPlaysAreNeverSilent() async throws {
        guard Self.env["VALSE_SILENT_REPRO"] != nil else { print("skip: VALSE_SILENT_REPRO"); return }
        guard #available(macOS 14.2, *) else { return }
        let project = try await Self.compoundProject(compounds: 12)
        let plays = Int(Self.env["VALSE_SILENT_PLAYS"] ?? "30") ?? 30
        #expect(try await Self.compareLayouts(project, plays: plays, label: "generated") == 0)
    }
}
