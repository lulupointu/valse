import Testing
import Foundation
@testable import ValseCore

@Suite struct MediaBinTests {
    @Test func createRenameMoveDelete() throws {
        var (p, _) = Fx.project(mainClips: 2)
        let a = try BinOps.createFolder("Footage", parent: nil, in: &p)
        let b = try BinOps.createFolder("Day 1", parent: a, in: &p)
        let dup = try BinOps.createFolder("Footage", parent: nil, in: &p)
        #expect(p.folders.first { $0.id == dup }?.name == "Footage 2")
        try BinOps.rename(b, to: "Jour 1", in: &p)
        #expect(BinOps.path(to: b, in: p).map(\.name) == ["Footage", "Jour 1"])
        try BinOps.moveMedia([p.media[0].id], to: b, in: &p)
        #expect(BinOps.media(in: b, of: p).count == 1)
        #expect(throws: BinOps.BinError.cycle) { try BinOps.moveFolder(a, to: b, in: &p) }
        try BinOps.moveFolder(b, to: dup, in: &p)
        #expect(BinOps.children(of: dup, in: p).map(\.id) == [b])
        // delete parent: sub-folder removed too, media moves up to the deleted folder's parent (root)
        try BinOps.deleteFolder(dup, in: &p)
        #expect(!p.folders.contains { $0.id == b || $0.id == dup })
        #expect(p.media[0].folderID == nil)
        #expect(BinOps.validate(p).isEmpty)
        #expect(throws: BinOps.BinError.emptyName) { try BinOps.createFolder("  ", parent: nil, in: &p) }
    }

    @Test func depthIsLimitedToTen() throws {
        var p = Project()
        var parent: MediaFolderID? = nil
        for i in 0..<10 { parent = try BinOps.createFolder("L\(i)", parent: parent, in: &p) }
        #expect(BinOps.depth(of: parent, in: p) == 10)
        #expect(throws: BinOps.BinError.tooDeep) { try BinOps.createFolder("L10", parent: parent, in: &p) }
        // moving a 2-level subtree under level 9 would exceed the limit
        let x = try BinOps.createFolder("X", parent: nil, in: &p)
        _ = try BinOps.createFolder("Y", parent: x, in: &p)
        let l8 = BinOps.path(to: parent, in: p)[8].id
        #expect(throws: BinOps.BinError.tooDeep) { try BinOps.moveFolder(x, to: l8, in: &p) }
    }

    @Test func ensurePathReusesFolders() throws {
        var p = Project()
        let f1 = try BinOps.ensurePath(["Shoot", "Day 1"], under: nil, in: &p)
        let f2 = try BinOps.ensurePath(["Shoot", "Day 1"], under: nil, in: &p)
        let f3 = try BinOps.ensurePath(["Shoot", "Day 2"], under: nil, in: &p)
        #expect(f1 == f2 && f1 != f3 && p.folders.count == 3)
    }

    @Test func commandsAreUndoable() throws {
        let (p, _) = Fx.project(mainClips: 1)
        var s = EditSession(project: p)
        try s.perform(BinCommand.createFolder("A", parent: nil))
        #expect(s.project.folders.count == 1)
        _ = s.undo()
        #expect(s.project.folders.isEmpty && s.project.mediaFolders == nil)
    }

    @Test func foldersAndMediaExtrasPersist() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        let f = try BinOps.createFolder("B-roll", parent: nil, in: &p)
        p.media[0].folderID = f
        p.media[0].conversion = .imageSequence
        p.media[0].sequence = ImageSequenceInfo(prefix: "s_", digits: 4, firstIndex: 1, count: 20, ext: "png")
        var info = MediaTechInfo(); info.audioTrackCount = 2; info.hasAlpha = true
        p.media[0].techInfo = info
        p.timeline[clip: ids[0]]!.audioStreamIndex = 1
        let data = try ProjectPackage.encoder().encode(p)
        let q = try ProjectPackage.decoder().decode(Project.self, from: data)
        #expect(q == p)
    }

    @Test func oldProjectJSONWithoutNewFieldsDecodes() throws {
        let (p, _) = Fx.project(mainClips: 1)
        var obj = try JSONSerialization.jsonObject(with: ProjectPackage.encoder().encode(p)) as! [String: Any]
        obj.removeValue(forKey: "mediaFolders")
        let q = try ProjectPackage.decoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(q.folders.isEmpty && q.media.count == 1)
    }
}

@Suite struct CaptionFileTests {
    @Test func parsesSRT() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nBonjour <i>tout</i> le monde\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nLigne 1\r\nLigne 2\r\n"
        let cues = CaptionFile.parse(srt, format: .srt)
        #expect(cues == [CaptionCue(start: Time(1), end: Time(2.5), text: "Bonjour tout le monde"),
                         CaptionCue(start: Time(3), end: Time(4), text: "Ligne 1\nLigne 2")])
    }

    @Test func parsesVTTAndLRC() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nHi\n"
        #expect(CaptionFile.parse(vtt, format: .vtt) == [CaptionCue(start: Time(1), end: Time(2), text: "Hi")])
        let lrc = "[ti:Song]\n[00:01.00]First\n[00:03.50][00:10.00]Chorus\n"
        let cues = CaptionFile.parse(lrc, format: .lrc)
        #expect(cues.map(\.text) == ["First", "Chorus", "Chorus"])
        #expect(cues[0].end == Time(3.5) && cues[2].end == Time(13))
    }

    @Test func parsesASSDialogue() {
        let ass = """
        [Script Info]
        Title: x
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\b1}Salut,\\Nça va ?
        """
        let cues = CaptionFile.parse(ass, format: .ass)
        #expect(cues == [CaptionCue(start: Time(1.5), end: Time(3), text: "Salut,\nça va ?")])
    }

    @Test func detectsLegacyEncodings() {
        let latin = "1\n00:00:01,000 --> 00:00:02,000\nCafé à l'été\n"
        let cp1252 = latin.data(using: .windowsCP1252)!
        #expect(CaptionFile.decode(cp1252)?.contains("Café à l'été") == true)
        let utf16 = Data([0xFF, 0xFE]) + latin.data(using: .utf16LittleEndian)!
        #expect(CaptionFile.decode(utf16)?.contains("été") == true)
        let bom = Data([0xEF, 0xBB, 0xBF]) + latin.data(using: .utf8)!
        #expect(CaptionFile.decode(bom)?.hasPrefix("1") == true)
    }

    @Test func insertsOnNewTextTrack() throws {
        var (p, _) = Fx.project(mainClips: 1)
        let cues = [CaptionCue(start: 0, end: 1, text: "a"), CaptionCue(start: Time(0.5), end: 2, text: "b")]  // overlap clipped
        let tid = try CaptionFile.insert(cues, into: &p)
        let track = p.timeline.tracks.first { $0.id == tid }!
        #expect(track.kind == .text && track.clips.count == 2)
        #expect(track.clips[1].start == Time(1))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }
}
