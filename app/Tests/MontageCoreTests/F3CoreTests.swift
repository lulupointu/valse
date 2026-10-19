import Testing
import Foundation
@testable import MontageCore

/// Finisher F3 model / logic tests.
struct F3CoreTests {
    // AU-004
    @Test func volumeNudgeStepsTenthsOfADecibel() {
        let up = VolumeNudge.nudged(0.5, by: 0.1)             // −6.02 → −5.9 dB
        #expect(abs(VolumeNudge.db(up) - -5.9) < 1e-9)
        let down = VolumeNudge.nudged(1, by: -0.1)
        #expect(abs(VolumeNudge.db(down) - -0.1) < 1e-9)
        #expect(VolumeNudge.nudged(10, by: 0.1) == 10)          // capped at +20 dB
        #expect(VolumeNudge.nudged(0, by: -0.1) == 0)           // silent stays silent
        #expect(abs(VolumeNudge.db(VolumeNudge.nudged(0, by: 0.1)) - VolumeNudge.floorDB) < 1e-9)
        #expect(VolumeNudge.nudged(VolumeNudge.gain(-60), by: -0.1) == 0)
        // 10 presses = +1 dB exactly (no drift)
        var g = 1.0
        for _ in 0..<10 { g = VolumeNudge.nudged(g, by: 0.1) }
        #expect(abs(VolumeNudge.db(g) - 1) < 1e-9)
    }

    // CV-006
    @Test func cropGeometryRotationStaysInsideTheSource() throws {
        let plain = CropRect(left: 0.1, top: 0.2, right: 0.3, bottom: 0.05)
        let m = CropGeometry.affine(plain, aspect: 16.0 / 9)
        #expect(abs(m.a - 0.6) < 1e-12 && abs(m.d - 0.75) < 1e-12 && m.b == 0 && m.c == 0 && m.tx == 0.1 && m.ty == 0.2)
        #expect(CropGeometry.fitZoom(plain, aspect: 16.0 / 9) == 1)
        for deg in [-45.0, -12.5, 7, 30, 45, 90] {
            for c in [CropRect(rotation: deg), CropRect(left: 0.3, top: 0.1, right: 0.05, bottom: 0.4, rotation: deg)] {
                let z = CropGeometry.fitZoom(c, aspect: 16.0 / 9)
                #expect(z > 0 && z <= 1)
                for (x, y) in CropGeometry.sampledCorners(c, aspect: 16.0 / 9) {
                    #expect(x >= -1e-9 && x <= 1 + 1e-9 && y >= -1e-9 && y <= 1 + 1e-9, "\(deg)°: corner \(x),\(y)")
                }
                // the window keeps its centre
                let cs = CropGeometry.sampledCorners(c, aspect: 16.0 / 9)
                let mx = cs.map(\.0).reduce(0, +) / 4, my = cs.map(\.1).reduce(0, +) / 4
                #expect(abs(mx - (c.left + 1 - c.right) / 2) < 1e-9 && abs(my - (c.top + 1 - c.bottom) / 2) < 1e-9)
            }
        }
        // old files: no rotation key
        let old = try JSONDecoder().decode(CropRect.self, from: Data(#"{"left":0.1,"top":0,"right":0,"bottom":0}"#.utf8))
        #expect(old.rotation == nil && !old.isIdentity && CropRect(rotation: 5).isIdentity == false)
    }

    // MI-020
    @Test func captionEncodingOverride() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nПривет мир\n"
        let cp1251 = srt.data(using: .windowsCP1251)!
        // auto reads legacy bytes as Windows-1252 (wrong letters) — the override fixes it
        #expect(CaptionEncoding.auto.decode(cp1251)?.contains("Привет") == false)
        let fixed = try #require(CaptionEncoding.windows1251.decode(cp1251))
        #expect(CaptionFile.parse(fixed, format: .srt).first?.text == "Привет мир")
        let jp = "こんにちは"
        #expect(CaptionEncoding.shiftJIS.decode(jp.data(using: .shiftJIS)!) == jp)
        let zh = "你好，世界"
        let gb = CaptionEncoding.gb18030.stringEncoding!
        #expect(CaptionEncoding.gb18030.decode(zh.data(using: gb)!) == zh)
        // BOM handling: forced UTF-8 drops the BOM; auto still detects it
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8)
        #expect(CaptionEncoding.utf8.decode(bom) == "abc" && CaptionEncoding.auto.decode(bom) == "abc")
        // files on disk go through the chosen encoding
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("f3-\(UUID().uuidString).srt")
        try cp1251.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try CaptionFile.load(url, encoding: .windows1251).first?.text == "Привет мир")
        #expect(CaptionEncoding.allCases.count == 12)
    }

    // MI-014
    func multiStreamProject(streams: Int) throws -> (Project, ClipID) {
        var p = Project()
        var a = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/v.mov"), duration: 20, pixelSize: .hd1080,
                           frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "h")
        var info = MediaTechInfo(); info.audioTrackCount = streams; a.techInfo = info
        p.media = [a]
        var c = TimelineOps.makeClip(for: a); c.duration = 10
        try TimelineOps.insert(c, into: &p)
        return (p, c.id)
    }

    @Test func audioStreamPickerAndSeparate() throws {
        var (p, id) = try multiStreamProject(streams: 3)
        #expect(TimelineOps.audioStreamCount(p.timeline.clip(id)!, in: p) == 3)
        try TimelineOps.setAudioStream([id], 2, in: &p)
        #expect(p.timeline.clip(id)?.audioStreamIndex == 2)
        #expect(throws: EditError.self) { try TimelineOps.setAudioStream([id], 2, in: &p) }   // nothing to do
        try TimelineOps.setAudioStream([id], 0, in: &p)
        #expect(p.timeline.clip(id)?.audioStreamIndex == nil)
        // extract keeps the chosen stream
        var q = p
        try TimelineOps.setAudioStream([id], 1, in: &q)
        let x = try TimelineOps.extractAudio(id, in: &q)
        #expect(q.timeline.clip(x)?.audioStreamIndex == 1)
        // separate: one audio clip per stream on its own track, video muted; restore removes them
        let ids = try TimelineOps.separateAudioStreams(id, in: &p)
        #expect(ids.count == 3)
        #expect(ids.map { p.timeline.clip($0)?.audioStreamIndex ?? 0 } == [0, 1, 2])
        #expect(Set(ids.compactMap { p.timeline.locate($0)?.track }).count == 3)
        #expect(p.timeline.clip(id)?.audio.isMuted == true)
        try TimelineOps.restoreAudio(id, in: &p.timeline)
        #expect(p.timeline.allClips.count == 1 && p.timeline.clip(id)?.audio.isMuted == false)
        // single-stream files: nothing to separate
        var (s, sid) = try multiStreamProject(streams: 1)
        #expect(throws: EditError.self) { try TimelineOps.separateAudioStreams(sid, in: &s) }
    }
}
