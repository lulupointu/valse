@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// B1: an export range starting mid-project hung on the owner's iPhone clip IMG_9079 (project 1019) at 1 s / 10 s while
/// full and from-0 exports worked. Root cause: the composition's base track was the 1-s blank file STRETCHED to the
/// project duration; for some durations (32.735 s here) an AVAssetReader whose time range starts inside the stretched
/// samples never delivers a frame. The base track now tiles the blank unscaled (`CompositionBuilder.addBase`).
@Suite struct RangeExportTests {
    /// iPhone-like clip: 10-bit HEVC Main10, HLG / BT.2020 tags, B-frames, 90° display rotation, AAC stereo (ffmpeg).
    static func iPhoneLikeClip() throws -> URL? {
        guard let ff = HDRTests.ffmpegPath else { return nil }
        let url = TestMedia.directory.appendingPathComponent("b1-iphone-hlg-46s.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = TestMedia.directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }   // left only when ffmpeg failed (shell throws)
        _ = try HDRTests.shell(ff, ["-v", "error", "-y", "-display_rotation", "90",
                                    "-f", "lavfi", "-i", "testsrc2=size=192x108:rate=30",
                                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "46",
                                    "-vf", "format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast",
                                    "-x265-params", "log-level=error:bframes=2:keyint=60:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited",
                                    "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67",
                                    "-colorspace", "bt2020nc", "-color_range", "tv", "-c:a", "aac", "-ac", "2", tmp.path])
        guard FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        if (try? FileManager.default.moveItem(at: tmp, to: url)) == nil { try? FileManager.default.removeItem(at: tmp) }
        return url
    }

    /// Exports `range`; a STALLED export — no progress for `timeout` s (the B1 bug: the reader never delivers a frame,
    /// progress stays at 0 forever) — is cancelled and reported as a failure instead of hanging. Progress-based, not
    /// wall-clock: a slow export on a loaded machine keeps reporting progress and is never cancelled.
    static func export(_ project: Project, range: TimeRange, timeout: Double = 90) async throws -> MediaInfo {
        var s = ExportSettings(); s.resolution = .p480
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("valse-b1-\(UUID().uuidString).\(s.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        let progress = ExportProgressBox()
        let work = Task { try await Exporter.export(project: project, settings: s, to: url, range: range, progress: { progress.set($0) }) }
        let watchdog = Task {
            var last = progress.get(), since = Date()
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
                let now = progress.get()
                if now != last { last = now; since = Date() } else if Date().timeIntervalSince(since) > timeout { work.cancel(); return }
            }
        }
        defer { watchdog.cancel() }
        do { try await work.value } catch ExportError.cancelled {
            Issue.record("range export \(range.start.seconds)+\(range.duration.seconds) s stalled (no progress for \(timeout) s, at \(progress.get()))")
            throw ExportError.cancelled
        }
        return try await MediaInfo.probe(url)
    }

    static func hlgProject(_ clip: URL, duration: Double? = nil) async throws -> Project {
        var p = TestProject(canvas: Size2(108, 192))
        p.project.settings.colorSpace = .hdrHLG
        try await p.addMedia(clip, duration: duration.map { Time($0) })
        return p.project
    }

    /// Durations whose stretched base track stalled a mid-project read (32.735 s = IMG_9079), starts 1 s and 10 s.
    @Test(arguments: [32.735, 32.7, 45.123])
    func rangeExportStartingMidProjectFinishes(duration: Double) async throws {
        guard let clip = try Self.iPhoneLikeClip() else { return }   // no ffmpeg on this machine
        let project = try await Self.hlgProject(clip, duration: duration)
        #expect(abs(project.duration.seconds - duration) < 0.001)
        for start in [1.0, 10.0] {
            let info = try await Self.export(project, range: TimeRange(start: Time(start), duration: Time(1)))
            #expect(abs(info.duration - 1) < 0.1, "start \(start): \(info.duration) s")
            #expect(info.videoCodec != nil && info.hasAudio)
        }
    }

    /// The base track covers the project exactly, with unscaled pieces of the blank file.
    @Test func baseTrackIsTiledUnscaled() async throws {
        var p = TestProject()
        try p.addSolid(.red, duration: Time(125.37))
        let built = try await CompositionBuilder.build(project: p.project, purpose: .export)
        let base = try #require(try await built.composition.loadTracks(withMediaType: .video).first)
        let segs = base.segments
        #expect(segs.count == 3)
        for s in segs {
            #expect(CMTimeCompare(s.timeMapping.source.duration, s.timeMapping.target.duration) == 0)
        }
        #expect(abs(base.timeRange.duration.seconds - 125.37) < 1e-6)
    }

    /// The owner's clip (opt-in, not in the repo; use a COPY): `VALSE_B1_CLIP=<copy of IMG_9079.mov>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_B1_CLIP"] != nil))
    func ownerClipRangeExport() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VALSE_B1_CLIP"]!)
        try #require(FileManager.default.fileExists(atPath: url.path))
        let project = try await Self.hlgProject(url)
        for start in [0.0, 1.0, 10.0] {
            let info = try await Self.export(project, range: TimeRange(start: Time(start), duration: Time(2)))
            #expect(abs(info.duration - 2) < 0.1, "start \(start): \(info.duration) s")
        }
    }
}

/// Last progress value of an export (watchdog of `RangeExportTests.export`).
final class ExportProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}
