import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-COMPOUND-PREVIEW: a compound clip's timeline filmstrip / waveform are its rendered result (every layer through
/// the compositor, the mixed audio), keyed on the nested content.
@Suite(.serialized) struct CompoundPreviewTests {
    static func compound(_ p: TestProject, _ id: ClipID) -> CompoundClip {
        guard case .compound(let cid) = p[id].content else { fatalError("not a compound") }
        return p.project.compound(cid)!
    }

    @Test func filmstripFrameIsTheCompositeOfEveryLayer() async throws {
        var p = TestProject(background: .black)
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let o = try await p.addVideo(.solid(.green), seconds: 2, target: .newTrack)
        p[o].transform.scale = Vec2(0.5, 0.5); p[o].transform.position = Vec2(0.25, 0)
        let cid = try TimelineOps.createCompound([a, o], name: "C", in: &p.project)
        let comp = Self.compound(p, cid)
        let cache = CompoundPreviewCache()
        let key = CompoundPreviewCache.key(of: comp, in: p.project)
        let img = try #require(await cache.thumbnail(p.project.nested(comp), key: key, at: 0.5, height: 90))
        #expect(img.height == 90 && img.width == 160)
        let bm = Bitmap(img)
        // base layer (red) on the left, the half-size green overlay on the right: not one nested clip's frame
        #expect(bm[0.15, 0.5].isClose(to: .red, tolerance: 0.12))
        #expect(bm[0.75, 0.5].isClose(to: .green, tolerance: 0.12))
        #expect(cache.cachedThumbnail(key: key, at: 0.6, height: 90) != nil)   // same 0.25 s quantum
        #expect(cache.cachedThumbnail(key: key, at: 1.0, height: 90) == nil)
    }

    @Test func keyFollowsNestedContentNotPlacement() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let cid = try TimelineOps.createCompound([a], name: "C", in: &p.project)
        let comp = Self.compound(p, cid)
        let k0 = CompoundPreviewCache.key(of: comp, in: p.project)
        #expect(CompoundPreviewCache.key(of: comp, in: p.project) == k0)
        p[cid].opacity = 0.3   // the compound clip's own look / placement: same nested content
        #expect(CompoundPreviewCache.key(of: Self.compound(p, cid), in: p.project) == k0)
        var edited = comp
        edited.timeline.tracks[edited.timeline.mainTrackIndex!].clips[0].opacity = 0.5
        p.project.compounds = [edited]
        let k1 = CompoundPreviewCache.key(of: edited, in: p.project)
        #expect(k1 != k0)

        // stale fallback: while the new content renders, the previous frames of the same compound show
        let cache = CompoundPreviewCache()
        let nested0 = p.project.nested(comp)
        _ = try #require(await cache.thumbnail(nested0, key: k0, at: 0, height: 40))
        cache.noteKey(k0, for: comp.id)
        cache.noteKey(k1, for: comp.id)
        #expect(cache.cachedThumbnail(key: k1, at: 0, height: 40) == nil)
        #expect(cache.cachedThumbnail(key: k1, compound: comp.id, at: 0, height: 40) != nil)
        #expect(!cache.hasThumbnail(key: k1, at: 0, height: 40))
    }

    @Test func waveformIsTheMixOfEveryNestedAudio() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.red), seconds: 2, audioHz: 440)
        let b = try await p.addVideo(.solid(.blue), seconds: 1, audioHz: 660, at: 1, target: .newTrack)
        let cid = try TimelineOps.createCompound([a, b], name: "C", in: &p.project)
        let comp = Self.compound(p, cid)
        let cache = CompoundPreviewCache()
        let mixed = try #require(await cache.waveform(p.project.nested(comp), key: "mix"))
        #expect(abs(mixed.peaks.count - 200) <= 2)

        // the same compound with its second layer's track muted = the first clip's audio alone
        var solo = comp
        let bi = try #require(solo.timeline.tracks.firstIndex { !$0.isMain && !$0.clips.isEmpty })
        solo.timeline.tracks[bi].isMuted = true
        let single = try #require(await cache.waveform(p.project.nested(solo), key: "single"))
        let both = mixed.peak(from: 1.2, to: 1.8), one = single.peak(from: 1.2, to: 1.8)
        #expect(one > 0.05)
        #expect(both > one + 0.05, "mix \(both) vs single \(one)")
        // before the second clip starts both mixes are the first clip alone
        #expect(abs(mixed.peak(from: 0.2, to: 0.8) - single.peak(from: 0.2, to: 0.8)) < 0.03)
        #expect(cache.cachedWaveform(key: "mix") != nil)
    }
}
