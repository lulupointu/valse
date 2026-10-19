import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import MontageCore
import MontageEffects
@testable import MontageEngine
import MontageTestSupport

/// MI-006 auto-relink at open.
@Suite struct F3AutoRelinkTests {
    func file(_ u: URL, seed: UInt8) throws -> MediaAsset {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: Int($0) &* Int(seed)) }).write(to: u)
        let size = Int64(try FileManager.default.attributesOfItem(atPath: u.path)[.size] as! Int)
        return MediaAsset(name: u.lastPathComponent, kind: .video, url: u, duration: 5, pixelSize: .hd1080, frameRate: .fps30,
                          hasVideo: true, hasAudio: false, contentHash: MediaProbe.contentHash(u, size: size, mtime: nil), fileSize: size)
    }

    @Test func findsMovedMediaNearTheProjectAndInRememberedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f3-relink-\(UUID().uuidString)/work")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let pkg = root.appendingPathComponent("Trip.montage")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        // 1. renamed folder next to the project
        var a = try file(root.appendingPathComponent("Old shoot/a.mov"), seed: 7)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Old shoot"), to: root.appendingPathComponent("Footage"))
        // 2. same name, different content in the project folder must NOT match; the real one lives in a remembered folder
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("Archive")
        var b = try file(elsewhere.appendingPathComponent("b.mov"), seed: 13)
        let bOld = root.appendingPathComponent("gone/b.mov")
        _ = try file(root.appendingPathComponent("decoy/b.mov"), seed: 99)
        a.url = root.appendingPathComponent("Old shoot/a.mov"); b.url = bOld
        #expect(MediaRelinker.isMissing(a) && MediaRelinker.isMissing(b))
        let folders = MediaAutoRelink.candidateFolders(missing: [a, b], packageURL: pkg, remembered: [elsewhere])
        #expect(folders.first?.path == root.standardizedFileURL.path)
        let found = MediaAutoRelink.search(missing: [a, b], packageURL: pkg, remembered: [elsewhere])
        #expect(found[a.id]?.standardizedFileURL.path == root.appendingPathComponent("Footage/a.mov").standardizedFileURL.path)
        #expect(found[b.id]?.standardizedFileURL.path == elsewhere.appendingPathComponent("b.mov").standardizedFileURL.path)
        // without the remembered folder only a is found: the decoy has the same name and size but another fingerprint
        let partial = MediaAutoRelink.search(missing: [a, b], packageURL: pkg, remembered: [])
        #expect(partial[a.id] != nil)
        #expect(partial[b.id] == nil)
    }

    @Test func broadRootsAreNeverScanned() {
        #expect(MediaAutoRelink.isBroad(URL(fileURLWithPath: "/")))
        #expect(MediaAutoRelink.isBroad(FileManager.default.homeDirectoryForCurrentUser))
        #expect(MediaAutoRelink.isBroad(URL(fileURLWithPath: "/Volumes/Drive")))
        #expect(!MediaAutoRelink.isBroad(URL(fileURLWithPath: "/Volumes/Drive/Footage")))
    }
}

/// CV-006 rotation inside the crop window.
@Suite struct F3CropRenderTests {
    @Test func rotatedCropTurnsTheImageAndNeverShowsEmptyCorners() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.split(RGBA(1, 0, 0), RGBA(0, 0, 1)), seconds: 1)
        let plain = try await p.render(at: 0.5)
        #expect(plain[0.1, 0.5].r > 0.8 && plain[0.9, 0.5].b > 0.8)
        // 90° clockwise: the red left half moves to the top
        p[id].crop = CropRect(rotation: 90)
        let r90 = try await p.render(at: 0.5)
        #expect(r90[0.5, 0.08].r > 0.8 && r90[0.5, 0.08].b < 0.3, "top \(r90[0.5, 0.08])")
        #expect(r90[0.5, 0.92].b > 0.8 && r90[0.5, 0.92].r < 0.3, "bottom \(r90[0.5, 0.92])")
        // 30°: the window zooms in, so every corner still shows the image (no black)
        p[id].crop = CropRect(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1, rotation: 30)
        let r30 = try await p.render(at: 0.5)
        for (x, y) in [(0.12, 0.12), (0.88, 0.12), (0.12, 0.88), (0.88, 0.88)] {   // the cropped layer covers 0.1…0.9
            let c = r30[x, y]
            #expect(c.r + c.b > 0.7, "corner \(x),\(y) = \(c)")
        }
    }
}

/// MI-008 proxy creation rules.
@Suite struct F3ProxyTests {
    func video(_ w: Double, _ h: Double) -> MediaAsset {
        MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/v.mov"), duration: 10, pixelSize: Size2(w, h),
                   frameRate: .fps30, hasVideo: true, hasAudio: false, contentHash: "h\(w)")
    }

    @Test func alwaysOnlyConvertsMaterialAboveTheProxyResolution() {
        let m = ProxyManager()
        m.policy = .always; m.resolution = 720; m.onlyAboveResolution = true
        #expect(m.shouldGenerate(video(1920, 1080)))
        #expect(!m.shouldGenerate(video(1280, 720)))
        #expect(!m.shouldGenerate(video(720, 1280)))      // portrait: short side
        m.resolution = 540
        #expect(m.shouldGenerate(video(1280, 720)))
        m.onlyAboveResolution = false; m.resolution = 1080
        #expect(m.shouldGenerate(video(640, 360)))
        m.policy = .never
        #expect(!m.shouldGenerate(video(3840, 2160)))
    }
}

/// Finisher F3 render tests (text stroke position, …).
@Suite(.serialized) struct F3TextRenderTests {
    let h = TextRenderTests()

    /// TX-005: inside keeps the glyph's outer edge, centre grows it by half the width, outside by the whole width.
    @Test func strokePositionInsideCentreOutside() {
        let ink: (RGBA) -> Bool = { $0.luma > 0.2 || TextRenderTests.isRed($0) }
        let plain = h.box(h.render(h.text("O")), ink)!
        func styled(_ p: TextStrokePosition) -> Bitmap {
            h.render(h.text("O") { $0.strokeColor = RGBA(1, 0, 0); $0.strokeWidth = 0.1; $0.strokePosition = p })
        }
        let outside = styled(.outside), centre = styled(.center), inside = styled(.inside)
        let wOut = h.box(outside, ink)!.width, wMid = h.box(centre, ink)!.width, wIn = h.box(inside, ink)!.width
        // em = 72 px → w = 7.2 px each side
        #expect(abs(wIn - plain.width) <= 2, "inside \(wIn) vs plain \(plain.width)")
        #expect(abs(wMid - (plain.width + 7.2)) <= 3, "centre \(wMid)")
        #expect(abs(wOut - (plain.width + 14.4)) <= 3, "outside \(wOut)")
        // every position shows the stroke colour; inside eats into the white fill
        let white: (RGBA) -> Bool = { $0.r > 0.9 && $0.g > 0.9 }
        for img in [outside, centre, inside] { #expect(h.count(img, TextRenderTests.isRed) > 300) }
        #expect(h.count(inside, white) < h.count(outside, white) * 3 / 4)
    }

    @Test func strokePositionRoundTripsAndDefaultsToOutside() throws {
        var t = TextContent(string: "A"); t.strokePosition = .inside
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back.strokePosition == .inside)
        let old = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"A","strokeWidth":0.1}"#.utf8))
        #expect(old.strokePosition == .outside)
        t.strokeWidth = 0.1
        #expect(t.strokeExtentEm == 0)
        t.strokePosition = .center
        #expect(abs(t.strokeExtentEm - 0.05) < 1e-9)
    }
}
