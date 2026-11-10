import Testing
import Foundation
@testable import ValseCore

/// Compound clips: no stretching past the nested content (outside), any clip lengthenable (inside).
@Suite struct CompoundTrimTests {
    @Test func outsideCompoundCannotExtendPastItsContent() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        let cid = try TimelineOps.createCompound([ids[0], ids[1]], name: "C", in: &p)
        let c = try #require(p.timeline.clip(cid))
        try TimelineOps.trim(cid, edge: .tail, to: c.end + Time(5), in: &p)
        #expect(p.timeline.clip(cid)?.duration == c.duration)
        // shortening then lengthening is bounded by the content again
        try TimelineOps.trim(cid, edge: .tail, to: c.end - Time(1), in: &p)
        try TimelineOps.trim(cid, edge: .tail, to: c.end + Time(5), in: &p)
        #expect(p.timeline.clip(cid)?.duration == c.duration)
    }

    @Test func insideCompoundAnyClipCanBeLengthened() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        let cid = try TimelineOps.createCompound([ids[0], ids[1]], name: "C", in: &p)
        try CompoundEditing.enter(cid, in: &p)
        let clips = p.timeline.mainTrack!.clips
        let first = clips[0], second = clips[1]
        // shorten the first by 1 s, then lengthen it back: the second is not the last... it must still work
        try TimelineOps.trim(first.id, edge: .tail, to: first.end - Time(1), in: &p)
        try TimelineOps.trim(first.id, edge: .tail, to: first.end, in: &p)
        #expect(p.timeline.clip(first.id)?.end == first.end)
        // lengthening past the neighbour pushes it (shorten, butt the neighbour against it, lengthen again)
        try TimelineOps.trim(first.id, edge: .tail, to: first.end - Time(1), in: &p)
        let mi = try #require(p.timeline.mainTrackIndex)
        p.timeline.tracks[mi].clips[1].start = second.start - Time(1)
        try TimelineOps.trim(first.id, edge: .tail, to: first.end, in: &p)
        #expect(p.timeline.clip(first.id)?.end == first.end)
        #expect(p.timeline.clip(second.id)?.start == second.start)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // the head stops at the previous clip instead of throwing
        try TimelineOps.trim(second.id, edge: .head, to: .zero, in: &p)
        #expect(p.timeline.clip(second.id)?.start == first.end)
    }
}
