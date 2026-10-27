import Testing
import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import AVFoundation
import ValseCore
import ValseEngine
import ValseTestSupport

/// Import breadth (MI-001/MI-013/MI-010/MI-014): probing, background conversion, and rendering through the compositor.
@Suite(.serialized) struct ImportTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("valse-import-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func image(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        paint(ctx)
        return ctx.makeImage()!
    }

    static func solid(_ c: RGBA, _ w: Int = 64, _ h: Int = 64) -> CGImage {
        image(w, h) { $0.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)); $0.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    static func writeAnimated(_ url: URL, type: String, frames: [CGImage], delay: Double) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil)!
        let key: CFString = type == "com.compuserve.gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let dkey: CFString = type == "com.compuserve.gif" ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        for f in frames { CGImageDestinationAddImage(dest, f, [key: [dkey: delay]] as CFDictionary) }
        #expect(CGImageDestinationFinalize(dest))
    }

    static func writeStill(_ url: URL, type: String, _ img: CGImage) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    func importPlayable(_ p: inout TestProject, _ url: URL, target: InsertTarget = .automatic) async throws -> (ClipID, MediaAsset) {
        let a = try await MediaProbe.probe(url)
        try await PlayableMediaCache.shared.ensurePlayable(a)
        let id = try await p.addMedia(url, target: target)
        return (id, a)
    }

    @Test func animatedGIFBecomesVideoClip() async throws {
        let url = Self.dir.appendingPathComponent("anim.gif")
        try Self.writeAnimated(url, type: "com.compuserve.gif", frames: [Self.solid(.red), Self.solid(.green), Self.solid(.blue)], delay: 0.5)
        let a = try await MediaProbe.probe(url)
        #expect(a.kind == .video && a.conversion == .animatedImage)
        #expect(abs(a.duration.seconds - 1.5) < 0.02)
        #expect(PlayableMediaCache.shared.needsConversion(a) || PlayableMediaCache.shared.playableURL(for: a) != nil)
        var p = TestProject()
        let (id, _) = try await importPlayable(&p, url)
        #expect(abs(p[id].duration.seconds - 1.5) < 0.05)
        let c0 = try await p.render(at: 0.25)[0.5, 0.5]
        #expect(c0.isClose(to: .red), "\(c0)")
        #expect(try await p.render(at: 0.75)[0.5, 0.5].isClose(to: .green))
        #expect(try await p.render(at: 1.25)[0.5, 0.5].isClose(to: .blue))
    }

    @Test func animatedPNGKeepsAlpha() async throws {
        // Left half transparent, right half red → over a blue main clip.
        let f = Self.image(64, 64) { $0.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); $0.fill(CGRect(x: 32, y: 0, width: 32, height: 64)) }
        let url = Self.dir.appendingPathComponent("anim.png")
        try Self.writeAnimated(url, type: "public.png", frames: [f, f], delay: 0.5)
        let a = try await MediaProbe.probe(url)
        #expect(a.conversion == .animatedImage && a.techInfo?.hasAlpha == true)
        var p = TestProject(canvas: Size2(180, 180))
        try await p.addVideo(.solid(.blue), seconds: 2, size: CGSize(width: 180, height: 180))
        _ = try await importPlayable(&p, url, target: .newTrack)
        let img = try await p.render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .blue))
        #expect(img[0.75, 0.5].isClose(to: .red))
    }

    @Test func movWithAlphaComposites() async throws {
        // ProRes 4444 with straight alpha written through the converter's writer.
        let f = Self.image(64, 64) { $0.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 64)) }
        let url = Self.dir.appendingPathComponent("alpha.mov")
        try await TestMovies.write(to: url, image: f, seconds: 1, alpha: true)
        let a = try await MediaProbe.probe(url)
        #expect(a.techInfo?.hasAlpha == true)
        var p = TestProject(canvas: Size2(180, 180))
        try await p.addVideo(.solid(.red), seconds: 2, size: CGSize(width: 180, height: 180))
        try await p.addMedia(url, target: .newTrack)
        let img = try await p.render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .green))
        #expect(img[0.75, 0.5].isClose(to: .red))
    }

    @Test func imageSequenceDetectedAndPlayable() async throws {
        let seqDir = Self.dir.appendingPathComponent("seq", isDirectory: true)
        try FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 1...12 {
            let g = Double(i * 20) / 255
            let u = seqDir.appendingPathComponent(String(format: "shot_%04d.png", i))
            Self.writeStill(u, type: "public.png", Self.solid(RGBA(g, g, g)))
            urls.append(u)
        }
        let stray = seqDir.appendingPathComponent("cover.png")
        Self.writeStill(stray, type: "public.png", Self.solid(.white))
        let (seqs, rest) = MediaProbe.detectSequences(urls + [stray])
        #expect(seqs.count == 1 && rest == [stray])
        let s = try #require(seqs.first)
        #expect(s.info.count == 12 && s.info.firstIndex == 1 && s.info.digits == 4)
        let a = try MediaProbe.probeSequence(first: s.first, info: s.info)
        #expect(a.kind == .video && abs(a.duration.seconds - 0.4) < 0.01)
        try await PlayableMediaCache.shared.ensurePlayable(a)
        var p = TestProject()
        p.project.media.append(a)
        try TimelineOps.insert(TimelineOps.makeClip(for: a), into: &p.project)
        // frame index 4 (0-based) = shot_0005 → gray 100
        let g = try await p.render(at: 4.5 / 30).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r
        #expect(abs(g - 100.0 / 255) < 0.04)
    }

    @Test func cameraPhotosAreNotASequence() {
        let urls = (1...30).map { URL(fileURLWithPath: String(format: "/tmp/x/IMG_%04d.JPG", $0)) }
        let (seqs, rest) = MediaProbe.detectSequences(urls)
        #expect(seqs.isEmpty && rest.count == 30)
    }

    @Test func heicStillAndProResProbe() async throws {
        let url = Self.dir.appendingPathComponent("still.heic")
        Self.writeStill(url, type: "public.heic", Self.solid(.green, 128, 96))
        let a = try await MediaProbe.probe(url)
        #expect(a.kind == .image && a.pixelSize == Size2(128, 96))
        var p = TestProject()
        try await p.addMedia(url, duration: 2)
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: .green))

        let pr = try await TestMedia.video(.solid(.red), seconds: 1, codec: .proRes422)
        let b = try await MediaProbe.probe(pr)
        #expect(b.kind == .video && b.codec == "apcn")
    }

    @Test func audioFormatsProbe() async throws {
        let m4a = try await TestMedia.audio(seconds: 2)
        var formats: [(String, [String])] = [("wav", ["-f", "WAVE", "-d", "LEI16"]), ("aiff", ["-f", "AIFF", "-d", "BEI16"]),
                                             ("caf", ["-f", "caff", "-d", "LEI16"]), ("flac", ["-f", "flac", "-d", "flac"]),
                                             ("alac.m4a", ["-f", "m4af", "-d", "alac"])]
        if FFmpegSidecar.isAvailable { formats.append(("mp3", [])) }
        for (ext, args) in formats {
            let out = Self.dir.appendingPathComponent("tone.\(ext)")
            let p = Process()
            if ext == "mp3" {
                p.executableURL = FFmpegSidecar.executableURL
                p.arguments = ["-y", "-loglevel", "error", "-i", m4a.path, out.path]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                p.arguments = args + [m4a.path, out.path]
            }
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }  // codec not available on this machine
            let a = try await MediaProbe.probe(out)
            #expect(a.kind == .audio && a.hasAudio, "\(ext)")
            #expect(abs(a.duration.seconds - 2) < 0.1, "\(ext)")
        }
    }

    @Test func ffmpegFallbackForMKV() async throws {
        guard let ffmpeg = FFmpegSidecar.executableURL, FFmpegSidecar.probeURL != nil else { return }
        let url = Self.dir.appendingPathComponent("red.mkv")
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=160x90:d=1:r=25",
                       "-f", "lavfi", "-i", "sine=f=440:d=1", "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest", url.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let a = try await MediaProbe.probe(url)
        #expect(a.conversion == .ffmpeg && a.kind == .video && a.hasAudio)
        #expect(a.pixelSize == Size2(160, 90))
        #expect(abs(a.duration.seconds - 1) < 0.1)
        var proj = TestProject()
        let (id, _) = try await importPlayable(&proj, url)
        #expect(proj[id].duration > Time(0.9))
        #expect(try await proj.render(at: 0.5)[0.5, 0.5].isClose(to: .red, tolerance: 0.12))
    }

    @Test func ffmpegArgumentsAreLGPLSafe() {
        let args = FFmpegSidecar.transcodeArguments(input: URL(fileURLWithPath: "/a.mkv"), output: URL(fileURLWithPath: "/b.mov"), alpha: false)
        #expect(args.contains("prores_ks") && !args.contains("libx264") && args.contains("pcm_s16le"))
        #expect(FFmpegSidecar.transcodeArguments(input: URL(fileURLWithPath: "/a.mkv"), output: URL(fileURLWithPath: "/b.mov"), alpha: true).contains("yuva444p10le"))
    }

    @Test func variableFrameRateRendersByTimestamp() async throws {
        // Frames at irregular times; gray = 40 * index.
        let url = Self.dir.appendingPathComponent("vfr.mov")
        let times = [0.0, 0.1, 0.15, 0.5, 0.55, 1.0]
        try await TestMovies.write(to: url, times: times, end: 1.2) { i in let g = Double(40 * i) / 255; return RGBA(g, g, g) }
        let a = try await MediaProbe.probe(url)
        #expect(a.techInfo?.isVariableFrameRate == true)
        var p = TestProject()
        try await p.addMedia(url)
        // t = 0.3 → frame 2 (0.15 s); t = 0.8 → frame 4 (0.55 s)
        let g1 = try await p.render(at: 0.3).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r
        let g2 = try await p.render(at: 0.8).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r
        #expect(abs(g1 - 80.0 / 255) < 0.04)
        #expect(abs(g2 - 160.0 / 255) < 0.04)
    }

    @Test func multipleAudioStreamsSelectable() async throws {
        let url = Self.dir.appendingPathComponent("twoaudio.mov")
        try await TestMovies.write(to: url, times: [0], end: 1, audioStreams: 2) { _ in .black }
        let a = try await MediaProbe.probe(url)
        #expect(a.techInfo?.audioTrackCount == 2)
        var p = TestProject()
        let id = try await p.addMedia(url)
        let srcTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        for (i, src) in srcTracks.enumerated() {
            p[id].audioStreamIndex = i
            let built = try await CompositionBuilder.build(project: p.project, purpose: .export)
            let tracks = try await built.composition.loadTracks(withMediaType: .audio)
            let ids = tracks.flatMap { $0.segments.filter { !$0.isEmpty }.map(\.sourceTrackID) }
            #expect(ids == [src.trackID])
        }
    }
}
