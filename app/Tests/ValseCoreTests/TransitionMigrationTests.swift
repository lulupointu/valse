import Foundation
import Testing
@testable import ValseCore

/// TR-MODEL-CAPCUT: schema 1 projects (overlapping transitions) migrate to cut-centred transitions on butted clips
/// with the same timeline length, the same transition windows and the same source frame at every instant.
@Suite struct TransitionMigrationTests {
    /// What the schema-1 renderer showed on `track` at `t`: (clip, source time) per side, and the progress.
    struct Sample: Equatable, CustomStringConvertible {
        var sides: [(ClipID, Time)]
        var progress: Double?
        static func == (a: Sample, b: Sample) -> Bool {
            guard a.sides.count == b.sides.count else { return false }
            if let p = a.progress, let q = b.progress { if abs(p - q) > 1e-6 { return false } } else if (a.progress == nil) != (b.progress == nil) { return false }
            return zip(a.sides, b.sides).allSatisfy { $0.0 == $1.0 && abs(($0.1 - $1.1).ticks) <= 2 }
        }
        var description: String { "\(sides.map { "\($0.0.short)@\($0.1.seconds)" }) p=\(progress.map { String($0) } ?? "-")" }
    }

    /// The old (schema 1) model: neighbours overlap by d; the overlap [b.start, a.end) is the transition.
    static func oldSample(_ track: Track, at t: Time) -> Sample? {
        let active = track.clips.filter { $0.range.contains(t) }
        if active.count >= 2, let tr = active[0].transitionOut {
            let p = Double((t - active[1].start).ticks) / Double(tr.duration.ticks)
            return Sample(sides: [(active[0].id, active[0].sourceTime(at: t)), (active[1].id, active[1].sourceTime(at: t))], progress: p)
        }
        return active.first.map { Sample(sides: [($0.id, $0.sourceTime(at: t))], progress: nil) }
    }

    static func newSample(_ p: Project, track: TrackID, at t: Time) -> Sample? {
        func src(_ l: LayerDescription) -> Time { if case .media(_, let s) = l.source { return s }; return .zero }
        for item in FrameEvaluator.evaluate(p, at: t).items {
            switch item {
            case .transition(let a, let b, _, let pr, _) where a.trackID == track:
                return Sample(sides: [(a.clipID, src(a)), (b.clipID, src(b))], progress: pr)
            case .layer(let l) where l.trackID == track && !l.isCanvasBackground:
                return Sample(sides: [(l.clipID, src(l))], progress: nil)
            default: continue
            }
        }
        return nil
    }

    static func clip(_ m: MediaAsset, start: Double, duration: Double, source: Double, speed: Double = 1, reversed: Bool = false,
                     transition: Double? = nil) -> Clip {
        var c = TimelineOps.makeClip(for: m, at: Time(start))
        c.duration = Time(duration); c.sourceStart = Time(source); c.reversed = reversed
        if speed != 1 { c.speed = .constant(speed) }
        if let transition { c.transitionOut = TransitionInstance(typeID: "valse.transition.dissolve", duration: Time(transition)) }
        return c
    }

    /// A schema-1 project: main track 4 clips with three transitions in a row (one reversed, one 2× clip), an overlay
    /// video track with two transitions in a row and a gap.
    static func oldProject() -> Project {
        var p = Project(name: "Old")
        let m = MediaAsset(name: "m", kind: .video, url: URL(fileURLWithPath: "/tmp/m.mp4"), duration: Time(60), pixelSize: .hd1080,
                           frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "m")
        p.media = [m]
        var main = Track(kind: .video, isMain: true)
        // durations 4, 4, 3, 5; overlaps 1, 0.5, 2 → starts 0, 3, 6.5, 7.5
        main.clips = [clip(m, start: 0, duration: 4, source: 5, transition: 1),
                      clip(m, start: 3, duration: 4, source: 20, reversed: true, transition: 0.5),
                      clip(m, start: 6.5, duration: 3, source: 30, speed: 2, transition: 2),
                      clip(m, start: 7.5, duration: 5, source: 40)]
        var overlay = Track(kind: .video)
        overlay.clips = [clip(m, start: 1, duration: 3, source: 10, transition: 1),
                         clip(m, start: 3, duration: 3, source: 15, transition: 0.6),
                         clip(m, start: 5.4, duration: 2, source: 25),
                         clip(m, start: 9, duration: 2, source: 50)]
        p.timeline.tracks = [main, overlay]
        return p
    }

    static func migratedThroughJSON(_ old: Project) throws -> Project {
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectPackage.encoder().encode(old)) as? [String: Any])
        obj["schemaVersion"] = 1
        let migrated = try ProjectMigrator.migrate(JSONSerialization.data(withJSONObject: obj))
        return try ProjectPackage.decoder().decode(Project.self, from: migrated)
    }

    @Test func migrationKeepsEveryFrameLengthAndWindow() throws {
        let old = Self.oldProject()
        let new = try Self.migratedThroughJSON(old)
        #expect(new.schemaVersion == Project.currentSchemaVersion)
        #expect(new.duration == old.duration)
        #expect(TimelineOps.validate(new.timeline).isEmpty)
        for (ot, nt) in zip(old.timeline.tracks, new.timeline.tracks) {
            // butted clips, transitions = the old overlaps, windows = the old overlap ranges
            for i in ot.clips.indices.dropLast() {
                guard let tr = ot.clips[i].transitionOut, ot.clips[i].end > ot.clips[i + 1].start else { continue }
                #expect(nt.clips[i].end == nt.clips[i + 1].start)
                #expect(nt.clips[i].transitionOut?.duration == tr.duration)
                #expect(nt.transitionWindow(after: i) == TimeRange(start: ot.clips[i + 1].start, end: ot.clips[i].end))
            }
            var t = Time.zero
            while t < old.duration {
                let a = Self.oldSample(ot, at: t), b = Self.newSample(new, track: nt.id, at: t)
                #expect(a == b, "track \(nt.isMain ? "main" : "overlay") at \(t.seconds): old \(a.map(\.description) ?? "-") new \(b.map(\.description) ?? "-")")
                t += Time(0.05)
            }
        }
    }

    @Test func migrationMovesTheCutToTheOverlapCentre() throws {
        let new = try Self.migratedThroughJSON(Self.oldProject())
        let main = new.timeline.mainTrack!.clips
        #expect(main.map(\.start) == [Time(0), Time(3.5), Time(6.75), Time(8.5)])
        // A keeps its start and in point; B's in point moves by d/2 (forward clip), the reversed clip keeps its in point
        #expect(main[0].sourceStart == Time(5))
        #expect(main[0].duration == Time(3.5))
        #expect(main[3].sourceStart == Time(41))
        #expect(main[3].duration == Time(4))
        // the 2× clip loses 0.25 s at its head (0.5 s of source) and 1 s at its tail
        #expect(main[2].sourceStart == Time(30.5))
        #expect(main[2].duration == Time(1.75))
    }

    @Test func compoundAndTabTimelinesMigrateToo() throws {
        var old = Self.oldProject()
        old.compounds = [CompoundClip(name: "c", timeline: old.timeline)]
        old.timelines = [TimelineSlot(name: "t", timeline: old.timeline, settings: old.settings)]
        let new = try Self.migratedThroughJSON(old)
        #expect(new.compounds?.first?.timeline == new.timeline)
        #expect(new.timelines?.first?.timeline == new.timeline)
    }

    @Test func currentFilesAreLeftAlone() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        let data = try ProjectPackage.encoder().encode(p)
        let back = try ProjectPackage.decoder().decode(Project.self, from: ProjectMigrator.migrate(data))
        #expect(back.timeline == p.timeline)
    }
}
