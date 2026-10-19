import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
@preconcurrency import AVFoundation
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

/// AU-009 "Isolate voice ▸ Music": routed through the HTDemucs vocals / accompaniment stems (fake provider here).
@Suite(.serialized) struct F3MusicIsolationTests {
    /// 48 kHz stereo float CAF of a sine (amplitude `amp`), written on a GCD queue (no blocking AV work on the pool).
    static func writeSine(_ url: URL, hz: Double, amp: Float, seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let n = AVAudioFrameCount(seconds * 48_000)
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
                b.frameLength = n
                for ch in 0..<2 { for i in 0..<Int(n) { b.floatChannelData![ch][i] = amp * Float(sin(2 * .pi * hz * Double(i) / 48_000)) } }
                let f = try! AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try! f.write(from: b)
                c.resume()
            }
        }
    }

    static func rms(_ url: URL) async -> Float {
        await withCheckedContinuation { (c: CheckedContinuation<Float, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let f = try! AVAudioFile(forReading: url)
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
                try! f.read(into: b)
                var s: Float = 0
                let n = Int(b.frameLength)
                for i in 0..<n { let v = b.floatChannelData![0][i]; s += v * v }
                c.resume(returning: (s / Float(max(n, 1))).squareRoot())
            }
        }
    }

    @Test func keepAndRemoveUseTheMusicStems() async throws {
        let a = MediaAsset(name: "song", kind: .audio, url: URL(fileURLWithPath: "/tmp/song-\(UUID().uuidString).m4a"), duration: 1,
                           pixelSize: Size2(0, 0), frameRate: nil, hasVideo: false, hasAudio: true, contentHash: "f3-song-\(UUID().uuidString)")
        let store = AudioStemStore.shared
        await Self.writeSine(store.stemURL(media: a, kind: "demucs-vocals"), hz: 440, amp: 0.5, seconds: 1)
        await Self.writeSine(store.stemURL(media: a, kind: "demucs-novocals"), hz: 110, amp: 0.2, seconds: 1)
        let previous = AudioML.musicStems
        AudioML.musicStems = { _, p in p(1) }
        defer { AudioML.musicStems = previous }
        var props = AudioProps(); props.separation = .keepVocals; props.isolateSource = .music
        let plan = ClipAudioPlan.make(props)
        #expect(plan.render.musicVocals == true && plan.render.mlVoice == nil)
        props.isolateSource = nil
        #expect(ClipAudioPlan.make(props).render.musicVocals == nil)   // speech keeps the voice-isolation path

        let cache = AudioRenderCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("f3-audio-\(UUID().uuidString)"))
        let keep = try await cache.render(a, spec: plan.render)
        var removeSpec = plan.render; removeSpec.separation = .removeVocals
        let remove = try await cache.render(a, spec: removeSpec)
        let k = await Self.rms(keep), r = await Self.rms(remove)
        #expect(abs(Double(k) - 0.5 / 2.0.squareRoot()) < 0.05, "keep rms \(k)")    // vocals only
        #expect(abs(Double(r) - 0.2 / 2.0.squareRoot()) < 0.03, "remove rms \(r)")  // accompaniment only
    }
}

/// CV-014 motion blur direction (frame accumulation over previous / next / both frames).
@Suite(.serialized) struct F3MotionBlurTests {
    @Test func offsetsPerDirection() {
        #expect(MotionBlur(samples: 4).frameOffsets == [-1, -2, -3])
        #expect(MotionBlur(samples: 4, direction: .forward).frameOffsets == [1, 2, 3])
        #expect(MotionBlur(samples: 6, direction: .both).frameOffsets == [-1, 1, -2, 2, -3])
        let old = try? JSONDecoder().decode(MotionBlur.self, from: Data(#"{"amount":0.5,"samples":2}"#.utf8))
        #expect(old?.direction == nil && old?.frameOffsets == [-1])
    }

    /// White box moving right on blue: a trailing blur smears it to the left, a leading one to the right.
    @Test func trailingAndLeadingSmearOppositeWays() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.movingBox(.blue, .white), seconds: 2)
        func centroid(_ b: Bitmap) -> Double {
            var sw = 0.0, sx = 0.0
            for i in 0..<320 {
                let x = (Double(i) + 0.5) / 320
                let w = b[x, 0.5].r   // white box: r≈1, blue background: r≈0
                sw += w; sx += w * x
            }
            return sx / max(sw, 1e-6)
        }
        let sharp = centroid(try await p.render(at: 1))
        p[id].motionBlur = MotionBlur(amount: 1, samples: 6)
        let trailing = centroid(try await p.render(at: 1))
        p[id].motionBlur = MotionBlur(amount: 1, samples: 6, direction: .forward)
        let leading = centroid(try await p.render(at: 1))
        p[id].motionBlur = MotionBlur(amount: 1, samples: 6, direction: .both)
        let both = centroid(try await p.render(at: 1))
        #expect(trailing < sharp - 0.005, "trailing \(trailing) sharp \(sharp)")
        #expect(leading > sharp + 0.005, "leading \(leading) sharp \(sharp)")
        #expect(abs(both - sharp) < abs(trailing - sharp), "both \(both)")
    }
}

/// AU-019 peak + RMS waveform cache.
@Suite struct F3WaveformTests {
    @Test func sineHasRmsAboutPeakOverRootTwo() async throws {
        let url = try await TestMedia.video(.solid(.black), seconds: 1, size: CGSize(width: 64, height: 36), audioHz: 440)
        let w = try await WaveformCache.compute(url)   // reads off the cooperative pool (OffPool)
        #expect(w.rms.count == w.peaks.count && w.peaks.count >= 95)
        let pk = w.peak(from: 0.2, to: 0.8), rm = w.rmsLevel(from: 0.2, to: 0.8)
        #expect(pk > 0.05)
        #expect(abs(rm / pk - 1 / 2.0.squareRoot()) < 0.1, "rms \(rm) peak \(pk)")
        // file round trip
        let back = try #require(Waveform(data: w.data))
        #expect(back.peaks == w.peaks && back.rms == w.rms)
    }

    @Test func rmsLevelAveragesEnergy() {
        let w = Waveform(peaks: [255, 255, 255, 255], rms: [255, 0, 255, 0])
        #expect(abs(w.rmsLevel(from: 0, to: 0.04) - (0.5).squareRoot()) < 1e-9)
        #expect(Waveform(peaks: [200]).rmsLevel(from: 0, to: 0.01) > 0)   // legacy peaks-only fallback
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

    /// TX-040: a text effect on part of the text paints only those characters.
    @Test func textEffectOnARangeOnly() throws {
        let fx = try #require(Registries.textStyles(.effect).first { d in
            // visible on black: a bright outline or a non-white fill
            var t = TextContent(string: "A"); d.restyle(&t)
            func vivid(_ c: RGBA) -> Bool { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) > 0.5 }
            return t.fill == nil && vivid(t.color)
        })
        let plain = h.render(h.text("HHHH"))
        var t = h.text("HHHH")
        t.applyStyle(TextRunStyle(effectID: fx.id), to: TextSpan(0, 2))
        #expect(t.runs.first?.style.effectID == fx.id)
        let styled = h.render(t)
        func diff(_ x0: Int, _ x1: Int) -> Int {
            var n = 0
            for y in 0..<plain.height { for x in x0..<x1 {
                let a = plain.pixel(x, y), b = styled.pixel(x, y)
                if abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 0.3 { n += 1 }
            } }
            return n
        }
        let w = plain.width
        #expect(diff(0, w / 2 - 4) > 200, "effect missing on the range")
        #expect(diff(w / 2 + 12, w) < 30, "effect leaked outside the range")
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
