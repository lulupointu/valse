import Testing
import Foundation
import CoreText
import ValseCore
import ValseEngine
import ValseTestSupport

@Suite(.serialized) struct MediaLibraryToolsTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("valse-lib-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func copyOfTestVideo(_ dir: URL, name: String, pattern: SyntheticMedia.Pattern = .solid(.red)) async throws -> URL {
        let src = try await TestMedia.video(pattern, seconds: 1)
        let dst = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    @Test func relinksMovedAndRenamedMedia() async throws {
        let a = tempDir(), b = tempDir()
        let u1 = try await copyOfTestVideo(a, name: "one.mp4")
        let u2 = try await copyOfTestVideo(a, name: "two.mp4", pattern: .solid(.blue))
        var p = Project()
        p.media = [try await MediaProbe.probe(u1), try await MediaProbe.probe(u2)]
        #expect(MediaRelinker.missing(in: p).isEmpty)
        // move one renamed (hash match), the other with the same name into a sub-folder (name+size match)
        let sub = b.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: u1, to: b.appendingPathComponent("renamed.mp4"))
        try FileManager.default.moveItem(at: u2, to: sub.appendingPathComponent("two.mp4"))
        #expect(MediaRelinker.missing(in: p).count == 2)
        let found = MediaRelinker.search(b, for: MediaRelinker.missing(in: p))
        #expect(found.count == 2)
        MediaRelinker.apply(found, to: &p)
        #expect(MediaRelinker.missing(in: p).isEmpty)
        #expect(p.media[0].url.lastPathComponent == "renamed.mp4")
        #expect(p.media[1].url.path.hasSuffix("nested/deeper/two.mp4"))
    }

    @Test func relinkDoesNotMatchDifferentContent() async throws {
        let a = tempDir(), b = tempDir()
        let u1 = try await copyOfTestVideo(a, name: "clip.mp4")
        var p = Project()
        p.media = [try await MediaProbe.probe(u1)]
        try FileManager.default.removeItem(at: u1)
        try Data(repeating: 7, count: 1000).write(to: b.appendingPathComponent("clip.mp4"))  // same name, other size
        #expect(MediaRelinker.search(b, for: p.media).isEmpty)
    }

    @Test func consolidateCopiesIntoPackage() async throws {
        let a = tempDir()
        let u1 = try await copyOfTestVideo(a, name: "c.mp4")
        var p = Project()
        p.media = [try await MediaProbe.probe(u1)]
        let pkg = a.appendingPathComponent("P.valse")
        let map = try MediaConsolidator.consolidate(p, packageURL: pkg)
        MediaRelinker.apply(map, to: &p)
        #expect(p.media[0].url.path.hasPrefix(pkg.appendingPathComponent("media").path))
        #expect(FileManager.default.fileExists(atPath: p.media[0].url.path))
        // second run: nothing left to copy
        #expect(try MediaConsolidator.consolidate(p, packageURL: pkg).isEmpty)
        // project saved next to the package and moved still finds media/ through the relative path
        try ProjectPackage.save(p, to: pkg)
        let q = try ProjectPackage.load(from: pkg)
        #expect(q.media[0].url.standardizedFileURL == p.media[0].url.standardizedFileURL)
    }

    @Test func livePhotoPairing() {
        let urls = ["/x/IMG_1.HEIC", "/x/IMG_1.MOV", "/x/IMG_2.HEIC", "/x/clip.mov"].map { URL(fileURLWithPath: $0) }
        let (pairs, rest) = LivePhoto.pair(urls)
        #expect(pairs.count == 1 && pairs[0].still.lastPathComponent == "IMG_1.HEIC")
        #expect(rest.map(\.lastPathComponent) == ["IMG_2.HEIC", "clip.mov"])
    }

    @Test func fontImportRegistersForProcess() throws {
        // Copy a system font file under a new name and import it.
        let candidates = ["/System/Library/Fonts/Supplemental/Arial Narrow.ttf", "/System/Library/Fonts/Supplemental/Courier New.ttf",
                          "/Library/Fonts/Arial Unicode.ttf"]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let names = try FontLibrary.importFonts([URL(fileURLWithPath: src)])
        #expect(!names.isEmpty)
        #expect(FileManager.default.fileExists(atPath: FontLibrary.directory.appendingPathComponent((src as NSString).lastPathComponent).path))
        let f = CTFontCreateWithName(names[0] as CFString, 12, nil)
        #expect(CTFontCopyPostScriptName(f) as String == names[0])
        #expect(!FontLibrary.loadAll().isEmpty)
        try? FileManager.default.removeItem(at: FontLibrary.directory.appendingPathComponent((src as NSString).lastPathComponent))
    }

    @Test func folderImportKeepsStructure() throws {
        let root = tempDir().appendingPathComponent("Shoot", isDirectory: true)
        let day = root.appendingPathComponent("Day 1/A cam", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("top.mp4"))
        try Data([0]).write(to: day.appendingPathComponent("x.mov"))
        try Data([0]).write(to: day.appendingPathComponent("notes.txt"))
        let items = MediaProbe.expandWithFolders([root])
        #expect(items.count == 2)
        #expect(items.first { $0.url.lastPathComponent == "top.mp4" }?.folderPath == ["Shoot"])
        #expect(items.first { $0.url.lastPathComponent == "x.mov" }?.folderPath == ["Shoot", "Day 1", "A cam"])
    }
}
