import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Auto captions end to end: speech audio on the timeline → CaptionGenerator → caption clips → export renders them.
@Suite(.serialized) struct CaptionPipelineTests {
    @Test func generateCaptionsFromAudioTrackAndExport() async throws {
        guard let wav = AIFixtures.speechFR else { print("skip: bench media missing"); return }
        var p = TestProject()
        _ = try await p.addVideo(.solid(RGBA(0.1, 0.1, 0.4)), seconds: 6)
        let audioID = try await p.addMedia(wav, at: .zero, target: .newTrack, duration: Time(6))
        #expect(p.project.timeline.clip(audioID) != nil)
        let options = CaptionOptions(language: nil, engine: .automatic, source: .allTracks)
        let phases = PhaseLog()
        let r = try await CaptionGenerator.run(project: p.project, options: options, progress: nil) { phases.add($0) }
        #expect(r.language == "fr")
        #expect(r.count >= 2)
        try r.command.apply(to: &p.project)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        let caps = CaptionOps.captions(in: p.project.timeline)
        #expect(caps.count == r.count)
        let first = try #require(caps.first)
        #expect(CaptionOps.mainText(first).lowercased().hasPrefix("bonjour"))
        #expect(first.caption?.words.isEmpty == false)
        #expect(phases.all.contains(.adding))
        // cached: a second run is instant and identical
        let again = try await CaptionGenerator.run(project: p.project, options: options)
        #expect(again.count == r.count)

        // the caption is rendered in the lower third (white text over the blue background)
        let t = first.start.seconds + min(0.3, first.duration.seconds / 2)
        let img = try await p.render(at: t)
        var bright = 0
        for y in stride(from: 0.75, to: 0.95, by: 0.01) {
            for x in stride(from: 0.2, to: 0.8, by: 0.01) where img[x, y].r > 0.8 && img[x, y].g > 0.8 { bright += 1 }
        }
        #expect(bright > 10, "no caption pixels")
        let out = try await p.export(seconds: 2)
        #expect(out.probe.width > 0 && out.probe.duration > 1.5 && out.probe.hasAudio)
    }

    @Test func noSpeechThrows() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 1)
        let silent = try await TestMedia.audio(seconds: 1.5, hz: 0)
        _ = try await p.addMedia(silent, at: .zero, target: .newTrack)
        await #expect(throws: AIToolError.self) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(source: .allTracks))
        }
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [CaptionPhase] = []
    func add(_ p: CaptionPhase) { lock.withLock { phases.append(p) } }
    var all: [CaptionPhase] { lock.withLock { phases } }
}
