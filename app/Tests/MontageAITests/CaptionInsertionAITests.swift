import Testing
import Foundation
@testable import MontageAI
import MontageCore

/// BUG-AUTOCAPTION-SHIFT: the real "Auto captions" edit body (`CaptionGenerator.insert`, incl. speaker colours) run
/// through an `EditSession` on a busy timeline never moves a clip that was already there.
@Suite struct CaptionInsertionAITests {
    static func asset(_ name: String, audioOnly: Bool) -> MediaAsset {
        MediaAsset(name: name, kind: audioOnly ? .audio : .video, url: URL(fileURLWithPath: "/tmp/\(name).mp4"), duration: Time(20),
                   pixelSize: audioOnly ? .zero : .hd1080, frameRate: audioOnly ? nil : .fps30, hasVideo: !audioOnly, hasAudio: true,
                   contentHash: UUID().uuidString)
    }

    static func trackOf(_ tl: Timeline) -> [ClipID: TrackID] {
        var out: [ClipID: TrackID] = [:]
        for t in tl.tracks { for c in t.clips { out[c.id] = t.id } }
        return out
    }

    @Test func generatedCaptionsWithSpeakersKeepExistingClips() throws {
        var p = Project(name: "captions")
        p.timeline.linkage = true
        p.timeline.mainTrackMagnet = true
        let main = (0..<3).map { Self.asset("m\($0)", audioOnly: false) }
        let vo = Self.asset("vo", audioOnly: true), pip = Self.asset("pip", audioOnly: false)
        p.media += main + [vo, pip]
        for a in main {
            var c = TimelineOps.makeClip(for: a, at: Time(1000)); c.duration = Time(4)
            try TimelineOps.insert(c, into: &p)
        }
        var o = TimelineOps.makeClip(for: pip, at: Time(1)); o.duration = Time(5)
        try TimelineOps.insert(o, into: &p, target: .newTrack)
        var v = TimelineOps.makeClip(for: vo, at: Time(0.5)); v.duration = Time(8)
        try TimelineOps.insert(v, into: &p)
        let title = Clip(content: .text(TextContent(string: "Title", fontSize: 0.08)), start: Time(0), duration: Time(6))
        try TimelineOps.insert(title, into: &p, target: .newTrack)

        let before = p.timeline
        let tracks = Self.trackOf(before)
        let times = before.tracks.flatMap(\.clips).map { ($0.id, $0.start, $0.duration) }
        func check(_ tl: Timeline, sourceLocation: SourceLocation = #_sourceLocation) {
            let now = Self.trackOf(tl)
            for (id, start, duration) in times {
                #expect(now[id] == tracks[id], "clip changed track", sourceLocation: sourceLocation)
                #expect(tl.clip(id)?.start == start && tl.clip(id)?.duration == duration, "clip moved", sourceLocation: sourceLocation)
            }
            #expect(tl.tracks.map(\.id).filter { before.tracks.map(\.id).contains($0) } == before.tracks.map(\.id),
                    sourceLocation: sourceLocation)
            #expect(TimelineOps.validate(tl).isEmpty, "\(TimelineOps.validate(tl))", sourceLocation: sourceLocation)
        }

        let segs = (0..<8).map { i -> CaptionSegment in
            let s = Double(i) * 1.4
            return CaptionSegment(text: "w\(i)", start: s, end: s + 1.3, words: [("w\(i)", s, s + 1.3)], speaker: "\(i % 2 + 1)")
        }
        var session = EditSession(project: p)
        try session.perform(Edit("cmd.captions") { p in
            try CaptionGenerator.insert(segs, style: nil, origin: .auto, replacing: true, speakers: true, into: &p)
        })
        check(session.project.timeline)
        #expect(SpeechCaptions.captions(in: session.project.timeline).count == 8)
        #expect(session.project.speakers?.count == 2)

        // a second generation ("Delete current captions" on), then auto lyrics next to them
        try session.perform(Edit("cmd.captions") { p in
            try CaptionGenerator.insert(Array(segs.prefix(3)), style: nil, origin: .auto, replacing: true, speakers: false, into: &p)
        })
        check(session.project.timeline)
        #expect(SpeechCaptions.captions(in: session.project.timeline).count == 3)
        try session.perform(Edit("cmd.lyrics") { p in
            try CaptionGenerator.insert(segs, style: nil, origin: .lyrics, replacing: true, speakers: false, into: &p)
        })
        check(session.project.timeline)
        #expect(CaptionOps.captionTracks(session.project.timeline).count == 2)
        // nothing to add: refused, nothing changes
        #expect(throws: EditError.nothingToDo) {
            try session.perform(Edit("cmd.captions") { p in
                try CaptionGenerator.insert([], style: nil, origin: .auto, replacing: true, speakers: false, into: &p)
            })
        }
        check(session.project.timeline)
    }
}
