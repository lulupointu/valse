import Testing
import Foundation
@testable import MontageCore

/// Finisher rows: TL-037 timecode, AU-029 solo, TL-023 multi-timeline, TL-043 / SE-010 settings fields.
@Suite struct TimecodeEntryTests {
    @Test func formatsStylesAndDropFrame() {
        let r = FrameRate.fps30
        #expect(Timecode.string(Time(65.5), rate: r, style: .frames, dropFrame: false) == "00:01:05:15")
        #expect(Timecode.string(Time(65.25), rate: r, style: .seconds, dropFrame: false) == "00:01:05.250")
        // drop-frame only applies to NTSC rates
        #expect(Timecode.string(Time(60), rate: r, style: .frames, dropFrame: true) == "00:01:00:00")
        let ntsc = FrameRate.fps29_97
        // frame 1800 at 29.97 DF is 00:01:00;02 (frames ;00 and ;01 of minute 1 are skipped)
        #expect(Timecode.string(ntsc.time(ofFrame: 1800), rate: ntsc, style: .frames, dropFrame: true) == "00:01:00;02")
        #expect(Timecode.string(ntsc.time(ofFrame: 1799), rate: ntsc, style: .frames, dropFrame: true) == "00:00:59;29")
        // every 10th minute keeps its frames: 17982 frames = 00:10:00;00
        #expect(Timecode.string(ntsc.time(ofFrame: 17982), rate: ntsc, style: .frames, dropFrame: true) == "00:10:00;00")
        // one hour of 29.97 DF is 107892 frames
        #expect(Timecode.string(ntsc.time(ofFrame: 107_892), rate: ntsc, style: .frames, dropFrame: true) == "01:00:00;00")
        #expect(Timecode.string(Time(-1), rate: r) == "-00:00:01:00")
    }

    @Test func parsesTypedTimecodes() {
        let r = FrameRate.fps30
        #expect(Timecode.parse("00:01:05:15", rate: r) == Time(65.5))
        #expect(Timecode.parse("1:05:15", rate: r) == Time(65.5))
        #expect(Timecode.parse("1005", rate: r) == r.time(ofFrame: 305))        // 00:00:10:05
        #expect(Timecode.parse("30000", rate: r) == Time(180))                  // 00:03:00:00
        #expect(Timecode.parse("+10", rate: r, relativeTo: Time(1)) == r.time(ofFrame: 40))
        #expect(Timecode.parse("-1:00", rate: r, relativeTo: Time(5)) == Time(4))
        #expect(Timecode.parse("12.5", rate: r, style: .seconds) == Time(12.5))
        #expect(Timecode.parse("01:00.25", rate: r, style: .seconds) == Time(60.25))
        #expect(Timecode.parse("abc", rate: r) == nil)
        #expect(Timecode.parse("", rate: r) == nil)
        #expect(Timecode.parse("123456789", rate: r) == nil)
        // drop-frame round trip
        let ntsc = FrameRate.fps29_97
        for f: Int64 in [0, 1799, 1800, 17_982, 17_983, 54_000, 107_892] {
            let label = Timecode.string(ntsc.time(ofFrame: f), rate: ntsc, style: .frames, dropFrame: true)
            #expect(Timecode.parse(label, rate: ntsc, dropFrame: true) == ntsc.time(ofFrame: f), "\(label)")
        }
    }

    @Test func settingsCarryDisplay() throws {
        var s = AppSettings()
        s.timecodeStyle = "seconds"; s.dropFrame = true
        let back = AppSettings.decode(try JSONEncoder().encode(s))
        #expect(back.timecodeDisplay == TimecodeDisplay(style: .seconds, dropFrame: true))
        #expect(AppSettings().timecodeDisplay == TimecodeDisplay())
    }
}

@Suite struct TrackSoloTests {
    @Test func soloSilencesOtherTracks() {
        var tl = Timeline()
        tl.tracks.append(Track(kind: .audio))
        tl.tracks.append(Track(kind: .audio))
        #expect(!tl.hasSolo && tl.tracks.allSatisfy { tl.isAudible($0) })
        tl.tracks[1].isSolo = true
        #expect(tl.isAudible(tl.tracks[1]) && !tl.isAudible(tl.tracks[0]) && !tl.isAudible(tl.tracks[2]))
        tl.tracks[2].isSolo = true
        #expect(tl.isAudible(tl.tracks[2]))
        tl.tracks[2].isMuted = true   // mute wins over solo
        #expect(!tl.isAudible(tl.tracks[2]))
        var p = Project()
        p.timeline = tl
        let decoded = CompoundFlattening.decodeTracks(p)
        #expect(decoded.map(\.isMuted) == [true, false, true])
    }

    @Test func soloRoundTrips() throws {
        var t = Track(kind: .audio)
        t.isSolo = true
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        #expect(back.isSolo == true)
        // old files without the key decode as not soloed
        let old = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(Track(kind: .audio)))
        #expect(old.isSolo == nil)
    }
}

@Suite struct MultiTimelineTests {
    func project() -> Project {
        var p = Project()
        p.timeline.tracks[0].clips = [Clip(content: .solid(.white), start: 0, duration: 2),
                                      Clip(content: .solid(.black), start: 2, duration: 3)]
        return p
    }

    @Test func newSwitchKeepsEachTimeline() throws {
        var p = project()
        let first = p.timeline
        let id2 = try MultiTimelineOps.newTimeline(&p, name: "Timeline 2", firstName: "Timeline 1")
        #expect(p.timelines?.map(\.name) == ["Timeline 1", "Timeline 2"])
        #expect(p.activeTimelineID == id2 && p.timeline.allClips.isEmpty)
        p.timeline.tracks[0].clips = [Clip(content: .solid(.white), start: 0, duration: 7)]
        p.settings.frameRate = .fps25      // per-timeline settings (TL-043)
        let id1 = p.timelines![0].id
        try MultiTimelineOps.switchTo(&p, id1)
        #expect(p.timeline == first && p.settings.frameRate == .fps30)
        try MultiTimelineOps.switchTo(&p, id2)
        #expect(p.timeline.duration == Time(7) && p.settings.frameRate == .fps25)
        #expect(throws: EditError.self) { try MultiTimelineOps.switchTo(&p, id2) }
    }

    @Test func newWithSelectionCopiesClips() throws {
        var p = project()
        let second = p.timeline.tracks[0].clips[1].id
        try MultiTimelineOps.newTimeline(&p, name: "B", firstName: "A", clips: [second])
        #expect(p.timeline.tracks[0].clips.count == 1)
        #expect(p.timeline.tracks[0].clips[0].start == .zero && p.timeline.tracks[0].clips[0].duration == Time(3))
        #expect(p.timeline.tracks[0].clips[0].id != second)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func duplicateRenameDeleteMove() throws {
        var p = project()
        try MultiTimelineOps.newTimeline(&p, name: "B", firstName: "A")
        let a = p.timelines![0].id
        try MultiTimelineOps.switchTo(&p, a)
        let c = try MultiTimelineOps.duplicate(&p, a, name: "A copy")
        #expect(p.timelines!.map(\.name) == ["A", "A copy", "B"])
        #expect(p.activeTimelineID == c && p.timeline.allClips.count == 2)
        #expect(Set(p.timeline.allClips.map(\.id)).isDisjoint(with: p.timelines![0].timeline.allClips.map(\.id)))
        try MultiTimelineOps.rename(&p, c, to: "  Edit  ")
        #expect(p.timelines![1].name == "Edit")
        #expect(throws: EditError.self) { try MultiTimelineOps.rename(&p, c, to: " ") }
        try MultiTimelineOps.move(&p, c, to: 0)
        #expect(p.timelines!.map(\.name) == ["Edit", "A", "B"])
        try MultiTimelineOps.delete(&p, c)              // active → neighbour becomes active
        #expect(p.timelines!.map(\.name) == ["A", "B"] && p.activeTimelineID == a)
        try MultiTimelineOps.delete(&p, p.timelines![1].id)
        #expect(p.timelines == nil && p.activeTimelineID == nil && p.timeline.allClips.count == 2)
    }

    @Test func savesWithoutDuplicatingActiveTimeline() throws {
        var p = project()
        try MultiTimelineOps.newTimeline(&p, name: "B", firstName: "A")
        p.timeline.tracks[0].clips = [Clip(content: .solid(.white), start: 0, duration: 4)]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString).montage")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectPackage.save(p, to: dir)
        let back = try ProjectPackage.load(from: dir)
        #expect(back.timeline.duration == Time(4) && back.timelines?.count == 2)
        #expect(back.timelines![1].timeline.allClips.isEmpty)            // active slot stored empty
        #expect(back.timelines![0].timeline.duration == Time(5))         // inactive slot kept
        var q = back
        try MultiTimelineOps.switchTo(&q, q.timelines![0].id)
        try MultiTimelineOps.switchTo(&q, q.timelines![1].id)
        #expect(q.timeline.duration == Time(4))
    }

    @Test func projectSettingsImportModeRoundTrips() throws {
        var s = ProjectSettings()
        #expect(s.copyMediaOnImport == nil)
        s.copyMediaOnImport = true
        let back = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s))
        #expect(back.copyMediaOnImport == true)
    }
}

@Suite struct MatchCutTests {
    @Test func splitsOnBeatsInsideTheClip() throws {
        var tl = Timeline()
        let v = Clip(content: .solid(.white), start: 0, duration: 6)
        tl.tracks[0].clips = [v]
        var music = Track(kind: .audio)
        var m = Clip(content: .solid(.black), start: 1, duration: 10)
        m.beats = [Time(0.5), Time(1.5), Time(3), Time(4.99)]   // absolute 1.5, 2.5, 4, 5.99 (too close to the end)
        music.clips = [m]
        tl.tracks.append(music)
        let n = try TimelineOps.matchCut([v.id], in: &tl)
        #expect(n == 3)
        #expect(tl.tracks[0].clips.map(\.start) == [Time(0), Time(1.5), Time(2.5), Time(4)])
        #expect(TimelineOps.validate(tl).isEmpty)
        var empty = Timeline()
        empty.tracks[0].clips = [v]
        #expect(throws: EditError.self) { try TimelineOps.matchCut([v.id], in: &empty) }
    }

    @Test func splitAudioTrackMakesLeftAndRightClips() throws {
        var tl = Timeline()
        var a = Track(kind: .audio)
        let c = Clip(content: .media(MediaID()), start: 1, duration: 4)
        a.clips = [c]
        tl.tracks.append(a)
        let r = try TimelineOps.splitAudioChannels(c.id, in: &tl)
        let left = try #require(tl.clip(c.id)), right = try #require(tl.clip(r))
        #expect(left.audio.channels == .leftToBoth && right.audio.channels == .rightToBoth)
        #expect(left.groupID != nil && left.groupID == right.groupID && right.range == left.range)
        #expect(tl.tracks.filter { $0.kind == .audio }.count == 2)
        #expect(TimelineOps.validate(tl).isEmpty)
        #expect(throws: EditError.self) { try TimelineOps.splitAudioChannels(c.id, in: &tl) }   // already split
    }
}

/// TL-018 track volume, TL-025 clip markers, TL-013 freeze link.
@Suite struct FinisherTrackTests {
    @Test func trackVolumeIsBakedIntoDecodedClips() throws {
        var p = Project()
        var a = Track(kind: .audio)
        var c = Clip(content: .media(MediaID()), start: 0, duration: 4)
        c.audio.volume = 0.8
        c.keyframes[ParamKey.volume.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(1)), Keyframe(time: 2, value: .scalar(0.5))])
        a.clips = [c]
        a.volume = 0.5
        p.timeline.tracks.append(a)
        let d = try #require(CompoundFlattening.decodeTracks(p).first { $0.id == a.id })
        #expect(abs(d.clips[0].audio.volume - 0.4) < 1e-9)
        #expect(d.clips[0].keyframes[ParamKey.volume.raw]!.keyframes.compactMap(\.value.scalar) == [0.5, 0.25])
        #expect(d.volume == nil)
        // the model itself is untouched; nil volume = unity
        #expect(p.timeline.tracks.last!.clips[0].audio.volume == 0.8)
        #expect(Track(kind: .audio).gain == 1)
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(a))
        #expect(back.volume == 0.5)
    }

    @Test func clipMarkersFollowSplitTrimAndSpeed() throws {
        var tl = Timeline()
        let v = Clip(content: .solid(.white), start: 2, duration: 6)
        tl.tracks[0].clips = [v]
        try TimelineOps.addClipMarker(v.id, at: 3, in: &tl)
        try TimelineOps.addClipMarker(v.id, at: 6, in: &tl)
        #expect(throws: EditError.self) { try TimelineOps.addClipMarker(v.id, at: 6, in: &tl) }   // duplicate
        #expect(throws: EditError.self) { try TimelineOps.addClipMarker(v.id, at: 9, in: &tl) }   // outside
        #expect(tl.clip(v.id)!.markers!.map(\.time) == [Time(1), Time(4)])
        let r = try TimelineOps.split(v.id, at: 5, in: &tl)
        #expect(tl.clip(v.id)!.markers!.map(\.time) == [Time(1)])
        #expect(tl.clip(r)!.markers!.map(\.time) == [Time(1)])
        #expect(TimelineOps.allMarkerTimes(tl) == [Time(3), Time(6)])
        try TimelineOps.setSpeed(r, .constant(2), in: &tl)   // 3 s → 1.5 s: marker at 0.5
        #expect(tl.clip(r)!.markers!.map(\.time) == [Time(0.5)])
        try TimelineOps.removeClipMarkers([v.id, r], in: &tl)
        #expect(tl.clip(v.id)!.markers == nil && TimelineOps.allMarkerTimes(tl).isEmpty)
    }

    @Test func linkedFreezeFollowsTheOriginalsLook() throws {
        var (p, ids0) = Fx.project(mainClips: 2)
        let ids = ids0
        let f = try TimelineOps.freezeFrame(ids[0], at: 1, in: &p)
        var s = EditSession(project: p)
        #expect(s.project.timeline.clip(f)?.freezeSource == ids[0])
        try s.perform(Edit("x") { p in p.timeline[clip: ids[0]]?.opacity = 0.4; p.timeline[clip: ids[0]]?.transform.scale = Vec2(2, 2) })
        #expect(s.project.timeline.clip(f)?.opacity == 0.4 && s.project.timeline.clip(f)?.transform.scale == Vec2(2, 2))
        // gestures too
        s.beginGesture("g")
        s.updateGesture { p in p.timeline[clip: ids[0]]?.opacity = 0.7 }
        #expect(s.project.timeline.clip(f)?.opacity == 0.7)
        s.endGesture()
        // original deleted → link dropped, look kept
        try s.perform(Edit("d") { p in p.timeline[clip: ids[0]] = nil })
        #expect(s.project.timeline.clip(f)?.freezeSource == nil && s.project.timeline.clip(f)?.opacity == 0.7)
        // unlinked freeze frames when the setting is off
        p = s.project
        var d = EditDefaults.current; let saved = d; d.linkFreeze = false; EditDefaults.current = d
        defer { EditDefaults.current = saved }
        let g = try TimelineOps.freezeFrame(ids[1], at: p.timeline.clip(ids[1])!.start + 1, in: &p)
        #expect(p.timeline.clip(g)?.freezeSource == nil)
    }
}

/// TL-021 edit inside a compound clip.
@Suite struct FinisherCompoundEditTests {
    @Test func enterEditExitWritesTheNestedTimelineBack() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        let cid = try TimelineOps.createCompound([ids[0], ids[1]], name: "C", in: &p)
        let parentDuration = p.timeline.clip(cid)!.duration
        try CompoundEditing.enter(cid, in: &p)
        #expect(p.isInsideCompound && CompoundEditing.path(p) == ["C"])
        #expect(p.timeline.allClips.count == 2)
        // the compound is still "used" (its clip lives in the parent on the stack)
        #expect(MultiTimelineOps.allTimelines(p).count == 2)
        // edit inside: trim the last nested clip by 1 s
        let inner = p.timeline.mainTrack!.clips.last!
        try TimelineOps.trim(inner.id, edge: .tail, to: inner.end - Time(1), in: &p)
        let nestedDuration = p.timeline.duration
        try CompoundEditing.exit(&p)
        #expect(!p.isInsideCompound && p.compoundEdit == nil)
        let comp = try #require(p.compound({ if case .compound(let c) = p.timeline.clip(cid)!.content { return c }; return CompoundID() }()))
        #expect(comp.timeline.duration == nestedDuration)
        // the compound clip got shorter with its content
        #expect(p.timeline.clip(cid)!.duration == min(parentDuration, nestedDuration))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        #expect(throws: EditError.self) { try CompoundEditing.exit(&p) }
        #expect(throws: EditError.self) { try CompoundEditing.enter(ids[2], in: &p) }   // not a compound
        try CompoundEditing.enter(cid, in: &p)
        CompoundEditing.exitAll(&p)
        #expect(!p.isInsideCompound && p.timeline.clip(cid) != nil)
    }
}

/// MI-009 playback-lag heuristics.
@Suite struct FinisherLagTests {
    @Test func flagsHeavyVideosOnly() {
        var a = Fx.video("v", seconds: 10)
        a.pixelSize = Size2(1920, 1080); a.frameRate = .fps30
        a.techInfo = MediaTechInfo(); a.techInfo?.bitrate = 12_000_000
        #expect(PlaybackLagAdvisor.reasons(a).isEmpty)
        a.techInfo?.bitrate = 120_000_000
        #expect(PlaybackLagAdvisor.reasons(a) == [.highBitrate])
        a.techInfo?.bitrate = 12_000_000; a.techInfo?.isVariableFrameRate = true
        #expect(PlaybackLagAdvisor.reasons(a) == [.variableFrameRate])
        a.techInfo?.isVariableFrameRate = nil
        a.pixelSize = Size2(3840, 2160); a.frameRate = .fps60
        #expect(PlaybackLagAdvisor.reasons(a) == [.highFrameRate])
        a.frameRate = .fps30; a.bitDepth = 10
        #expect(PlaybackLagAdvisor.reasons(a) == [.hdr4K])
        #expect(PlaybackLagAdvisor.reasons(Fx.audio("a", seconds: 3)).isEmpty)
    }
}
