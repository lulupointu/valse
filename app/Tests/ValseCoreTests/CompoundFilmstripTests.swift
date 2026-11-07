import Testing
import Foundation
@testable import ValseCore

/// BUG-COMPOUND-FILMSTRIP: what a compound clip shows at a parent time (timeline filmstrip / waveform source).
@Suite struct CompoundFilmstripTests {
    let mA = MediaID(), mB = MediaID(), mC = MediaID()

    /// Nested: main A [0,4) src 10 · overlay video B [2,3) src 0 · audio C [0,4).
    func project(hideOverlay: Bool = false) -> (Project, Clip, Track) {
        var nested = Timeline()
        let mi = nested.mainTrackIndex!
        var a = Clip(content: .media(mA), start: 0, duration: 4); a.sourceStart = 10
        nested.tracks[mi].clips = [a]
        var ov = Track(kind: .video); ov.isHidden = hideOverlay
        ov.clips = [Clip(content: .media(mB), start: 2, duration: 1)]
        nested.tracks.append(ov)
        var au = Track(kind: .audio)
        au.clips = [Clip(content: .media(mC), start: 0, duration: 4)]
        nested.tracks.append(au)
        let comp = CompoundClip(name: "C", timeline: nested)
        var p = Project()
        p.compounds = [comp]
        // trimmed (in-point 1 s) and 1.5× : shows nested [1, 4) over parent [5, 7)
        var cc = Clip(content: .compound(comp.id), start: 5, duration: 2)
        cc.sourceStart = 1
        cc.speed = .constant(1.5)
        return (p, cc, au)
    }

    func close(_ a: Time, _ b: Double) -> Bool { abs(a.seconds - b) < 1e-4 }

    @Test func topmostVisualClipAndSourceTime() throws {
        let (p, cc, _) = project()
        let tracks = CompoundFlattening.nestedTracks(of: cc, in: p)
        #expect(tracks.count == 3)
        // t = 5.2 → nested 1.3 → A at 11.3
        let x1 = try #require(CompoundFlattening.visualClip(at: Time(5.2), in: tracks))
        #expect(x1.mediaID == mA && close(x1.sourceTime(at: Time(5.2)), 11.3))
        // t = 6 → nested 2.5 → overlay B (topmost) at 0.5
        let x2 = try #require(CompoundFlattening.visualClip(at: Time(6), in: tracks))
        #expect(x2.mediaID == mB && close(x2.sourceTime(at: Time(6)), 0.5))
        // the audio clip never wins the filmstrip; it is re-timed to the parent window
        let au = try #require(tracks.first { $0.kind == .audio }?.clips.first)
        #expect(au.mediaID == mC && close(au.start, 5) && close(au.duration, 2))
        // outside the compound: nothing
        #expect(CompoundFlattening.visualClip(at: Time(8), in: tracks) == nil)
    }

    @Test func hiddenNestedTrackIsSkipped() throws {
        let (p, cc, _) = project(hideOverlay: true)
        let x = try #require(CompoundFlattening.visualClip(at: Time(6), in: CompoundFlattening.nestedTracks(of: cc, in: p)))
        #expect(x.mediaID == mA && close(x.sourceTime(at: Time(6)), 12.5))
    }

    @Test func muteFlagsFollowCompoundAndNestedTrack() {
        var (p, cc, _) = project()
        #expect(CompoundFlattening.nestedTracks(of: cc, in: p).allSatisfy { !$0.isMuted })
        cc.audio.isMuted = true
        #expect(CompoundFlattening.nestedTracks(of: cc, in: p).allSatisfy { $0.isMuted })
        cc.audio.isMuted = false
        p.compounds![0].timeline.tracks[2].isMuted = true
        let t = CompoundFlattening.nestedTracks(of: cc, in: p)
        #expect(t.first { $0.kind == .audio }?.isMuted == true)
        #expect(CompoundFlattening.nestedTracks(of: Clip(content: .media(mA), start: 0, duration: 1), in: p).isEmpty)
    }

    @Test func nestedCompoundIsExpandedRecursively() throws {
        let mE = MediaID()
        var innerTL = Timeline()
        innerTL.tracks[innerTL.mainTrackIndex!].clips = [Clip(content: .media(mE), start: 0, duration: 10)]
        let inner = CompoundClip(name: "inner", timeline: innerTL)
        var outerTL = Timeline()
        var ic = Clip(content: .compound(inner.id), start: 0, duration: 4); ic.sourceStart = 2
        outerTL.tracks[outerTL.mainTrackIndex!].clips = [ic]
        let outer = CompoundClip(name: "outer", timeline: outerTL)
        var p = Project()
        p.compounds = [inner, outer]
        var cc = Clip(content: .compound(outer.id), start: 3, duration: 2); cc.sourceStart = 1
        let x = try #require(CompoundFlattening.visualClip(at: Time(4), in: CompoundFlattening.nestedTracks(of: cc, in: p)))
        // parent 4 → outer 2 → inner 4
        #expect(x.mediaID == mE && close(x.sourceTime(at: Time(4)), 4))
    }
}
