import Testing
import Foundation
import ValseCore
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// MI-015 / MI-017: placing finished recordings (one undo step), recorder model permission logic.
@MainActor @Suite(.serialized) struct RecordingStoreTests {
    func copy(_ src: URL, _ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: u)
        return u
    }

    @Test func screenAndCameraSeparateTracks() async throws {
        let screen = try copy(try await TestMedia.video(.solid(.red), seconds: 2), "screen.mp4")
        let cam = try copy(try await TestMedia.video(.solid(.blue), seconds: 2), "cam.mp4")
        let s = EditorStore()
        s.autosaveEnabled = false
        await s.placeRecording(.init(screenURL: screen, cameraURL: cam, layout: .separate))
        #expect(s.project.media.count == 2)
        #expect(s.project.timeline.mainTrack?.clips.count == 1)
        let overlay = try #require(s.project.timeline.tracks.first { !$0.isMain && !$0.clips.isEmpty })
        #expect(overlay.clips[0].transform.scale.x == 0.3)
        #expect(s.session.undoNameKey == "cmd.record")
        s.undo()
        #expect(s.project.media.isEmpty && s.project.timeline.allClips.isEmpty)
    }

    @Test func singleTrackNestsIntoCompound() async throws {
        let screen = try copy(try await TestMedia.video(.solid(.red), seconds: 2), "screen.mp4")
        let cam = try copy(try await TestMedia.video(.solid(.blue), seconds: 2), "cam.mp4")
        let s = EditorStore()
        s.autosaveEnabled = false
        await s.placeRecording(.init(screenURL: screen, cameraURL: cam, layout: .single))
        #expect(s.project.compounds?.count == 1)
        #expect(s.project.timeline.allClips.count == 1)
        if case .compound = s.project.timeline.allClips[0].content {} else { Issue.record("expected a compound clip") }
    }

    @Test func cameraOnlyGoesToMainTrack() async throws {
        let cam = try copy(try await TestMedia.video(.solid(.blue), seconds: 1), "cam.mp4")
        let s = EditorStore()
        s.autosaveEnabled = false
        await s.placeRecording(.init(screenURL: nil, cameraURL: cam, layout: .separate))
        #expect(s.project.timeline.mainTrack?.clips.count == 1 && s.project.timeline.allClips.count == 1)
    }

    @Test func modelNeedsPermissions() {
        RecordingPermission.override = [.screen: .granted, .microphone: .denied]
        defer { RecordingPermission.override = nil }
        let m = RecorderModel(mode: .screen)
        #expect(m.missing == .microphone)
        m.microphone = false
        #expect(m.missing == nil)
        #expect(!m.canStart)   // no source selected
        m.sources = [ScreenSource(kind: .display, id: 1, name: "1", size: CGSize(width: 100, height: 100))]
        m.sourceID = m.key(m.sources[0])
        #expect(m.canStart)
        m.camera = true
        #expect(m.missing == .camera)
    }
}
