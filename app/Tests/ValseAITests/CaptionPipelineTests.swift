import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Auto captions end to end: speech audio on the timeline → CaptionGenerator → caption clips → export renders them.
@Suite(.serialized) struct CaptionPipelineTests {
    @Test func generateCaptionsFromAudioTrackAndExport() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
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
            let caps = SpeechCaptions.captions(in: p.project.timeline)
            #expect(caps.count == r.count)
            let first = try #require(caps.first)
            let firstText: String = CaptionOps.text(first).map { $0.string } ?? ""
            #expect(firstText.lowercased().hasPrefix("bonjour"))
            #expect(CaptionOps.text(first)?.caption?.words.isEmpty == false)
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
    }

    @Test func noSpeechThrows() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 1)
        let silent = try await TestMedia.audio(seconds: 1.5, hz: 0)
        _ = try await p.addMedia(silent, at: .zero, target: .newTrack)
        await #expect(throws: SpeechFailure.noSpeech(language: nil)) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(source: .allTracks))
        }
        // forced language: the reason keeps it (the card then offers "Detect language automatically")
        await #expect(throws: SpeechFailure.noSpeech(language: "fr")) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(language: "fr", source: .allTracks))
        }
    }

    /// BUG-CAPTION-ERRORS: typed input failures instead of a generic "try again".
    @Test func inputFailuresAreTyped() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 1)
        // no clip with sound: All tracks vs a chosen track
        await #expect(throws: SpeechFailure.nothingToCaption(trackChosen: false)) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(source: .allTracks))
        }
        await #expect(throws: SpeechFailure.nothingToCaption(trackChosen: true)) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(source: .mainTrack))
        }
        // the source file was moved: offline, with the media to relink
        let tone = try await TestMedia.audio(seconds: 1.5, hz: 440)
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("valse-offline-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: tone, to: moved)
        _ = try await p.addMedia(moved, at: .zero, target: .newTrack)
        try FileManager.default.removeItem(at: moved)
        let asset = try #require(p.project.media.first { $0.url == moved })
        await #expect(throws: SpeechFailure.mediaOffline(name: asset.name, media: asset.id)) {
            _ = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(source: .allTracks))
        }
    }

    /// A failing audio extraction says why (file gone / no sound), never a raw AVFoundation error.
    @Test func audioExtractorFailuresAreTyped() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("valse-missing-\(UUID().uuidString).wav")
        await #expect(throws: SpeechFailure.mediaOffline(name: gone.lastPathComponent, media: nil)) {
            _ = try await AudioExtractor.wav16k(gone, range: nil)
        }
        let video = try await TestMedia.video(.solid(.black), seconds: 1)
        await #expect(throws: SpeechFailure.noSoundInFile(name: video.lastPathComponent)) {
            _ = try await AudioExtractor.wav16k(video, range: nil)
        }
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [CaptionPhase] = []
    func add(_ p: CaptionPhase) { lock.withLock { phases.append(p) } }
    var all: [CaptionPhase] { lock.withLock { phases } }
}
