import Testing
import Foundation
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Store flows of the media pipeline: folder import keeps structure (one undo step), captions, colour clips, relink.
@MainActor @Suite(.serialized) struct MediaStoreTests {
    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<3000 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }   // ≥ 30 s hang bound (load)
    }

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-store-media-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func folderImportCreatesBinFoldersInOneUndoStep() async throws {
        let root = tempDir().appendingPathComponent("Shoot", isDirectory: true)
        let sub = root.appendingPathComponent("B-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try await TestMedia.video(.solid(.red), seconds: 1), to: root.appendingPathComponent("a.mp4"))
        try FileManager.default.copyItem(at: try await TestMedia.video(.solid(.blue), seconds: 1), to: sub.appendingPathComponent("b.mp4"))
        let s = EditorStore()
        s.autosaveEnabled = false
        s.importMedia([root])
        await waitUntil { s.project.media.count == 2 }
        #expect(s.project.folders.map(\.name).sorted() == ["B-roll", "Shoot"])
        let b = try #require(s.project.media.first { $0.name == "b" })
        #expect(BinOps.path(to: b.folderID, in: s.project).map(\.name) == ["Shoot", "B-roll"])
        s.undo()
        #expect(s.project.media.isEmpty && s.project.folders.isEmpty)
    }

    @Test func captionFileBecomesTextTrack() async throws {
        let url = tempDir().appendingPathComponent("subs.srt")
        try "1\n00:00:00,500 --> 00:00:01,500\nBonjour\n\n2\n00:00:02,000 --> 00:00:03,000\nSalut\n".write(to: url, atomically: true, encoding: .utf8)
        let s = EditorStore()
        s.autosaveEnabled = false
        s.importMedia([url])
        await waitUntil { s.project.timeline.tracks.contains { $0.kind == .text } }
        let t = try #require(s.project.timeline.tracks.first { $0.kind == .text })
        #expect(t.clips.count == 2 && t.clips[0].start == Time(0.5))
    }

    @Test func colorClipAndFolderCommands() async throws {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.addColorClip(.black, nameKey: "media.color.black")
        #expect(s.project.timeline.mainTrack?.clips.count == 1)
        let f = try #require(s.createFolder(in: nil))
        s.renameFolder(f, to: "Mes rushs")
        #expect(s.project.folders.first?.name == "Mes rushs")
        s.deleteFolder(f)
        #expect(s.project.folders.isEmpty)
    }

    @Test func relinkMissingFromFolder() async throws {
        let a = tempDir(), b = tempDir()
        let u = a.appendingPathComponent("m.mp4")
        try FileManager.default.copyItem(at: try await TestMedia.video(.solid(.green), seconds: 1), to: u)
        var p = Project()
        p.media = [try await MediaProbe.probe(u)]
        try FileManager.default.moveItem(at: u, to: b.appendingPathComponent("m.mp4"))
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        #expect(s.isMissing(s.project.media[0]))
        s.relinkMissing(searching: b)
        await waitUntil { !s.isMissing(s.project.media[0]) }
        #expect(!s.isMissing(s.project.media[0]))
    }
}
