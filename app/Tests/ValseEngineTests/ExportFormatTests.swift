@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
import ValseCore
import ValseEngine
import ValseTestSupport

/// W11: every export format / option checked with ffprobe (codec, profile, bit depth, colour tags, alpha, duration,
/// fps, audio streams) + range, GIF frame count, audio-only, stills, captions, interchange.
@Suite(.serialized) struct ExportFormatTests {
    static var hasFFprobe: Bool { MediaInfo.ffprobePath != nil }

    func project(_ seconds: Double = 2, audio: Bool = true) async throws -> TestProject {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.movingBox(.blue, .white), seconds: seconds, audioHz: audio ? 440 : nil)
        return p
    }

    func settings(_ edit: (inout ExportSettings) -> Void = { _ in }) -> ExportSettings {
        var s = ExportSettings(); s.resolution = .p480; edit(&s); return s
    }

    // MARK: Codecs

    @Test func h264DefaultIsMovHighProfileRec709WithAAC() async throws {
        let r = try await project().export(seconds: 1, settings: settings())
        #expect(r.url.pathExtension == "mov")
        #expect(r.probe.videoCodec == "h264")
        #expect(r.probe.width == 854 && r.probe.height == 480)
        #expect(abs(r.probe.duration - 1) < 0.06)
        guard Self.hasFFprobe else { return }
        #expect(r.probe.profile == "High")
        #expect(r.probe.pixelFormat == "yuv420p")
        #expect(r.probe.colorPrimaries == "bt709" && r.probe.colorTransfer == "bt709" && r.probe.colorMatrix == "bt709")
        #expect(r.probe.majorBrand == "qt  ")
        #expect(r.probe.audioCodec == "aac" && r.probe.audioStreamCount == 1)
        #expect(r.probe.audioSampleRate == 48000 && r.probe.audioChannels == 2)
        #expect(r.probe.frameCount == 30)
        #expect((r.probe.videoStartTime ?? 1) < 0.001)
    }

    /// EX-016: "Speed up hardware encoding" off → the software VideoToolbox encoders give the same format.
    @Test(arguments: [ExportSettings.Codec.h264, .hevc])
    func softwareEncoderWhenHardwareIsOff(_ codec: ExportSettings.Codec) async throws {
        let r = try await project(audio: false).export(seconds: 0.5, settings: settings { $0.codec = codec; $0.preferHardware = false })
        #expect(r.probe.videoCodec == (codec == .h264 ? "h264" : "hevc"))
        #expect(r.probe.width == 854 && r.probe.height == 480)
        guard Self.hasFFprobe else { return }
        #expect(r.probe.frameCount == 15)
        #expect(r.probe.colorPrimaries == "bt709")
    }

    @Test func mp4Container() async throws {
        let r = try await project(audio: false).export(seconds: 0.5, settings: settings { $0.container = .mp4 })
        #expect(r.url.pathExtension == "mp4")
        guard Self.hasFFprobe else { return }
        #expect(r.probe.majorBrand != "qt  " && r.probe.majorBrand != nil)
        #expect(!r.probe.hasAudio)
    }

    @Test func hevc8And10Bit() async throws {
        let p = try await project(audio: false)
        let r8 = try await p.export(seconds: 0.5, settings: settings { $0.codec = .hevc })
        #expect(r8.probe.videoCodec == "hevc")
        let r10 = try await p.export(seconds: 0.5, settings: settings { $0.codec = .hevc; $0.bitDepth = .ten })
        #expect(r10.probe.videoCodec == "hevc")
        guard Self.hasFFprobe else { return }
        #expect(r8.probe.profile == "Main" && r8.probe.pixelFormat == "yuv420p", "\(String(describing: r8.probe.pixelFormat)) \(r8.url.path)")
        #expect(r10.probe.profile == "Main 10" && r10.probe.pixelFormat == "yuv420p10le")
        #expect(r10.probe.colorPrimaries == "bt709" && r10.probe.colorTransfer == "bt709")
        // 10-bit SDR goes through the 16-bit compositor: picture still correct
        let f = try await Self.frame(r10.url, at: 0.25)
        #expect(f.average(x: 0.05, y: 0.05, w: 0.1, h: 0.1).isClose(to: .blue, tolerance: 0.1))
    }

    @Test(arguments: [
        (ExportSettings.Codec.proRes422Proxy, "Proxy", "yuv422p10le"), (.proRes422LT, "LT", "yuv422p10le"),
        (.proRes422, "Standard", "yuv422p10le"), (.proRes422HQ, "HQ", "yuv422p10le"),
        (.proRes4444, "4444", "yuv444p12le"), (.proRes4444XQ, "XQ", "yuv444p12le"),
    ])
    func proResVariants(codec: ExportSettings.Codec, profile: String, pix: String) async throws {
        let r = try await project(1).export(seconds: 0.3, settings: settings { $0.codec = codec; $0.container = .mp4 })
        #expect(r.url.pathExtension == "mov")       // ProRes forces QuickTime
        #expect(r.probe.videoCodec == "prores")
        guard Self.hasFFprobe else { return }
        #expect(r.probe.profile?.replacingOccurrences(of: " ", with: "") == profile, "\(r.probe.profile ?? "-")")
        #expect(r.probe.pixelFormat == pix, "\(r.probe.pixelFormat ?? "-")")
        #expect(r.probe.colorPrimaries == "bt709")
    }

    // MARK: Alpha

    func alphaProject() async throws -> TestProject {
        var p = TestProject(canvas: Size2(320, 180))
        let id = try await p.addVideo(.solid(.red), seconds: 1)
        p[id].transform.scale = Vec2(0.5, 0.5)
        return p
    }

    @Test func proRes4444WithAlphaKeepsTransparency() async throws {
        let r = try await alphaProject().export(seconds: 0.3, settings: settings { $0.codec = .proRes4444; $0.alpha = true })
        if Self.hasFFprobe { #expect(r.probe.pixelFormat == "yuva444p12le", "\(r.probe.pixelFormat ?? "-")") }
        #expect(try await Self.containsAlpha(r.url))
        let px = try await Self.bgraFrame(r.url)
        #expect(px.alpha(0.05, 0.05) < 0.02)                // outside the layer: transparent
        #expect(px.alpha(0.5, 0.5) > 0.98)                  // layer: opaque red
        #expect(px.rgb(0.5, 0.5).isClose(to: .red, tolerance: 0.06))
        // without alpha the background is opaque black
        let opaque = try await alphaProject().export(seconds: 0.3, settings: settings { $0.codec = .proRes4444 })
        #expect(try await Self.bgraFrame(opaque.url).alpha(0.05, 0.05) > 0.98)
    }

    @Test func hevcWithAlpha() async throws {
        let r = try await alphaProject().export(seconds: 0.3, settings: settings { $0.codec = .hevc; $0.alpha = true })
        #expect(r.probe.videoCodec == "hevc")
        #expect(try await Self.containsAlpha(r.url))
        let px = try await Self.bgraFrame(r.url)
        #expect(px.alpha(0.05, 0.05) < 0.05 && px.alpha(0.5, 0.5) > 0.95)
    }

    // MARK: Resolution / frame rate / bit rate

    @Test func resolutionsUpTo4KAnd8K() async throws {
        var s = ExportSettings()
        #expect(ExportSettings.Resolution.allCases.map(\.label) == ["480P", "720P", "1080P", "2K", "4K", "8K"])
        for (res, w, h) in [(ExportSettings.Resolution.p720, 1280, 720), (.p1440, 2560, 1440), (.p2160, 3840, 2160), (.p4320, 7680, 4320)] {
            s.resolution = res
            #expect(s.outputSize(canvas: .hd1080) == (w, h))
        }
        s.resolution = .p1080
        #expect(s.outputSize(canvas: Size2(1080, 1920)) == (1080, 1920))
        let p = try await project(1, audio: false)
        let r4 = try await p.export(seconds: 0.2, settings: settings { $0.resolution = .p2160; $0.codec = .hevc })
        #expect(r4.probe.width == 3840 && r4.probe.height == 2160)
        // 8K: H.264 is upgraded to HEVC
        let r8 = try await p.export(seconds: 0.1, settings: settings { $0.resolution = .p4320 })
        #expect(r8.probe.videoCodec == "hevc" && r8.probe.width == 7680 && r8.probe.height == 4320)
    }

    @Test(arguments: [(FrameRate.fps23_976, 24000.0 / 1001), (.fps25, 25), (.fps29_97, 30000.0 / 1001), (.fps50, 50), (.fps60, 60)])
    func frameRates(rate: FrameRate, fps: Double) async throws {
        let r = try await project(2, audio: false).export(seconds: 1, settings: settings { $0.frameRate = rate })
        #expect(abs((r.probe.nominalFPS ?? r.probe.fps) - fps) < 0.001, "\(r.probe.nominalFPS ?? r.probe.fps)")
        if let n = r.probe.frameCount { #expect(abs(Double(n) - fps) <= 1, "\(n)") }
        #expect(abs(r.probe.duration - 1) < 0.06)
    }

    @Test func bitratePresetsAreOrderedAndCustomIsHonoured() async throws {
        var s = settings(); s.resolution = .p1080
        let canvas = Size2.hd1080
        var rates: [Int] = []
        for m in [ExportSettings.BitrateMode.lower, .recommended, .higher] { s.bitrateMode = m; rates.append(s.videoBitrate(canvas: canvas)) }
        #expect(rates[0] < rates[1] && rates[1] < rates[2])
        s.bitrateMode = .recommended
        #expect(abs(Double(rates[1]) / 1e6 - 11.8) < 1)    // CapCut: 1080p30 recommended ≈ 12 Mbps (48 s → 72 MB)
        let est = s.estimatedBytes(duration: 48, canvas: canvas)
        #expect(est > 60_000_000 && est < 85_000_000)
        s.codec = .hevc
        #expect(s.videoBitrate(canvas: canvas) < rates[1])
        // custom bit rate reaches the encoder (noisy-enough content: moving box)
        guard Self.hasFFprobe else { return }
        let p = try await project(2, audio: false)
        let low = try await p.export(seconds: 2, settings: settings { $0.bitrateMode = .custom; $0.customBitrateMbps = 0.5 })
        let high = try await p.export(seconds: 2, settings: settings { $0.bitrateMode = .custom; $0.customBitrateMbps = 8; $0.rateControl = .cbr })
        let lowSize = try FileManager.default.attributesOfItem(atPath: low.url.path)[.size] as! Int
        let highSize = try FileManager.default.attributesOfItem(atPath: high.url.path)[.size] as! Int
        #expect(lowSize < highSize, "\(lowSize) vs \(highSize)")
        #expect(Double(lowSize) * 8 / 2 < 1_000_000, "\(lowSize)")
    }

    // MARK: Colour

    @Test func hdrToneMappedToSDR() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        p.project.settings.colorSpace = .hdrHLG
        try await p.addVideo(.solid(.white), seconds: 1)
        let hdr = try await p.export(seconds: 0.3, settings: settings())
        let sdr = try await p.export(seconds: 0.3, settings: settings { $0.toneMapToSDR = true })
        #expect(hdr.probe.videoCodec == "hevc")
        #expect(sdr.probe.videoCodec == "h264")
        guard Self.hasFFprobe else { return }
        #expect(hdr.probe.colorTransfer == "arib-std-b67" && hdr.probe.pixelFormat == "yuv420p10le")
        #expect(sdr.probe.colorTransfer == "bt709" && sdr.probe.colorPrimaries == "bt709" && sdr.probe.pixelFormat == "yuv420p")
        let f = try await Self.frame(sdr.url, at: 0.1)
        #expect(f[0.5, 0.5].luma > 0.9)
    }

    // MARK: Range / cover / aspect / metadata

    @Test func rangeExportStartsAtZeroWithTheRightFrames() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.frameIndex, seconds: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("range-\(UUID()).mov")
        let range = TimeRange(start: Time(1), duration: Time(1))
        try await Exporter.export(project: p.project, settings: settings(), to: url, range: range)
        let info = try await MediaInfo.probe(url)
        #expect(abs(info.duration - 1) < 0.06)
        if Self.hasFFprobe { #expect(info.frameCount == 30); #expect((info.videoStartTime ?? 1) < 0.001) }
        // frame 0 of the file = source frame 30 (grey level 30*4 = 120)
        let first = try await Self.frame(url, at: 0)
        #expect(abs(first[0.5, 0.5].r * 255 - 120) < 8, "\(first[0.5, 0.5].r * 255)")
        let later = try await Self.frame(url, at: 0.5)     // source frame 45 → 180
        #expect(abs(later[0.5, 0.5].r * 255 - 180) < 8, "\(later[0.5, 0.5].r * 255)")
    }

    @Test func prependCoverAddsTheCoverFrameFirst() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.frameIndex, seconds: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID()).mov")
        try await Exporter.export(project: p.project, settings: settings { $0.prependCover = true }, to: url,
                                  range: TimeRange(start: .zero, duration: Time(1)), options: ExportOptions(coverTime: Time(1.5)))
        let info = try await MediaInfo.probe(url)
        if Self.hasFFprobe { #expect(info.frameCount == 31, "\(info.frameCount ?? -1)") }
        let first = try await Self.frame(url, at: 0)        // source frame 45 → 180
        #expect(abs(first[0.5, 0.5].r * 255 - 180) < 8, "\(first[0.5, 0.5].r * 255)")
        let second = try await Self.frame(url, at: 1.0 / 30 + 0.001)
        #expect(second[0.5, 0.5].r * 255 < 12)
    }

    @Test func aspectPresetReframesTheCanvas() async throws {
        let p = try await project(1, audio: false)
        let r = try await p.export(seconds: 0.3, settings: settings { $0.aspect = .portrait9x16 })
        #expect(r.probe.width == 480 && r.probe.height == 854)
        var s = ExportSettings()
        ExportPreset.preset("tiktok")!.apply(to: &s, projectRate: .fps30)
        #expect(s.outputSize(canvas: .hd1080) == (1080, 1920) && s.container == .mp4 && s.bitrateMode == .custom)
        ExportPreset.preset("instagramPortrait")!.apply(to: &s, projectRate: .fps60)
        #expect(s.outputSize(canvas: .hd1080) == (1080, 1350) && s.frameRate.fps <= 30)
    }

    @Test func titleAndCoverArtworkMetadata() async throws {
        let p = try await project(1, audio: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID()).mp4")
        let jpeg = try await StillFrameExporter.coverJPEG(project: p.project, at: Time(0.5))
        try await Exporter.export(project: p.project, settings: settings { $0.container = .mp4 }, to: url,
                                  range: TimeRange(start: .zero, duration: Time(0.3)), options: ExportOptions(title: "My film", artworkJPEG: jpeg))
        let md = try await AVURLAsset(url: url).load(.commonMetadata)
        let title = try await AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
        #expect(title == "My film")
        let art = try await AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierArtwork).first?.load(.dataValue)
        #expect((art?.count ?? 0) > 1000)
    }

    // MARK: GIF

    @Test func gifFrameCountSizeAndColours() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.split(.red, .green), seconds: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID()).gif")
        try await GIFExporter.export(project: p.project, settings: GIFSettings(resolution: .p240, fps: 15), to: url)
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 30)
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 10, nil))
        #expect(img.width == 426 && img.height == 240)
        let b = Bitmap(img)
        #expect(b.average(x: 0.1, y: 0.4, w: 0.2, h: 0.2).isClose(to: .red, tolerance: 0.1))
        #expect(b.average(x: 0.7, y: 0.4, w: 0.2, h: 0.2).isClose(to: .green, tolerance: 0.1))
        if Self.hasFFprobe {
            let info = try await MediaInfo.probe(url)
            #expect(info.videoCodec == "gif" && info.frameCount == 30, "\(info)")
            #expect(abs(info.duration - 2) < 0.1, "\(info.duration)")
        }
        // 640P and range
        try await GIFExporter.export(project: p.project, settings: GIFSettings(resolution: .p640, fps: 10), to: url,
                                     range: TimeRange(start: Time(0.5), duration: Time(1)))
        let src2 = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(src2) == 10)
        #expect(CGImageSourceCreateImageAtIndex(src2, 0, nil)?.width == 1138)
    }

    @Test func gifLZWRoundTripsNoisyFrames() throws {
        // LZW table resets (> 4096 codes) on noise; ImageIO must decode the exact indices back.
        let w = 200, h = 150
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(w * h) { px[4 * i] = UInt8.random(in: 0...255, using: &rng); px[4 * i + 1] = UInt8.random(in: 0...255, using: &rng); px[4 * i + 2] = UInt8(i % 256) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noise-\(UUID()).gif")
        let enc = try GIFEncoder(url: url, width: w, height: h, fps: 25)
        enc.dither = false
        px.withUnsafeBytes { enc.addFrame(bgra: $0.baseAddress!, bytesPerRow: w * 4) }
        px.withUnsafeBytes { enc.addFrame(bgra: $0.baseAddress!, bytesPerRow: w * 4) }
        enc.finish()
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 2)
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 1, nil))
        let b = Bitmap(img)
        #expect(b.width == w && b.height == h)
        // Without dithering each pixel maps to its nearest palette colour: mean error stays small
        var err = 0.0
        for y in stride(from: 0, to: h, by: 7) { for x in stride(from: 0, to: w, by: 7) {
            let i = (y * w + x) * 4
            let p = b.pixel(x, y)
            err += abs(p.r * 255 - Double(px[i + 2])) + abs(p.g * 255 - Double(px[i + 1])) + abs(p.b * 255 - Double(px[i]))
        } }
        let samples = Double(((h + 6) / 7) * ((w + 6) / 7))
        #expect(err / samples / 3 < 24, "\(err / samples / 3)")
    }

    // MARK: Audio only

    @Test func audioOnlyFormats() async throws {
        let p = try await project(2)
        let r = TimeRange(start: .zero, duration: Time(1))
        for (fmt, codec) in [(AudioOutputSettings.Format.wav, "pcm_s24le"), (.aac, "aac"), (.flac, "flac"), (.alac, "alac")] {
            var s = AudioOutputSettings(); s.format = fmt; s.bitDepth = 24; s.bitrateKbps = 256
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID()).\(fmt.fileExtension)")
            try await AudioOnlyExporter.export(project: p.project, settings: s, to: url, range: r)
            let info = try await MediaInfo.probe(url)
            #expect(abs(info.duration - 1) < 0.08, "\(fmt) \(info.duration)")
            if Self.hasFFprobe {
                #expect(info.audioCodec == codec, "\(fmt) \(info.audioCodec ?? "-")")
                #expect(info.audioSampleRate == 48000 && info.audioChannels == 2 && info.videoCodec == nil)
            }
        }
    }

    @Test func mp3ThroughTheFFmpegSidecar() async throws {
        guard await MP3Encoder.isAvailable() else { return }
        let p = try await project(2)
        var s = AudioOutputSettings(); s.format = .mp3; s.bitrateKbps = 320; s.sampleRate = 44100
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID()).mp3")
        try await AudioOnlyExporter.export(project: p.project, settings: s, to: url)
        let info = try await MediaInfo.probe(url)
        #expect(abs(info.duration - 2) < 0.1, "\(info.duration)")
        guard Self.hasFFprobe else { return }
        #expect(info.audioCodec == "mp3" && info.audioSampleRate == 44100 && info.audioChannels == 2)
        #expect(abs(Double(info.formatBitRate ?? 0) - 320_000) < 20_000, "\(info.formatBitRate ?? 0)")
    }

    // MARK: Stills

    @Test func stillFramePNGAndJPEG() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.split(.red, .blue), seconds: 1)
        for f in StillFrameExporter.Format.allCases {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID()).\(f.fileExtension)")
            try await StillFrameExporter.export(project: p.project, at: Time(0.5), to: url)
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(src) as String? == (f == .png ? "public.png" : "public.jpeg"))
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect(img.width == 640 && img.height == 360)
            let b = Bitmap(img)
            #expect(b[0.2, 0.5].isClose(to: .red) && b[0.8, 0.5].isClose(to: .blue))
        }
    }

    // MARK: Captions

    @Test func captionsSRTAndBurnIn() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.solid(.black), seconds: 4)
        try CaptionFile.insert([CaptionCue(start: Time(0.5), end: Time(1.5), text: "Bonjour"),
                                CaptionCue(start: Time(2), end: Time(3.25), text: "le monde")], into: &p.project)
        #expect(CaptionExport.serialize(p.project, format: .srt) ==
                "1\n00:00:00,500 --> 00:00:01,500\nBonjour\n\n2\n00:00:02,000 --> 00:00:03,250\nle monde\n")
        #expect(CaptionExport.serialize(p.project, format: .txt) == "Bonjour\nle monde\n")
        #expect(CaptionExport.serialize(p.project, format: .vtt).hasPrefix("WEBVTT\n\n1\n00:00:00.500 --> 00:00:01.500\nBonjour"))
        #expect(CaptionExport.serialize(p.project, format: .ass).contains("Dialogue: "))
        #expect(CaptionExport.serialize(p.project, format: .lrc).contains("[00:00.50]Bonjour"))
        // round trip through the text engine's parser
        let back = try CaptionFiles.parse(CaptionExport.serialize(p.project, format: .srt), format: .srt)
        #expect(back.map(\.text) == ["Bonjour", "le monde"] && back[1].end == 3.25)
        // range-relative
        let ranged = CaptionExport.segments(p.project, range: TimeRange(start: Time(1), duration: Time(2)))
        #expect(ranged.count == 2 && ranged[0].start == 0 && ranged[0].end == 0.5 && ranged[1].end == 2)
        // burn-in off hides caption tracks only in the export copy
        var s = ExportSettings(); s.burnCaptions = false
        let prepared = Exporter.prepare(p.project, for: s)
        let ids = CaptionExport.captionTrackIDs(p.project)
        #expect(!ids.isEmpty && prepared.timeline.tracks.filter { ids.contains($0.id) }.allSatisfy(\.isHidden))
        let burnt = try await renderFrame(p.project, at: 1)
        let clean = try await renderFrame(prepared, at: 1)
        let area = (x: 0.2, y: 0.8, w: 0.6, h: 0.15)
        #expect(burnt.average(x: area.x, y: area.y, w: area.w, h: area.h).luma > clean.average(x: area.x, y: area.y, w: area.w, h: area.h).luma + 0.01)
    }

    /// UX_GAPS W11-3: plain titles are not "captions" for burn-in: no burnable track, and burn-in off never hides them
    /// (they still export as a caption file through the text-track fallback).
    @Test func burnInOnlyConcernsRealCaptionTracks() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.solid(.black), seconds: 2)
        _ = try p.addText("Title", duration: Time(2))
        #expect(CaptionExport.burnableTrackIDs(p.project).isEmpty)
        #expect(CaptionExport.hasCaptions(p.project))
        var s = ExportSettings(); s.burnCaptions = false
        let hiddenWithoutCaptions = Exporter.prepare(p.project, for: s).timeline.tracks.filter { $0.isHidden }.count
        #expect(hiddenWithoutCaptions == 0)
        #expect(CaptionOps.addCaptionTrack([CaptionSegment(text: "hi", start: 0, end: 1)], to: &p.project, origin: .auto) != nil)
        let burnable = CaptionExport.burnableTrackIDs(p.project)
        #expect(burnable.count == 1)
        let prepared = Exporter.prepare(p.project, for: s)
        let hidden = prepared.timeline.tracks.filter { $0.isHidden }.map { $0.id }
        #expect(hidden == burnable)
    }

    @Test func autoCaptionTrackExportsWithWordTimingsAndOtherTextIgnored() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.solid(.black), seconds: 4)
        // a plain title on its own text track must not end up in the caption file once a caption track exists
        _ = try p.addText("Title", duration: Time(4))
        let seg = CaptionSegment(text: "hello world", start: 1, end: 2, words: [("hello", 1, 1.4), ("world", 1.5, 2)])
        #expect(CaptionOps.addCaptionTrack([seg], to: &p.project, origin: .auto) != nil)
        #expect(CaptionExport.segments(p.project).map(\.text) == ["hello world"])
        let ranged = CaptionExport.segments(p.project, range: TimeRange(start: Time(1.2), duration: Time(2)))
        #expect(ranged.count == 1 && ranged[0].start == 0 && abs(ranged[0].words[0].start) < 1e-9 && abs(ranged[0].words[1].start - 0.3) < 1e-9)
        #expect(CaptionExport.serialize(p.project, format: .ass).contains("\\k"))
        // sidecar written by the job next to the video
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        var spec = ExportJobSpec(project: p.project, title: "Caps", folder: dir)
        spec.captions = .srt
        let urls = try await ExportRunner.run(spec)
        #expect(try String(contentsOf: urls[0], encoding: .utf8).contains("00:00:01,000 --> 00:00:02,000\nhello world"))
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Interchange

    @Test func fcpxmlStructure() async throws {
        var p = TestProject(canvas: Size2(1920, 1080))
        let a = try await p.addVideo(.solid(.red), seconds: 3, audioHz: 440)
        let b = try await p.addVideo(.solid(.blue), seconds: 3, at: Time(3))
        try TimelineOps.setTransition(a, TransitionInstance(typeID: "x", duration: Time(1)), in: &p.project.timeline)
        p[a].audio.volume = 0.5
        _ = b
        try p.addText("Title", at: Time(1), duration: Time(1))
        let xml = TimelineInterchange.fcpxml(p.project, name: "Film")
        let doc = try XMLDocument(xmlString: xml)
        #expect(try doc.nodes(forXPath: "/fcpxml/@version").first?.stringValue == "1.10")
        let spine = try #require(try doc.nodes(forXPath: "//spine").first as? XMLElement)
        let kids = spine.children?.compactMap { $0 as? XMLElement } ?? []
        #expect(kids.map(\.name) == ["asset-clip", "transition", "asset-clip"], "\(kids.map(\.name))")
        // clip A trimmed by half the transition, B starts at the overlap start + 0.5 s
        #expect(kids[0].attribute(forName: "duration")?.stringValue == "5/2s")
        #expect(kids[1].attribute(forName: "offset")?.stringValue == "2s" && kids[1].attribute(forName: "duration")?.stringValue == "1s")
        #expect(kids[2].attribute(forName: "offset")?.stringValue == "5/2s")
        #expect(kids[2].attribute(forName: "start")?.stringValue == "1/2s")
        #expect(try doc.nodes(forXPath: "//sequence/@duration").first?.stringValue == "5s")
        #expect(try doc.nodes(forXPath: "//asset-clip/adjust-volume/@amount").first?.stringValue == "-6.0206dB")
        let title = try #require(try doc.nodes(forXPath: "//title").first as? XMLElement)
        #expect(title.attribute(forName: "lane")?.stringValue == "1")
        #expect(title.attribute(forName: "offset")?.stringValue == "1s")
        #expect(try doc.nodes(forXPath: "//media-rep/@src").count == 2)
        // EDL + OTIO
        let edl = TimelineInterchange.edl(p.project, name: "Film")
        #expect(edl.contains("TITLE: FILM") && edl.contains(" C        00:00:00:00 00:00:03:00 00:00:00:00 00:00:03:00"))
        #expect(edl.contains(" D    030 "))
        let otio = try JSONSerialization.jsonObject(with: Data(TimelineInterchange.otio(p.project, name: "Film").utf8)) as! [String: Any]
        #expect(otio["OTIO_SCHEMA"] as? String == "Timeline.1")
    }

    // MARK: Job runner

    @Test func jobWritesEveryCheckedOutputWithUniqueNames() async throws {
        var p = try await project(1)
        try CaptionFile.insert([CaptionCue(start: .zero, end: Time(0.5), text: "Hi")], into: &p.project)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Clip.mov").path, contents: Data())
        var spec = ExportJobSpec(project: p.project, title: "Clip", folder: folder)
        spec.video = settings()
        var a = AudioOutputSettings(); a.format = .wav; spec.audio = a
        spec.gif = GIFSettings()
        spec.captions = .srt
        spec.timeline = .fcpxml
        let outs = spec.plannedOutputs()
        #expect(outs.map(\.url.lastPathComponent) == ["Clip (1).mov", "Clip.wav", "Clip.gif", "Clip.srt", "Clip.fcpxml"])
        let box = ProgressBox()
        let urls = try await ExportRunner.run(spec, outputs: outs) { box.add($0) }
        #expect(urls.count == 5 && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(box.values.last == 1 && box.isMonotonic)
        #expect(spec.estimatedBytes > 0)
        let pre = ExportPreflight.check(p.project, neededBytes: spec.estimatedBytes, folder: folder)
        #expect(pre.isOK && pre.freeBytes != nil)
        var broken = p.project
        broken.media[0].url = URL(fileURLWithPath: "/nonexistent/\(UUID()).mp4")
        #expect(ExportPreflight.check(broken, neededBytes: 0, folder: folder).missingMedia.count == 1)
    }

    @Test func jobCancelDeletesPartialFiles() async throws {
        let p = try await project(4)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jobc-\(UUID())")
        var spec = ExportJobSpec(project: p.project, title: "C", folder: folder)
        spec.video = settings()
        let outs = spec.plannedOutputs()
        let task = Task { try await ExportRunner.run(spec, outputs: outs) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: ExportError.cancelled) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: outs[0].url.path))
    }

    // MARK: Settings persistence

    @Test func settingsDecodeWithDefaultsForMissingFields() throws {
        let old = #"{"codec":"hevc","resolution":720,"frameRate":{"numerator":25,"denominator":1},"bitrateMode":"higher","customBitrateMbps":20,"includeAudio":true,"audioBitrateKbps":192,"preferHardware":true}"#
        let s = try JSONDecoder().decode(ExportSettings.self, from: Data(old.utf8))
        #expect(s.codec == .hevc && s.resolution == .p720 && s.frameRate == .fps25 && s.bitrateMode == .higher)
        #expect(s.container == .mp4 && !s.alpha && s.burnCaptions && s.aspect == .original)
        let round = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }

    // MARK: helpers

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _v: [Double] = []
        func add(_ x: Double) { lock.withLock { _v.append(x) } }
        var values: [Double] { lock.withLock { _v } }
        var isMonotonic: Bool { let v = values; return zip(v, v.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } }
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> Bitmap {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (img, _) = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return Bitmap(img)
    }

    static func containsAlpha(_ url: URL) async throws -> Bool {
        guard let t = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let f = try await t.load(.formatDescriptions).first else { return false }
        return (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) == true
    }

    struct BGRAFrame {
        let w: Int, h: Int, bpr: Int, data: [UInt8]
        func at(_ x: Double, _ y: Double) -> Int { Int(y * Double(h - 1)) * bpr + Int(x * Double(w - 1)) * 4 }
        func alpha(_ x: Double, _ y: Double) -> Double { Double(data[at(x, y) + 3]) / 255 }
        func rgb(_ x: Double, _ y: Double) -> RGBA { let i = at(x, y); return RGBA(Double(data[i + 2]) / 255, Double(data[i + 1]) / 255, Double(data[i]) / 255) }
    }

    /// First frame as straight BGRA (alpha untouched).
    static func bgraFrame(_ url: URL) async throws -> BGRAFrame {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o)
        // blocking read: off the cooperative pool (valse-gotchas)
        let frame: BGRAFrame? = try await OffPool.run { _ in
            r.startReading()
            defer { r.cancelReading() }
            guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let bpr = CVPixelBufferGetBytesPerRow(pb), h = CVPixelBufferGetHeight(pb)
            let data = [UInt8](UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddress(pb), count: bpr * h))
            return BGRAFrame(w: CVPixelBufferGetWidth(pb), h: h, bpr: bpr, data: data)
        }
        return try #require(frame, "no first frame in \(url.lastPathComponent): \(r.error.map { "\($0)" } ?? "-")")
    }
}
