@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// PB-QC: after a quick cut (many short clips alternating A/B lanes), clips whose audio comes from a rendered stage
/// (voice changer → ALAC CAF) sat on the same composition audio track as clips playing the original AAC. A seek across
/// the two formats made AVPlayer rebuild that lane's audio chain and left its processing tap unprepared: sound stopped,
/// the audio-driven clock froze at rate 1 ("playing"), and no seek / play brought it back until the item was replaced.
@MainActor @Suite(.serialized) struct PlaybackCutStallTests {
    /// 8 clips of 1.5 s cut from one 12 s clip; clips 0, 1, 4, 5 use a voice changer (rendered stage), so both A/B lanes
    /// alternate between the rendered CAF and the original AAC. The renders are made before returning.
    static func mixedFormatProject() async throws -> Project {
        var p = TestProject()
        let url = try await TestMedia.video(.frameIndex, seconds: 12, audioHz: 440)
        _ = try await p.addMedia(url)
        let mainIndex = p.project.timeline.tracks.firstIndex { $0.isMain }
        let main = try #require(mainIndex)
        let base = p.project.timeline.tracks[main].clips[0]
        var clips: [Clip] = []
        for i in 0..<8 {
            var c = base
            c.id = ClipID()
            c.start = Time(Double(i) * 1.5); c.duration = Time(1.5); c.sourceStart = Time(Double(i) * 1.5)
            if i % 4 < 2 { c.audio.voice = VoiceEffects.descriptor("valse.voice.uncle")!.makeEffect() }
            clips.append(c)
        }
        p.project.timeline.tracks[main].clips = clips
        let asset = try #require(p.project.media.first)
        _ = try await AudioRenderCache.shared.render(asset, spec: ClipAudioPlan.make(clips[0]).render)
        return p.project
    }

    static func formatKey(of segment: AVCompositionTrackSegment) async throws -> String? {
        guard !segment.isEmpty, let url = segment.sourceURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTrack(withTrackID: segment.sourceTrackID) else { return nil }
        return CompositionBuilder.audioFormatKey(try await track.load(.formatDescriptions))
    }

    @Test func audioLanesNeverMixEncodedFormats() async throws {
        let project = try await Self.mixedFormatProject()
        let built = try await CompositionBuilder.build(project: project, purpose: .preview)
        var all = Set<String>()
        for track in built.composition.tracks(withMediaType: .audio) {
            var formats = Set<String>()
            for s in track.segments { if let k = try await Self.formatKey(of: s) { formats.insert(k) } }
            #expect(formats.count <= 1, "audio track \(track.trackID) mixes formats \(formats)")
            all.formUnion(formats)
        }
        #expect(all.count == 2, "the project plays a rendered stage and the original: \(all)")
        // the old layout (one track per A/B lane) did mix them: the case this guards against
        let legacy = try await CompositionBuilder.build(project: project, purpose: .preview, mixesAudioFormats: true)
        var mixed = false
        for track in legacy.composition.tracks(withMediaType: .audio) {
            var formats = Set<String>()
            for s in track.segments { if let k = try await Self.formatKey(of: s) { formats.insert(k) } }
            mixed = mixed || formats.count > 1
        }
        #expect(mixed)
    }

    /// Polls like the player view (the engine's watchdogs run from `pixelBuffer`) until the item clock advanced `need`
    /// seconds; false if it did not within `bound` s (a frozen clock never moves; a loaded machine only decodes slower).
    static func clockAdvances(_ engine: PlaybackEngine, need: Double = 0.4, bound: Double = 12) async throws -> Bool {
        let start = CACurrentMediaTime()
        var t0: Double?
        while CACurrentMediaTime() - start < bound {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            if engine.player.rate > 0, engine.player.timeControlStatus == .playing {
                let t = engine.player.currentTime().seconds
                if let a = t0 { if t - a >= need { return true }; if t < a { t0 = t } } else { t0 = t }
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        return false
    }

    /// Seeks while playing across lanes that switch between the rendered and the original audio: the clock keeps
    /// running. `legacy`: the old mixed-format lanes — the frozen-clock watchdog must replace the wedged item.
    @Test(arguments: [false, true]) func seeksAcrossRenderedAndOriginalAudioKeepPlaying(_ legacy: Bool) async throws {
        let project = try await Self.mixedFormatProject()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            engine.mixesAudioFormatsForTesting = legacy
            engine.forceRebuild()
            try await PlaybackProbe.waitReady(engine)
            engine.seek(to: Time(0.2))
            engine.play()
            #expect(try await Self.clockAdvances(engine), "clock never started")
            for target in [10.6, 1.0, 7.6, 4.0, 11.0, 2.5] {
                engine.seek(to: Time(target))
                let ok = try await Self.clockAdvances(engine)
                #expect(ok, "clock frozen after seeking to \(target) s (legacy \(legacy), rebuilds \(engine.clockRebuilds), t \(engine.player.currentTime().seconds))")
                if !ok { break }
            }
            print("PB-QC legacy \(legacy): frozen-clock rebuilds \(engine.clockRebuilds)")
            if legacy { #expect(engine.clockRebuilds <= 2, "recovery must stick (taps off), not rebuild again and again") }
            else { #expect(engine.clockRebuilds == 0, "the clock froze with homogeneous lanes") }
            engine.pause()
        }
    }

    /// Opt-in check on a real project: `VALSE_QA_CUT_PROJECT=<copy of a .valse> scripts/test.sh --filter
    /// PlaybackCutStallTests` (the package is only read).
    @Test func realProjectSurvivesSeekStress() async throws {
        guard let path = ProcessInfo.processInfo.environment["VALSE_QA_CUT_PROJECT"] else { print("skip: VALSE_QA_CUT_PROJECT"); return }
        let project = try ProjectPackage.load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine, timeout: 60)
            var waited = 0   // rendered audio stages: the engine rebuilds as each one lands
            while (AudioRenderCache.shared.isBusy || engine.isBuilding) && waited < 6000 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            try await PlaybackProbe.waitReady(engine, timeout: 60)
            let r = try await PlaybackStressTests.stress(engine, actions: 60, seed: 42, timeout: 3)
            print("PB-QC real project: \(r.actions) actions, stalls \(r.stalls.count), frozen-clock rebuilds \(engine.clockRebuilds)")
            #expect(r.stalls.isEmpty, "\(r.stalls.prefix(3))")
            #expect(engine.clockRebuilds == 0)
        }
    }
}
