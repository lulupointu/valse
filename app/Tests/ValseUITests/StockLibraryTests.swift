import Testing
import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ValseCore
import ValseEffects
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// Media ▸ Library content (W13): catalogue, generators (render through the real compositor), file rendering, store flow.
@MainActor @Suite(.serialized) struct StockLibraryTests {
    static let small = CGSize(width: 160, height: 90)

    func item(_ id: String) throws -> StockItem { try #require(StockLibrary[id]) }

    func frame(_ i: StockItem, _ t: Double) async throws -> Bitmap {
        try await renderFrame(StockLibrary.project(for: i), at: t, size: Self.small)
    }

    func spread(_ b: Bitmap) -> Double {
        let ps = [(0.1, 0.1), (0.9, 0.1), (0.5, 0.5), (0.1, 0.9), (0.9, 0.9), (0.3, 0.6), (0.7, 0.3)].map { b[$0.0, $0.1] }
        var m = 0.0
        for a in ps { for c in ps { m = max(m, abs(a.r - c.r) + abs(a.g - c.g) + abs(a.b - c.b)) } }
        return m
    }

    func withTempDirectory<T>(_ body: () async throws -> T) async rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("valse-stock-\(UUID().uuidString)")
        StockLibrary.directoryOverride = dir
        defer { StockLibrary.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        return try await body()
    }

    @Test func catalogueInvariants() {
        let ids = StockLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for c in StockLibrary.categories { #expect(!StockLibrary.items(in: c).isEmpty, "empty category \(c)") }
        #expect(StockLibrary.all.allSatisfy { StockLibrary.categories.contains($0.category) })
        #expect(StockLibrary.colors.first?.id == "color.black")
        #expect(StockLibrary.colors.contains { if case .solid(let c) = $0.kind { return c == RGBA(0, 1, 0) }; return false })
        #expect(StockLibrary.all.count >= 45)
        LibraryGenerators.register()
        for i in StockLibrary.all {
            if case .generator(let n, let cs, _, _) = i.recipe {
                #expect(Registries.effects[LibraryGenerators.id(n)] != nil, "missing generator \(n)")
                #expect(cs.count == 3)
            }
        }
    }

    @Test func stringsExistInBothLanguages() {
        ValseBootstrap.registerResources()
        let en = Set(L10n.shared.keys(for: "en")), fr = Set(L10n.shared.keys(for: "fr"))
        var keys = StockLibrary.categories.map { "library.cat.\($0)" } + StockLibrary.all.map(\.nameKey) + ["library.toast.failed"]
        keys += LibraryGenerators.all.map(\.nameKey) + LibraryGenerators.params.map(\.nameKey)
        for k in keys {
            #expect(en.contains(k), "en missing \(k)")
            #expect(fr.contains(k), "fr missing \(k)")
        }
    }

    @Test func generatorsAreHiddenFromCanvasStylePicker() {
        LibraryGenerators.register()
        #expect(Registries.effects(in: .canvas).contains { $0.groupKey == LibraryGenerators.groupKey })
        #expect(Registries.effects(in: .filter).allSatisfy { $0.groupKey != LibraryGenerators.groupKey })
        #expect(Registries.effects(in: .effect).allSatisfy { $0.groupKey != LibraryGenerators.groupKey })
    }

    @Test func searchMatchesNamesAndTags() {
        #expect(StockLibrary.matches(try! item("countdown.modern.3"), "timer"))
        #expect(StockLibrary.matches(try! item("gs.heart"), "LOVE"))
        #expect(!StockLibrary.matches(try! item("gs.heart"), "synthwave"))
        #expect(StockLibrary.all.filter { StockLibrary.matches($0, "green screen") }.count >= 8)
    }

    @Test func greenScreenElementsKeepPureGreenCorners() async throws {
        for id in ["gs.like", "gs.arrow", "gs.heart", "gs.ring"] {
            let i = try item(id)
            let b = try await frame(i, 1.0)
            for (x, y) in [(0.02, 0.03), (0.97, 0.03), (0.02, 0.96), (0.97, 0.96)] {
                #expect(b[x, y].isClose(to: RGBA(0, 1, 0), tolerance: 0.06), "\(id) corner \(b[x, y])")
            }
            // the element itself is not green
            // the element itself is drawn (some non-green pixels)
            let drawn = stride(from: 0, to: b.pixels.count, by: 4).filter { b.pixels[$0] > 120 || b.pixels[$0 + 2] > 120 }.count
            #expect(drawn > b.width * b.height / 200, "\(id) looks empty")
        }
    }

    @Test func backgroundsAreNotFlatAndAnimate() async throws {
        for id in ["bg.aurora", "bg.plasma", "bg.synthwave", "bg.bokeh", "bg.liquid"] {
            let i = try item(id)
            let a = try await frame(i, 0.5), b = try await frame(i, 3.0)
            #expect(spread(a) > 0.12, "\(id) looks flat")
            let changed = zip(a.pixels, b.pixels).filter { abs(Int($0) - Int($1)) > 12 }.count
            #expect(changed > a.pixels.count / 50, "\(id) does not animate")
        }
    }

    @Test func gradientCornersDiffer() async throws {
        for id in ["gradient.sunset", "gradient.ocean", "gradient.lavender"] {
            let b = try await frame(try item(id), 0)
            let p = b[0.03, 0.03], q = b[0.97, 0.97]
            #expect(abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 0.2, "\(id)")
        }
    }

    @Test func countdownChangesEverySecond() async throws {
        let i = try item("countdown.modern.3")
        #expect(StockLibrary.project(for: i).timeline.tracks.contains { $0.kind == .text && $0.clips.count == 3 })
        let a = try await frame(i, 0.5), b = try await frame(i, 1.5)
        let ca = a.average(x: 0.4, y: 0.3, w: 0.2, h: 0.4), cb = b.average(x: 0.4, y: 0.3, w: 0.2, h: 0.4)
        let diff = (0..<40).map { k -> Double in
            let x = 0.38 + Double(k % 8) * 0.03, y = 0.3 + Double(k / 8) * 0.08
            let p = a[x, y], q = b[x, y]; return abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)
        }.max() ?? 0
        #expect(diff > 0.3, "digits did not change (\(ca) vs \(cb))")
    }

    @Test func videoFileHasRightDurationAndIsPlayable() async throws {
        try await withTempDirectory {
            let i = try item("gs.sweep")
            let url = StockLibrary.directory.appendingPathComponent("short.mp4")
            try await StockLibrary.render(i, to: url, seconds: 1)
            let asset = AVURLAsset(url: url)
            let d = try await asset.load(.duration).seconds
            #expect(abs(d - 1) < 0.1)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let size = try await tracks.first?.load(.naturalSize)
            #expect(size == CGSize(width: 1920, height: 1080))
        }
    }

    @Test func stillFileAndCachedThumbnail() async throws {
        try await withTempDirectory {
            let i = try item("gradient.mint")
            #expect(StockLibrary.cachedFile(i) == nil)
            let url = try await StockLibrary.file(i)
            #expect(StockLibrary.cachedFile(i) == url)
            let img = try #require(StockLibrary.loadImage(url))
            #expect(img.width == 1920 && img.height == 1080)
            let t = try #require(await StockLibrary.thumbnail(i, height: 72))
            #expect(t.height == 72)
            #expect(FileManager.default.fileExists(atPath: StockLibrary.thumbnailURL(i, height: 72).path))
            let frames = await StockLibrary.previewFrames(try item("bg.waves"), count: 3, height: 54)
            #expect(frames.count == 3)
        }
    }

    @Test func addStockItemAddsClips() async throws {
        try await withTempDirectory {
            let s = EditorStore()
            s.autosaveEnabled = false
            s.addStockItem(try item("color.chroma"))
            #expect(s.project.timeline.allClips.count == 1)
            if case .solid(let c) = s.project.timeline.allClips.first?.content { #expect(c == RGBA(0, 1, 0)) } else { Issue.record("not solid") }
            s.addStockItem(try item("gradient.fire"), at: Time(3))
            for _ in 0..<3000 where s.project.timeline.allClips.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(s.project.media.count == 1)
            #expect(s.project.media.first?.kind == .image)
            #expect(s.project.timeline.allClips.count == 2)
            #expect(StockLibraryState.shared.rendering.isEmpty)
            // a second add reuses the bin asset
            s.addStockItem(try item("gradient.fire"))
            for _ in 0..<3000 where s.project.timeline.allClips.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(s.project.media.count == 1)
        }
    }

    @Test func dragPayloadRoundTrip() {
        #expect(DragPayload.parseStock(DragPayload.stock("bg.aurora")) == "bg.aurora")
        #expect(DragPayload.parseStock("valse-effect:x") == nil)
    }

    /// Visual review: `VALSE_STOCK_DUMP=/path swift test --filter StockLibraryTests/dumpContactSheet` writes a PNG of
    /// every card thumbnail (plus time strips of video items).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_STOCK_DUMP"] != nil)) func dumpContactSheet() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VALSE_STOCK_DUMP"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await withTempDirectory {
            let h = 180, w = 320, cols = 5
            for cat in StockLibrary.categories {
                let items = StockLibrary.items(in: cat)
                var imgs: [CGImage] = []
                let t0 = Date()
                for i in items {
                    if case .solid = i.kind { continue }
                    let times = i.isVideo ? [i.thumbnailTime, i.duration * 0.6] : [0]
                    imgs += try await StockLibrary.frames(i, times: times, height: h)
                }
                print("contact \(cat): \(imgs.count) frames in \(Date().timeIntervalSince(t0)) s")
                guard !imgs.isEmpty else { continue }
                let rows = (imgs.count + cols - 1) / cols
                let ctx = CGContext(data: nil, width: cols * w, height: rows * h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                for (k, img) in imgs.enumerated() {
                    ctx.draw(img, in: CGRect(x: (k % cols) * w, y: (rows - 1 - k / cols) * h, width: w, height: h))
                }
                try StockLibrary.writePNG(ctx.makeImage()!, to: dir.appendingPathComponent("\(cat).png"))
            }
            // timings
            let t0 = Date()
            _ = await StockLibrary.thumbnail(try item("bg.aurora"), height: 72)
            print("thumbnail 72px: \(Date().timeIntervalSince(t0)) s")
            let t1 = Date()
            _ = try await StockLibrary.file(try item("bg.synthwave"))
            print("render 8 s 1080p video: \(Date().timeIntervalSince(t1)) s")
        }
    }
}
