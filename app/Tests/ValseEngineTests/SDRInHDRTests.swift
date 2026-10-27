@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseTestSupport

/// BUG-SDR-IN-HDR (owner project "1018": iPhone HLG clips + one WhatsApp SDR clip in an HLG project): the SDR clip
/// looked darker, greyer and flatter than the original file in QuickTime, in the preview and in the export.
///
/// Root causes (both covered here, permanently):
/// 1. AVFoundation CONVERTED the SDR source frames to HLG before the compositor (a project mixing HDR and SDR footage,
///    untagged video composition, compositor without `canConformColorOfSourceFrames`), tagged them HLG, and the
///    renderer converted them a second time from the asset's SDR tags (export sky HLG 0.62 instead of 0.73).
/// 2. The SDR → HDR mapping linearised SDR with γ 2.4, Apple displays Rec.709 video with γ 1.961: mid-tones ≈ 30 %
///    darker than the original in Apple's EDR rendering.
/// The definition of correct is the owner's: Apple's rendering of our output ≈ Apple's rendering of the original file
/// (`ColorScience.appleDisplay`: Core Image EDR and AVAssetImageGenerator SDR).
@Suite(.serialized) struct SDRInHDRTests {
    /// SDR chart (8 × 4 patches): neutral ramp, colours, skin / sky.
    static let chart: [[Double]] = [
        [0, 0, 0], [0.1, 0.1, 0.1], [0.2, 0.2, 0.2], [0.35, 0.35, 0.35], [0.5, 0.5, 0.5], [0.65, 0.65, 0.65], [0.8, 0.8, 0.8], [1, 1, 1],
        [0.05, 0.05, 0.05], [0.15, 0.15, 0.15], [0.3, 0.3, 0.3], [0.45, 0.45, 0.45], [0.6, 0.6, 0.6], [0.75, 0.75, 0.75], [0.9, 0.9, 0.9], [0.97, 0.97, 0.97],
        [0.8, 0.1, 0.1], [0.1, 0.7, 0.2], [0.15, 0.2, 0.8], [0.9, 0.85, 0.2], [0.2, 0.8, 0.85], [0.8, 0.2, 0.75], [0.85, 0.65, 0.55], [0.55, 0.75, 0.95],
        [0.4, 0.3, 0.2], [0.2, 0.4, 0.3], [0.3, 0.3, 0.5], [0.9, 0.8, 0.6], [0.6, 0.45, 0.38], [0.95, 0.95, 0.98], [0.7, 0.2, 0.4], [0.98, 0.98, 0.9],
    ]
    static let canvas = Size2(512, 256)
    static let size = (512, 256)

    static func chartPPM(_ w: Int, _ h: Int) -> Data {
        var ppm = Data("P6\n\(w) \(h)\n65535\n".utf8)
        for y in 0..<h { for x in 0..<w { for c in chart[(y * 4 / h) * 8 + x * 8 / w] {
            let v = UInt16((c * 65535).rounded()); ppm.append(UInt8(v >> 8)); ppm.append(UInt8(v & 0xff))
        } } }
        return ppm
    }

    /// The chart as a phone / WhatsApp-like SDR clip: H.264, yuv420p, video range, BT.709 tags.
    static func sdrChartClip() async throws -> URL? {
        guard let ff = HDRTests.ffmpegPath else { return nil }
        return try await TestMedia.cached(TestMedia.directory.appendingPathComponent("sdr-chart-709-v1.mp4")) { tmp in
            let src = TestMedia.directory.appendingPathComponent("sdr-chart-\(UUID().uuidString).ppm")
            try chartPPM(512, 256).write(to: src)
            defer { try? FileManager.default.removeItem(at: src) }
            _ = try HDRTests.shell(ff, ["-v", "error", "-y", "-loop", "1", "-i", src.path, "-t", "1", "-r", "30",
                                        "-vf", "scale=in_range=pc:out_color_matrix=bt709:out_range=tv,format=yuv420p",
                                        "-c:v", "libx264", "-crf", "4", "-color_primaries", "bt709", "-color_trc", "bt709",
                                        "-colorspace", "bt709", "-color_range", "tv", "-f", "mp4", tmp.path])
        }
    }

    /// Real-like SDR footage (the owner's case): 464 × 832 portrait, H.264 Baseline, 60 fps, yuv420p video range,
    /// BT.709 — moving natural-ish content (ffmpeg testsrc2: gradients, colour bars, text).
    static func realLikeSDRClip() async throws -> URL? {
        guard let ff = HDRTests.ffmpegPath else { return nil }
        return try await TestMedia.cached(TestMedia.directory.appendingPathComponent("sdr-portrait-464x832-v1.mp4")) { tmp in
            _ = try HDRTests.shell(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=464x832:rate=60:duration=2",
                                        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
                                        "-c:v", "libx264", "-profile:v", "baseline", "-crf", "16",
                                        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                                        "-color_range", "tv", "-f", "mp4", tmp.path])
        }
    }

    /// The chart as a PNG still (sRGB-tagged, drawn with Core Graphics).
    static func chartStill() throws -> URL {
        try TestMedia.cachedSync(TestMedia.directory.appendingPathComponent("sdr-chart-still-v1.png")) { url in
            let w = 512, h = 256
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, c) in chart.enumerated() {
                ctx.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
                ctx.fill(CGRect(x: (i % 8) * 64, y: h - (i / 8 + 1) * 64, width: 64, height: 64))
            }
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
    }

    /// HDR footage first (so AVFoundation sees a mixed HDR + SDR composition, the owner's case), the SDR media at 2 s.
    static func mixedProject(_ space: ProjectColorSpace, sdr: URL, canvas: Size2 = SDRInHDRTests.canvas) async throws -> Project {
        var p = TestProject(canvas: canvas)
        p.project.settings.colorSpace = space
        try await p.addMedia(RealLikeMedia.iPhoneHLGPortrait, duration: Time(2))
        try await p.addMedia(sdr, at: Time(2), duration: Time(1))
        return p.project
    }

    /// The live preview's composed frame at `t` (code values in the project space, tagged like the preview layer).
    @MainActor static func previewBuffer(_ project: Project, at t: Double, sdrScreen: Bool = false) async throws -> CVPixelBuffer {
        let engine = PlaybackEngine(project: project)
        engine.rendersHDRAsSDR = sdrScreen
        defer { engine.pause(); engine.player.replaceCurrentItem(with: nil) }
        try await PlaybackProbe.waitReady(engine)
        engine.seek(to: Time(t), exact: true)
        let target = Time(t).cmTime
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let out = engine.videoOutput, out.hasNewPixelBuffer(forItemTime: target) {
                var shown = CMTime.invalid
                if let pb = out.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &shown), abs(shown.seconds - t) < 0.04 {
                    let tags = ColorTags(engine.previewColorSpace)
                    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, tags.primaries as CFString, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tags.transfer as CFString, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, tags.matrix as CFString, .shouldPropagate)
                    return pb
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "SDRInHDR", code: 3, userInfo: [NSLocalizedDescriptionKey: "no preview frame at \(t)"])
    }

    /// Exports `project` up to `t + 0.2` s (480p, no audio) and returns the file (caller deletes it).
    static func export(_ project: Project, upTo t: Double) async throws -> URL {
        var s = ExportSettings(); s.resolution = .p480; s.includeAudio = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdrhdr-\(UUID().uuidString).\(s.fileExtension)")
        try await Exporter.export(project: project, settings: s, to: url, range: TimeRange(start: .zero, duration: Time(t + 0.2)))
        return url
    }

    static func codes(_ f: ColorScience.Frame) -> [[Double]] { f.patches(8, 4) }
    static func maxError(_ a: [[Double]], _ b: [[Double]]) -> Double {
        zip(a, b).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
    }

    // MARK: 1. The SDR frames reach the renderer untouched (converted exactly once)

    /// HLG footage + SDR chart: the SDR patches in the preview AND the export are `ColorMath.convert` of the source
    /// codes (before the fix the export's white was HLG 0.68 instead of 0.75: AVFoundation's SDR → HLG + ours).
    /// SDR projects: the SDR chart stays the source codes (bit for bit up to 8-bit decode / compression).
    @Test(arguments: ProjectColorSpace.allCases) func mixedProjectConvertsSDRFramesOnce(space: ProjectColorSpace) async throws {
        guard let clip = try await Self.sdrChartClip() else { return }
        let project = try await Self.mixedProject(space, sdr: clip)
        let want = Self.chart.map { ColorMath.convert($0, from: .sdr, wide: false, to: space.transfer, wide: space.isWideGamut) }
        let pb = try await Self.previewBuffer(project, at: 2.5)
        let preview = Self.codes(ColorScience.frame(pb, size: Self.size))
        let url = try await Self.export(project, upTo: 2.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = Self.codes(try await ColorScience.appleFrame(url, at: 2.5, space: nil, size: Self.size))
        let ep = Self.maxError(preview, want), ee = Self.maxError(export, want)
        print("SDRHDR once \(space): preview max |Δcode| \(ep), export \(ee)")
        #expect(ep < 0.012, "\(space) preview SDR patches off by \(ep)")
        #expect(ee < 0.025, "\(space) export SDR patches off by \(ee) (converted twice?)")
    }

    // MARK: 2. Apple shows the SDR clip in an HDR project like the original file

    struct Look: CustomStringConvertible {
        var exportEDR, exportSDR, previewEDR: ColorScience.Stats
        var description: String { "export EDR \(exportEDR) | export SDR \(exportSDR) | preview EDR \(previewEDR)" }
    }

    static func look(_ space: ProjectColorSpace, sdr: URL, at srcT: Double, gx: Int, gy: Int, canvas: Size2, size: (Int, Int)) async throws -> Look {
        let project = try await mixedProject(space, sdr: sdr, canvas: canvas)
        let t = 2 + srcT
        let srcEDR = try await ColorScience.appleDisplay(sdr, at: srcT, target: .edr, size: size)
        let srcSDR = try await ColorScience.appleDisplay(sdr, at: srcT, target: .sdr, size: size)
        let url = try await export(project, upTo: t)
        defer { try? FileManager.default.removeItem(at: url) }
        let expEDR = try await ColorScience.appleDisplay(url, at: t, target: .edr, size: size)
        let expSDR = try await ColorScience.appleDisplay(url, at: t, target: .sdr, size: size)
        let pb = try await previewBuffer(project, at: t)
        let prevEDR = ColorScience.appleDisplay(pb, target: .edr, size: size)
        return Look(exportEDR: ColorScience.compareApple(srcEDR, expEDR, target: .edr, gx: gx, gy: gy),
                    exportSDR: ColorScience.compareApple(srcSDR, expSDR, target: .sdr, gx: gx, gy: gy),
                    previewEDR: ColorScience.compareApple(srcEDR, prevEDR, target: .edr, gx: gx, gy: gy))
    }

    /// Round trip SDR source → HDR project → Apple's display ≈ Apple's display of the source, chart + real-like clip.
    /// EDR (what an HDR-capable Mac shows, the owner's MacBook): before ΔE00 ≈ 12 (owner export), now < 1.5.
    /// SDR screens: PQ matches too; HLG cannot (Apple's HLG → SDR shows HLG reference white at ≈ 60 % grey, it is fitted
    /// to iPhone grading: putting SDR white higher would blow it out on EDR screens) — guarded against regressions.
    @Test(arguments: [ProjectColorSpace.hdrHLG, .hdrPQ]) func sdrClipLooksLikeTheOriginal(space: ProjectColorSpace) async throws {
        guard let chart = try await Self.sdrChartClip(), let real = try await Self.realLikeSDRClip() else { return }
        let c = try await Self.look(space, sdr: chart, at: 0.5, gx: 8, gy: 4, canvas: Self.canvas, size: Self.size)
        print("SDRHDR look chart \(space): \(c)")
        let r = try await Self.look(space, sdr: real, at: 0.5, gx: 6, gy: 10, canvas: Size2(270, 480), size: (270, 480))
        print("SDRHDR look real-like \(space): \(r)")
        // HLG: Core Image's HLG decode lifts strongly saturated dark colours (pure blue +30 %) above the BT.2100
        // luminance OOTF we invert, hence the looser HLG bounds on testsrc2's saturated bars (greys are exact).
        for (name, l, edr) in [("chart", c, (1.5, 4.0)), ("real-like", r, space == .hdrHLG ? (3.0, 7.0) : (1.5, 4.0))] {
            #expect(l.exportEDR.mean < edr.0 && l.exportEDR.p95 < edr.1, "\(name) \(space) export EDR \(l.exportEDR)")
            #expect(l.previewEDR.mean < edr.0 && l.previewEDR.p95 < edr.1, "\(name) \(space) preview EDR \(l.previewEDR)")
            // before: ≈ 22 (owner export); HLG can't reach the SDR target (see above): regression guard only
            if space == .hdrPQ { #expect(l.exportSDR.mean < 3, "\(name) PQ export SDR \(l.exportSDR)") }
            else { #expect(l.exportSDR.mean < 21, "\(name) HLG export SDR \(l.exportSDR)") }
        }
    }

    /// Non-EDR screens (SDR external monitor, Intel Macs, offscreen UI tests): the player composes the HDR project in
    /// SDR layer by layer. The SDR chart keeps its source codes (shown through the Rec.709-tagged drawable exactly like
    /// QuickTime shows the original; before: HLG white tone-mapped to 0.63 grey) and the HLG footage still matches
    /// Apple's own SDR rendering (C1 limits).
    @Test(arguments: [ProjectColorSpace.hdrHLG, .hdrPQ]) func nonEDRPreviewKeepsSDRMediaAsIs(space: ProjectColorSpace) async throws {
        guard let clip = try await Self.sdrChartClip() else { return }
        let project = try await Self.mixedProject(space, sdr: clip, canvas: Size2(270, 480))
        let sdrPB = try await Self.previewBuffer(project, at: 2.5, sdrScreen: true)
        #expect(CVPixelBufferGetPixelFormatType(sdrPB) == kCVPixelFormatType_32BGRA)
        // the chart is letterboxed in the portrait canvas: compare Apple's SDR display of both instead of raw patches
        let src = try await ColorScience.appleDisplay(clip, at: 0.5, target: .sdr, size: (512, 256))
        let shown = ColorScience.appleDisplay(sdrPB, target: .sdr, size: (270, 480))
        // the 512 × 256 chart fills the 270 × 135 middle band of the 270 × 480 frame
        let band = ColorScience.Frame(width: 270, height: 135, rgb: Array(shown.rgb[(172 * 270 * 3)..<((172 + 135) * 270 * 3)]))
        let d = ColorScience.compareApple(ColorScience.resample(src, to: (270, 135)), band, target: .sdr, gx: 8, gy: 4)
        print("SDRHDR non-EDR preview \(space): SDR chart vs original (Apple SDR display) \(d)")
        #expect(d.mean < 1.5 && d.p95 < 3, "\(space) non-EDR preview of the SDR chart \(d)")
        // HLG footage on the same non-EDR preview vs Apple's SDR rendering of the clip (C1: < 3 mean)
        let hdrPB = try await Self.previewBuffer(project, at: 1, sdrScreen: true)
        let apple = try await ColorScience.appleFrame(RealLikeMedia.iPhoneHLGPortrait, at: 1, space: .sdr709, size: (270, 480))
        let f = ColorScience.compare(apple, ColorScience.frame(hdrPB, size: (270, 480)), space: .sdr709)
        print("SDRHDR non-EDR preview \(space): HLG footage vs Apple SDR \(f)")
        #expect(f.mean < 3 && f.p95 < 6, "\(space) non-EDR preview of HLG footage \(f)")
    }

    /// Home cover thumbnails (`OfflineRenderer.renderFrame(sdr: true)`): the SDR chart keeps its codes in an HDR project
    /// (before: Apple's HLG → SDR of the composed frame, white ≈ 0.6).
    @Test(arguments: [ProjectColorSpace.hdrHLG, .hdrPQ]) func coverThumbnailKeepsSDRMediaAsIs(space: ProjectColorSpace) async throws {
        guard let clip = try await Self.sdrChartClip() else { return }
        let project = try await Self.mixedProject(space, sdr: clip)
        let img = Bitmap(try await OfflineRenderer.renderFrame(project, at: Time(2.5), sdr: true))
        var worst = 0.0
        for (i, c) in Self.chart.enumerated() {
            let a = img.average(x: (Double(i % 8) + 0.25) / 8, y: (Double(i / 8) + 0.25) / 4, w: 0.5 / 8, h: 0.5 / 4)
            worst = max(worst, abs(a.r - c[0]), abs(a.g - c[1]), abs(a.b - c[2]))
        }
        print("SDRHDR cover \(space): max |Δcode| \(worst)")
        #expect(worst < 0.03, "\(space) cover thumbnail SDR chart off by \(worst)")
    }

    /// Owner footage, opt-in (never committed): `VALSE_SDR_FOOTAGE="/path/copy.mp4@10"`.
    @Test(arguments: [ProjectColorSpace.hdrHLG, .hdrPQ]) func ownerSDRFootageLooksLikeTheOriginal(space: ProjectColorSpace) async throws {
        guard let env = ProcessInfo.processInfo.environment["VALSE_SDR_FOOTAGE"], !env.isEmpty else { return }
        let p = env.split(separator: "@")
        let url = URL(fileURLWithPath: String(p[0]))
        let t = p.count > 1 ? Double(p[1]) ?? 2 : 2
        // trim around t so the project stays short (the clip starts at 2 s in the mixed project)
        var project = try await Self.mixedProject(space, sdr: url, canvas: Size2(270, 480))
        if let mi = project.timeline.mainTrackIndex, let ci = project.timeline.tracks[mi].clips.firstIndex(where: { $0.start == Time(2) }) {
            project.timeline.tracks[mi].clips[ci].sourceStart = Time(max(0, t - 0.5))
        }
        let size = (270, 480)
        let srcEDR = try await ColorScience.appleDisplay(url, at: t, target: .edr, size: size)
        let srcSDR = try await ColorScience.appleDisplay(url, at: t, target: .sdr, size: size)
        let exp = try await Self.export(project, upTo: 2.5)
        defer { try? FileManager.default.removeItem(at: exp) }
        let e = ColorScience.compareApple(srcEDR, try await ColorScience.appleDisplay(exp, at: 2.5, target: .edr, size: size), target: .edr, gx: 9, gy: 16)
        let s = ColorScience.compareApple(srcSDR, try await ColorScience.appleDisplay(exp, at: 2.5, target: .sdr, size: size), target: .sdr, gx: 9, gy: 16)
        let pv = ColorScience.compareApple(srcEDR, ColorScience.appleDisplay(try await Self.previewBuffer(project, at: 2.5), target: .edr, size: size),
                                           target: .edr, gx: 9, gy: 16)
        print("SDRHDR owner \(url.lastPathComponent)@\(t) \(space): export EDR \(e) | export SDR \(s) | preview EDR \(pv)")
        // quality study (opt-in): full-size exports (1080 × 1920, default settings) for ffmpeg PSNR / SSIM
        if let dir = ProcessInfo.processInfo.environment["VALSE_SDR_QUALITY_DIR"] {
            for s in [ProjectColorSpace.sdr709, space] {
                var q = TestProject(canvas: Size2(1080, 1920))
                q.project.settings.colorSpace = s
                let id = try await q.addMedia(url, duration: Time(1))
                q[id].sourceStart = Time(max(0, t - 0.5))
                var es = ExportSettings(); es.includeAudio = false
                let out = URL(fileURLWithPath: dir).appendingPathComponent("owner-\(s.rawValue).\(es.fileExtension)")
                try? FileManager.default.removeItem(at: out)
                try await Exporter.export(project: q.project, settings: es, to: out, range: TimeRange(start: .zero, duration: Time(1)))
            }
        }
        #expect(e.mean < 3 && pv.mean < 3, "owner \(space): export EDR \(e), preview EDR \(pv)")
    }

    // MARK: 3. Every SDR-only source uses the same mapping (stills, solids, background; text / stickers = stills' path)

    /// The same still / solid / background in an SDR project (source code values) and in an HDR project: the HDR codes
    /// are `ColorMath.convert` of the SDR ones — the Metal shader and the CPU mirror agree on the SDR → HDR mapping.
    @Test(arguments: [ProjectColorSpace.hdrHLG, .hdrPQ]) func sdrGraphicsUseTheSameMapping(space: ProjectColorSpace) async throws {
        let still = try Self.chartStill()
        // the chart still filling the canvas; a solid over the middle half on a coloured background
        func stillProject(_ s: ProjectColorSpace) async throws -> Project {
            var p = TestProject(canvas: Self.canvas)
            p.project.settings.colorSpace = s
            try await p.addMedia(still, duration: Time(2))
            return p.project
        }
        func solidProject(_ s: ProjectColorSpace) throws -> Project {
            var p = TestProject(canvas: Self.canvas, background: RGBA(0.55, 0.75, 0.95))
            p.project.settings.colorSpace = s
            let id = try p.addSolid(RGBA(0.85, 0.65, 0.55))
            p[id].transform.scale = Vec2(0.5, 1)
            return p.project
        }
        for (name, make) in [("still", { s in try await stillProject(s) }), ("solid+background", { s in try solidProject(s) })]
            as [(String, (ProjectColorSpace) async throws -> Project)] {
            let sdr = Self.codes(ColorScience.frame(try await Self.previewBuffer(try await make(.sdr709), at: 0.5), size: Self.size))
            let hdr = Self.codes(ColorScience.frame(try await Self.previewBuffer(try await make(space), at: 0.5), size: Self.size))
            let want = sdr.map { ColorMath.convert($0, from: .sdr, wide: false, to: space.transfer, wide: true) }
            let err = Self.maxError(hdr, want)
            print("SDRHDR graphics \(name) \(space): max |Δcode| \(err)")
            #expect(err < 0.01, "\(space) \(name): shader vs ColorMath \(err)")
        }
    }

    // MARK: 4. The mapping itself (CPU reference = what the shader mirrors)

    @Test func sdrToHDRUsesApplesRec709DisplayCurve() {
        // SDR white = reference white (HLG 75 %, PQ 203 nits); mid-grey 0.5 = Apple's 0.5^1.961 (not 0.5^2.4)
        let w = ColorMath.convert([1, 1, 1], from: .sdr, wide: false, to: .hlg, wide: true)
        #expect(abs(w[0] - 0.75) < 0.002)
        for tf in [TransferFunction.hlg, .pq] {
            let g = ColorMath.convert([0.5, 0.5, 0.5], from: .sdr, wide: false, to: tf, wide: true)
            let l = ColorMath.toLinear(g, tf, wide: true)
            #expect(abs(l[1] - pow(0.5, 1.961)) < 1e-6, "\(tf) mid grey → \(l[1])")
        }
        // SDR ↔ SDR is untouched (SDR projects bit for bit), HDR → SDR keeps the fitted C1 curve
        #expect(ColorMath.convert([0.3, 0.4, 0.5], from: .sdr, wide: false, to: .sdr, wide: false) == [0.3, 0.4, 0.5])
        #expect(ColorMath.sdrDecodeGamma(to: .sdr) == 2.4)
        #expect(abs(ColorMath.color(RGBA(1, 1, 1), in: .hdrHLG).g - 0.75) < 0.002)
    }
}
