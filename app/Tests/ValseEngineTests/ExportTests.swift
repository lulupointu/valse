import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseTestSupport

@Suite(.serialized) struct ExportTests {
    @Test func h264ExportHasExpectedFormat() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.movingBox(.blue, .white), seconds: 2, audioHz: 440)
        var s = ExportSettings(); s.resolution = .p480; s.frameRate = .fps30
        let r = try await p.export(seconds: 1, settings: s)
        #expect(r.probe.videoCodec == "h264")
        #expect(r.probe.width == 854 && r.probe.height == 480)
        #expect(abs(r.probe.duration - 1) < 0.1)
        if let n = r.probe.frameCount { #expect(abs(n - 30) <= 1) }
        #expect(r.probe.hasAudio)
    }

    @Test func hevcAndProResExport() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.solid(.red), seconds: 1)
        var s = ExportSettings(); s.resolution = .p480; s.codec = .hevc
        #expect(try await p.export(seconds: 0.5, settings: s).probe.videoCodec == "hevc")
        s.codec = .proRes422
        let r = try await p.export(seconds: 0.5, settings: s)
        #expect(r.probe.videoCodec == "prores")
        #expect(r.url.pathExtension == "mov")
    }

    @Test func exportedPixelsMatchPreviewRenderer() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        let id = try await p.addVideo(.solid(.green), seconds: 1)
        p[id].transform.scale = Vec2(0.5, 0.5)
        var s = ExportSettings(); s.resolution = .p480
        let r = try await p.export(seconds: 0.5, settings: s)
        let frame = try await renderFrame(try await importedProject(r.url), at: 0.2)
        #expect(frame[0.5, 0.5].isClose(to: .green))
        #expect(frame[0.1, 0.1].isClose(to: .black))
    }

    @Test func exportReportsProgressAndCanBeCancelled() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.movingBox(.red, .white), seconds: 4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID()).mp4")
        let project = p.project
        let task = Task { try await Exporter.export(project: project, settings: ExportSettings(), to: url) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    func importedProject(_ url: URL) async throws -> Project {
        var p = TestProject(canvas: Size2(854, 480))
        try await p.addMedia(url)
        return p.project
    }
}

@Suite struct MediaTests {
    @Test func probeReadsVideoAudioAndImages() async throws {
        let v = try await MediaProbe.probe(try await TestMedia.video(.solid(.red), seconds: 2, audioHz: 440))
        #expect(v.kind == .video && v.hasAudio && v.pixelSize == Size2(320, 180))
        #expect(abs(v.duration.seconds - 2) < 0.05)
        #expect(v.frameRate == .fps30)
        let a = try await MediaProbe.probe(try await TestMedia.audio())
        #expect(a.kind == .audio && !a.hasVideo)
        let i = try await MediaProbe.probe(try TestMedia.image(.solid(.blue)))
        #expect(i.kind == .image && i.duration == .indefinite)
        #expect(!v.contentHash.isEmpty && v.contentHash != a.contentHash)
    }

    @Test func exportSettingsMath() {
        var s = ExportSettings()
        s.resolution = .p1080
        #expect(s.outputSize(canvas: Size2(1920, 1080)) == (1920, 1080))
        #expect(s.outputSize(canvas: Size2(1080, 1920)) == (1080, 1920))
        #expect(s.videoBitrate(canvas: .hd1080) > 1_000_000)
        #expect(s.estimatedBytes(duration: 10, canvas: .hd1080) > 0)
    }
}
