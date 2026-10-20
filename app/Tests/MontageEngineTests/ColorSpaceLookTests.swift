@preconcurrency import AVFoundation
import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Colour-space looks (C1, owner project "1019": iPhone HLG / Dolby Vision 8.4): preview AND export of HLG footage in
/// SDR / HLG / PQ projects, per-patch CIEDE2000 against Apple's own rendering of the same source frame
/// (VideoToolbox HDR → SDR tone mapping, the untouched HLG codes, VideoToolbox HLG → PQ).
///
/// Root cause fixed: AVPlayer converted the sources to the video composition's colour space before the compositor
/// (which converts from the asset tags again): SDR preview ΔE ≈ 13 (red skin), PQ preview ≈ 9 (washed out).
@Suite(.serialized) struct ColorSpaceLookTests {
    static let canvas = Size2(270, 480)

    /// Real clips (opt-in, not in the repo): `MONTAGE_C1_FOOTAGE="<file>@<seconds>|…"`, e.g. the owner's 1019 iPhone
    /// clips IMG_7251@2.5|IMG_9079@10|IMG_8815@5|IMG_7250@3. (Not read from ~/Downloads by default: TCC blocks the run.)
    /// Always includes the committed iPhone-like HLG portrait fixture (T1, RealLikeMedia) and `MONTAGE_REAL_FOOTAGE`.
    static var footage: [(URL, Double)] {
        var out: [(URL, Double)] = [(RealLikeMedia.iPhoneHLGPortrait, 1)]
        out += RealLikeMedia.ownerFootage.map { ($0.url, $0.seconds) }
        guard let env = ProcessInfo.processInfo.environment["MONTAGE_C1_FOOTAGE"] else { return out }
        return out + env.split(separator: "|").compactMap { e in
            let p = e.split(separator: "@")
            let u = URL(fileURLWithPath: String(p[0]))
            return FileManager.default.fileExists(atPath: u.path) ? (u, p.count > 1 ? Double(p[1]) ?? 2 : 2) : nil
        }
    }

    /// The live preview frame (PlaybackEngine → AVPlayer → compositor → player video output) at `t`.
    @MainActor static func previewFrame(_ project: Project, at t: Double) async throws -> ColorScience.Frame {
        let engine = PlaybackEngine(project: project)
        // release the player item (its audio taps) before anything else reads the same media
        defer { engine.pause(); engine.player.replaceCurrentItem(with: nil) }
        try await PlaybackProbe.waitReady(engine, timeout: 30)
        engine.seek(to: Time(t), exact: true)
        let target = Time(t).cmTime
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let out = engine.videoOutput, out.hasNewPixelBuffer(forItemTime: target) {
                var shown = CMTime.invalid
                if let pb = out.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &shown), abs(shown.seconds - t) < 0.04 {
                    return ColorScience.frame(pb, size: (Int(canvas.width), Int(canvas.height)))
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "C1", code: 3, userInfo: [NSLocalizedDescriptionKey: "no preview frame at \(t)"])
    }

    /// The exported file's frame at `t` (real Exporter, decoded without colour conversion).
    static func exportFrame(_ project: Project, at t: Double) async throws -> ColorScience.Frame {
        var s = ExportSettings(); s.resolution = .p480
        // from 0 (cheap); mid-project range exports are covered by RangeExportTests (B1: stretched base track stall)
        s.includeAudio = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c1-\(UUID().uuidString).\(s.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter.export(project: project, settings: s, to: url, range: TimeRange(start: .zero, duration: Time(t + 0.2)))
        return try await ColorScience.appleFrame(url, at: t, space: nil, size: (Int(canvas.width), Int(canvas.height)))
    }

    static func project(_ url: URL, space: ProjectColorSpace) async throws -> Project {
        var p = TestProject(canvas: canvas)
        p.project.settings.colorSpace = space
        try await p.addMedia(url)
        return p.project
    }

    struct Result { let preview: ColorScience.Stats; let export: ColorScience.Stats; let previewVsExport: ColorScience.Stats }

    static func measure(_ url: URL, at t: Double, space: ProjectColorSpace, gx: Int = 9, gy: Int = 16,
                        project make: (() async throws -> Project)? = nil) async throws -> Result {
        let size = (Int(canvas.width), Int(canvas.height))
        log("C1 measure \(url.lastPathComponent) \(space)")
        let apple = try await ColorScience.appleFrame(url, at: t, space: space == .hdrHLG ? nil : space, size: size)
        let p: Project
        if let make { p = try await make() } else { p = try await project(url, space: space) }
        let preview = try await previewFrame(p, at: t)
        let export = try await exportFrame(p, at: t)
        return Result(preview: ColorScience.compare(apple, preview, space: space, gx: gx, gy: gy),
                      export: ColorScience.compare(apple, export, space: space, gx: gx, gy: gy),
                      previewVsExport: ColorScience.compare(preview, export, space: space, gx: gx, gy: gy))
    }

    /// CIEDE2000 limits per patch vs Apple. HLG passes the codes through and PQ is the same BT.2100 transcode as
    /// VideoToolbox (preview ≈ 0.2); SDR is our tone curve against Apple's (real footage ≈ 1.6–2.1). The export adds
    /// 480p HEVC / H.264 compression (≈ +0.5–1).
    static func limits(_ space: ProjectColorSpace, export: Bool) -> (mean: Double, p95: Double) {
        switch (space, export) {
        case (.sdr709, _): return (3, 6)
        case (_, false): return (0.6, 1.2)
        case (_, true): return (1.6, 3)
        }
    }

    /// Owner footage (opt-in, `MONTAGE_C1_FOOTAGE`): before the fix the SDR preview was ΔE ≈ 13 (red skin), PQ ≈ 9.
    @Test(arguments: ProjectColorSpace.allCases) func realFootageMatchesApple(space: ProjectColorSpace) async throws {
        for (url, t) in Self.footage {
            let r = try await Self.measure(url, at: t, space: space)
            log("C1 \(url.deletingPathExtension().lastPathComponent)@\(t) \(space.rawValue): preview \(r.preview) | export \(r.export) | preview↔export \(r.previewVsExport)")
            let pl = Self.limits(space, export: false), el = Self.limits(space, export: true)
            #expect(r.preview.mean < pl.mean && r.preview.p95 < pl.p95, "\(url.lastPathComponent) \(space) preview \(r.preview)")
            #expect(r.export.mean < el.mean && r.export.p95 < el.p95, "\(url.lastPathComponent) \(space) export \(r.export)")
            #expect(r.previewVsExport.mean < 1.5, "\(url.lastPathComponent) \(space) preview vs export \(r.previewVsExport)")
        }
    }

    /// Always-run version on an ffmpeg HLG patch clip (greys, skin tones, saturated primaries; 4 × 3 patches): the
    /// preview matches the export in every project space, and Apple's rendering in HLG / PQ. SDR: our tone map
    /// desaturates the fully saturated BT.2020 primaries more than VideoToolbox (worst patch ≈ 11, real footage < 3).
    @Test(arguments: ProjectColorSpace.allCases) func hlgPatchClipMatchesApple(space: ProjectColorSpace) async throws {
        guard let clip = try HDRTests.ffmpegPatchClip(.hlg) else { return }
        let r = try await Self.measure(clip, at: 0.5, space: space, gx: 4, gy: 3) {
            var p = TestProject(canvas: Size2(320, 180))
            p.project.settings.colorSpace = space
            try await p.addMedia(clip)
            return p.project
        }
        log("C1 patches \(space.rawValue): preview \(r.preview) | export \(r.export) | preview↔export \(r.previewVsExport)")
        #expect(r.previewVsExport.mean < 0.5 && r.previewVsExport.max < 1.5, "\(space) preview vs export \(r.previewVsExport)")
        let (mean, mx) = space == .sdr709 ? (4.5, 14.0) : (0.6, 1.5)
        #expect(r.preview.mean < mean && r.preview.max < mx, "\(space) preview \(r.preview)")
        #expect(r.export.mean < mean && r.export.max < mx, "\(space) export \(r.export)")
    }
}

/// Progress lines: printed, and appended to `$C1_LOG` when set (swift test shows stdout only once the run ends).
private func log(_ s: String) {
    print(s)
    guard let path = ProcessInfo.processInfo.environment["C1_LOG"] else { return }
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close()
}
