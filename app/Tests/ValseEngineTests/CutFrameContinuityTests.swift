@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-FRAME-DROP ("a frame drop effect, sometimes, and it carries to the exports", project "1018 (1)"): after a split
/// of iPhone HEVC footage, the frames right after the cut froze on the clip's first frame for up to 3 frames (100 ms),
/// then jumped. Cause: AVFoundation decodes a composition track's segments of one file as one stream; on the A/B lane's
/// next clip it kept decoding from the previous segment instead of restarting at the sync sample, and in open GOPs the
/// leading B frames of the next CRA key frame were then never delivered. Repro: the owner's 5 clips (contiguous splits
/// of IMG_9081 at 0.671 / 1.109 / 1.623 / 2.149 s), the 4th starting on the P frame right before a CRA (frame 108 of a
/// 28-frame GOP, B frames 109–111 decoded after the CRA). Fix: `CompositionBuilder.decodeVariants` / `decodeAlias`.
@Suite struct CutFrameContinuityTests {
    static let fps = 30.0

    /// iPhone-structured stream (`TestMovies.writeFrameIndexHEVC`): HEVC, 30 fps, 5 s, open GOPs of 28 frames (CRA key
    /// frames at 28, 56, 84, 112 …, flagged in the `sync` sample group like IMG_9081; an x265 file without that group
    /// did NOT reproduce). Each frame shows its index as stripes.
    static func openGOPClip() async throws -> URL {
        try await TestMedia.cached(TestMedia.directory.appendingPathComponent("frame-drop-opengop-v2.mov")) { tmp in
            try await TestMovies.writeFrameIndexHEVC(to: tmp, frames: 150)
        }
    }

    /// The owner's layout: (timeline start, duration, source start) in seconds.
    static let ownerSplits: [(Double, Double, Double)] = [(0, 0.671, 1.981), (0.671, 0.438, 2.652), (1.109, 0.514, 3.090),
                                                           (1.623, 0.526, 3.604), (2.149, 0.562, 4.130)]

    static func project(_ clip: URL, layout: [(Double, Double, Double)], overlay: Bool = false) async throws -> Project {
        var p = TestProject(canvas: Size2(224, 128))
        try await p.addMedia(clip)
        let main = try #require(p.project.timeline.tracks.firstIndex { $0.isMain })
        let base = try #require(p.project.timeline.tracks[main].clips.first)
        let clips = layout.map { (start, dur, src) -> Clip in
            var c = base
            c.id = ClipID()
            c.start = Time(start); c.duration = Time(dur); c.sourceStart = Time(src)
            return c
        }
        if overlay {
            // a long main clip underneath; the overlay (one lane: no transitions) covers the canvas
            var under = base
            under.start = .zero; under.duration = Time(layout.map { $0.0 + $0.1 }.max() ?? 1); under.sourceStart = .zero
            p.project.timeline.tracks[main].clips = [under]
            p.project.timeline.tracks.append(Track(kind: .video, clips: clips))
        } else {
            p.project.timeline.tracks[main].clips = clips
        }
        return p.project
    }

    /// Source frame the timeline shows at `t` (top track with a clip there), nil outside every clip.
    static func expectedFrame(_ project: Project, at t: Double) -> Int? {
        for track in project.timeline.tracks.reversed() {
            guard let c = track.clips.first(where: { $0.start.seconds <= t + 1e-6 && t + 1e-6 < $0.end.seconds }) else { continue }
            return Int(((c.sourceStart.seconds + t - c.start.seconds) * fps + 1e-4).rounded(.down))
        }
        return nil
    }

    /// (time, shown frame) for every frame of `asset`: read through `composition` (the compositor's output) or the
    /// file's own video track.
    static func frames(_ asset: AVAsset, composition: AVVideoComposition? = nil) async throws -> [(Double, Int)] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let composition {
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await asset.loadTracks(withMediaType: .video), videoSettings: settings)
            o.videoComposition = composition
            output = o
        } else {
            output = AVAssetReaderTrackOutput(track: try #require(try await asset.loadTracks(withMediaType: .video).first), outputSettings: settings)
        }
        reader.add(output)
        let box = UncheckedSendable((reader, output))
        return try await OffPool.run { _ in   // blocking reads: off the cooperative pool
            let (reader, output) = box.value
            var out: [(Double, Int)] = []
            guard reader.startReading() else { return out }
            while let s = output.copyNextSampleBuffer() {
                if let pb = CMSampleBufferGetImageBuffer(s) { out.append((CMSampleBufferGetPresentationTimeStamp(s).seconds, TestMovies.frameIndex(stripes: pb))) }
            }
            return out
        }
    }

    static func check(_ shown: [(Double, Int)], _ project: Project, _ label: String) {
        #expect(shown.count >= Int(project.duration.seconds * fps) - 1, "\(label): \(shown.count) frames")
        var wrong: [String] = []
        for (t, got) in shown {
            guard let want = expectedFrame(project, at: t), got != want else { continue }
            wrong.append(String(format: "%.3f s: frame %d instead of %d", t, got, want))
        }
        #expect(wrong.isEmpty, "\(label): \(wrong.count) wrong frames — \(wrong.prefix(8).joined(separator: "; "))")
    }

    @Test func splitsBeforeAnOpenGOPKeyFrameShowEveryFrame() async throws {
        let clip = try await Self.openGOPClip()
        let project = try await Self.project(clip, layout: Self.ownerSplits)
        // preview composition (what AVPlayer plays) and export composition, read through the compositor
        for purpose in [RenderPurpose.preview, .export] {
            let built = try await CompositionBuilder.build(project: project, purpose: purpose)
            Self.check(try await Self.frames(built.composition, composition: built.videoComposition), project, "\(purpose)")
        }
        // the exported file itself
        var s = ExportSettings(); s.codec = .h264; s.resolution = .p480
        let out = try await exportProject(project, settings: s)
        defer { try? FileManager.default.removeItem(at: out.url) }
        Self.check(try await Self.frames(AVURLAsset(url: out.url)), project, "exported file")
    }

    /// One-lane track (overlay, no transition): a jump cut whose second clip starts on the P frame before a CRA.
    @Test func overlayJumpCutBeforeAnOpenGOPKeyFrameShowsEveryFrame() async throws {
        let clip = try await Self.openGOPClip()
        let project = try await Self.project(clip, layout: [(0, 0.438, 2.652), (0.438, 0.526, 3.604)], overlay: true)
        let built = try await CompositionBuilder.build(project: project, purpose: .export)
        Self.check(try await Self.frames(built.composition, composition: built.videoComposition), project, "overlay")
    }

    /// Variant choice: a track's segment keeps its stream only when it continues it (same file, contiguous source).
    @Test func decodeVariantsSwitchOnlyOnDiscontinuities() {
        let a = URL(fileURLWithPath: "/media/a.mov"), b = URL(fileURLWithPath: "/media/b.mov")
        func seg(_ out: Double, _ src: Double, _ d: Double) -> (output: TimeRange, source: TimeRange) {
            (TimeRange(start: Time(out), duration: Time(d)), TimeRange(start: Time(src), duration: Time(d)))
        }
        var clip = Clip(content: .solid(.black), start: .zero, duration: Time(2))
        clip.sourceStart = Time(1)
        let tol = Time(1.0 / 60)
        // first segment on a track, then two contiguous speed pieces
        let (v0, r0) = CompositionBuilder.decodeVariants(clip: clip, segments: [seg(0, 0, 1), seg(1, 1, 1)], url: a, after: nil, tolerance: tol)
        #expect(v0 == [0, 0] && r0 == .init(url: a, variant: 0, end: Time(3)))
        // a split continuing the run keeps the variant; a jump in the same file switches it
        clip.sourceStart = Time(3)
        #expect(CompositionBuilder.decodeVariants(clip: clip, segments: [seg(0, 0, 1)], url: a, after: r0, tolerance: tol).variants == [0])
        clip.sourceStart = Time(3.5)
        let (v1, r1) = CompositionBuilder.decodeVariants(clip: clip, segments: [seg(0, 0, 1)], url: a, after: r0, tolerance: tol)
        #expect(v1 == [1] && r1?.variant == 1)
        #expect(CompositionBuilder.decodeVariants(clip: clip, segments: [seg(0, 2, 1)], url: a, after: r1, tolerance: tol).variants == [0])
        // another file starts its own stream
        #expect(CompositionBuilder.decodeVariants(clip: clip, segments: [seg(0, 0, 1)], url: b, after: r1, tolerance: tol).variants == [0])
        // the alias is the same file under another URL
        let alias = CompositionBuilder.decodeAlias(a)
        #expect(alias != a && alias.standardizedFileURL == a.standardizedFileURL && alias.lastPathComponent == "a.mov")
    }
}
