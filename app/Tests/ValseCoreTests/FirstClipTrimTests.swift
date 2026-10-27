import Testing
@testable import ValseCore

/// BUG-FIRST-CLIP-TRIM-LEFT: the head of the first clip (start 0) whose source start was cut can be dragged left to
/// restore hidden media. Main track (magnetic): the clip grows, stays anchored at 0, the rest ripples right.
@Suite struct FirstClipTrimTests {
    @Test func magneticFirstClipGrowsLeftAndRipplesTheRest() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        try TimelineOps.trim(ids[0], edge: .head, to: 2, in: &p)          // cut 2 s off the start
        #expect(p.timeline.clip(ids[0])!.sourceStart == Time(2))
        #expect(p.timeline.clip(ids[1])!.start == Time(2))
        var text = Clip(content: .text(TextContent(string: "Hi")), start: 3, duration: 1)
        text.name = "t"
        try TimelineOps.insert(text, into: &p)
        #expect(p.timeline.clip(text.id)!.linkedTo == ids[1])
        // drag the head left of 0 (the pointer is over the track headers)
        try TimelineOps.trim(ids[0], edge: .head, to: Time(-1.5), in: &p)
        let c = p.timeline.clip(ids[0])!
        #expect(c.start == .zero && c.duration == Time(3.5) && c.sourceStart == Time(0.5))
        #expect(p.timeline.clip(ids[1])!.start == Time(3.5))               // rippled right
        #expect(p.timeline.clip(text.id)!.start == Time(4.5))              // linked clip follows
        // can't reveal media before the asset's start
        try TimelineOps.trim(ids[0], edge: .head, to: Time(-100), in: &p)
        #expect(p.timeline.clip(ids[0])!.sourceStart == .zero && p.timeline.clip(ids[0])!.duration == Time(4))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func firstClipWithSpeedRestoresSourceAtItsRate() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 4)
        p.timeline[clip: ids[0]]!.sourceStart = 2
        try TimelineOps.setSpeed(ids[0], .constant(2), in: &p.timeline)      // 4 s of source → 2 s on the timeline
        #expect(p.timeline.clip(ids[0])!.duration == Time(2))
        try TimelineOps.trim(ids[0], edge: .head, to: Time(-0.5), in: &p)
        var c = p.timeline.clip(ids[0])!
        #expect(c.start == .zero && c.duration == Time(2.5) && c.sourceStart == Time(1))
        try TimelineOps.trim(ids[0], edge: .head, to: Time(-10), in: &p)    // at most sourceStart / rate = 0.5 s more
        c = p.timeline.clip(ids[0])!
        #expect(c.start == .zero && c.duration == Time(3) && c.sourceStart == .zero)
    }

    @Test func reversedFirstClipHeadStopsAtTheMediaEnd() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 4)               // media is 10 s
        p.timeline[clip: ids[0]]!.sourceStart = 2                          // plays source 6 → 2
        p.timeline[clip: ids[0]]!.reversed = true
        try TimelineOps.trim(ids[0], edge: .head, to: Time(-100), in: &p)
        let c = p.timeline.clip(ids[0])!
        #expect(c.start == .zero && c.duration == Time(8) && c.sourceStart == Time(2))
        #expect(c.sourceStart + c.sourceDuration == Time(10))
    }

    @Test func freeTrackClipCannotGrowBeforeZero() throws {
        var (p, _) = Fx.project(mainClips: 1, seconds: 4)
        let a = Fx.video("o"); p.media.append(a)
        var atZero = TimelineOps.makeClip(for: a, at: .zero); atZero.duration = 2; atZero.sourceStart = 2
        var later = TimelineOps.makeClip(for: a, at: .zero); later.start = 3; later.duration = 2; later.sourceStart = 2
        var overlay = Track(kind: .video)
        overlay.clips = [atZero, later]
        p.timeline.tracks.append(overlay)
        // at 0 there is no room on a free track: nothing changes
        try TimelineOps.trim(atZero.id, edge: .head, to: Time(-1), in: &p)
        #expect(p.timeline.clip(atZero.id)!.start == .zero && p.timeline.clip(atZero.id)!.sourceStart == Time(2))
        // a later clip grows left until 0 (sourceStart 2 → 1 s restored down to start 2, then clamped by the neighbour)
        try TimelineOps.trim(later.id, edge: .head, to: Time(2), in: &p)
        #expect(p.timeline.clip(later.id)!.start == Time(2) && p.timeline.clip(later.id)!.sourceStart == Time(1))
        #expect(throws: EditError.invalidTime) { try TimelineOps.trim(later.id, edge: .head, to: Time(1), in: &p) }
    }
}
