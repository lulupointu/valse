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
