import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Compound clips / nested timelines (TL-021 render side).
@Suite(.serialized) struct CompoundTests {
    static func level(_ img: Bitmap) -> Double { img.average(x: 0.3, y: 0.3, w: 0.4, h: 0.4).r * 255 }

    @Test func compoundRendersLikeItsContentAndTakesItsOwnLook() async throws {
        var p = TestProject(background: .black)
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let o = try await p.addVideo(.solid(.green), seconds: 2, target: .newTrack)
        p[o].transform.scale = Vec2(0.5, 0.5); p[o].transform.position = Vec2(0.25, 0)
        let before = try await p.render(at: 0.5)
        let cid = try TimelineOps.createCompound([a, o], name: "C", in: &p.project)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        #expect(p.project.timeline.tracks.flatMap(\.clips).count == 1)
        let after = try await p.render(at: 0.5)
        for (x, y) in [(0.25, 0.5), (0.75, 0.5)] { #expect(after[x, y].isClose(to: before[x, y]), "\(x)") }
        // the compound's own opacity / transform apply to the whole group
        p[cid].opacity = 0.5
        let half = try await p.render(at: 0.5)
        #expect(half[0.25, 0.5].isClose(to: RGBA(0.5, 0, 0)) && half[0.75, 0.5].isClose(to: RGBA(0, 0.5, 0)))
        p[cid].opacity = 1
        p[cid].transform.scale = Vec2(0.5, 0.5)
        let small = try await p.render(at: 0.5)
        #expect(small[0.05, 0.05].isClose(to: .black) && small[0.4, 0.5].isClose(to: .red))
    }

    @Test func compoundSpeedAndTrimRemapNestedFrames() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.frameIndex, seconds: 2)
        let cid = try TimelineOps.createCompound([a], name: "C", in: &p.project)
        try TimelineOps.setSpeed(cid, .constant(2), in: &p.project.timeline)
        #expect(p[cid].duration == Time(1))
        // parent 0.5 s → nested 1.0 s → frame 30
        #expect(abs(Self.level(try await p.render(at: 0.5)) - 120) < 2.5)
        try TimelineOps.trim(cid, edge: .head, to: 0.25, in: &p.project)    // nested in-point 0.5 s → frame 15
        #expect(abs(Self.level(try await p.render(at: 0)) - 60) < 2.5)
    }

    @Test func nestedAudioIsDecodedAndExplodeRestoresClips() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.blue), seconds: 2, audioHz: 440)
        let cid = try TimelineOps.createCompound([a], name: "C", in: &p.project)
        let tracks = CompoundFlattening.decodeTracks(p.project)
        #expect(tracks.count == 2 && tracks[1].clips.first?.id == nestedClipID(cid, a))
        let r = try await p.export(seconds: 1)
        #expect(r.probe.hasAudio)
        try TimelineOps.explodeCompound(cid, in: &p.project)
        #expect(p.project.timeline.mainTrack?.clips.count == 1)
        #expect(p.project.compounds?.isEmpty == true)
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: .blue))
    }

    @Test func persistenceRoundTripsCompounds() throws {
        var p = Project()
        var tl = Timeline(); tl.tracks[0].clips = [Clip(content: .solid(.red), start: 0, duration: 1)]
        let comp = CompoundClip(name: "N", timeline: tl)
        p.compounds = [comp]
        p.timeline.tracks[0].clips = [Clip(content: .compound(comp.id), start: 0, duration: 1)]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back == p)
    }
}
