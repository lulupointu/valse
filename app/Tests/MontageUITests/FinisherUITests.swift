import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Finisher rows: SE-016 scroll mapping, PB-013 drop meter, PB-003 optimization steps, SP-009 prompt / smooth playback,
/// TL-023 store flows, PB-015 keystroke feed.
@MainActor @Suite(.serialized) struct FinisherUITests {
    @Test func scrollMappingFollowsMouseSettings() {
        typealias M = TimelineScrollMapping
        // defaults: ⌘ zooms, wheel scrolls vertically, ⇧ horizontal
        #expect(M.action(dx: 0, dy: 3, command: true, option: false, shift: false, precise: false, wheel: .vertical, zoomModifier: .command) == .zoom(1.1))
        #expect(M.action(dx: 0, dy: 3, command: false, option: false, shift: false, precise: false, wheel: .vertical, zoomModifier: .command) == .scroll(dx: 0, dy: 3))
        #expect(M.action(dx: 0, dy: 3, command: false, option: false, shift: true, precise: false, wheel: .vertical, zoomModifier: .command) == .scroll(dx: 3, dy: 0))
        // horizontal wheel only for mice, trackpads keep 2D
        #expect(M.action(dx: 0, dy: 3, command: false, option: false, shift: false, precise: false, wheel: .horizontal, zoomModifier: .command) == .scroll(dx: 3, dy: 0))
        #expect(M.action(dx: 1, dy: 3, command: false, option: false, shift: false, precise: true, wheel: .horizontal, zoomModifier: .command) == .scroll(dx: 1, dy: 3))
        // ⌥ as zoom modifier; plain wheel zoom ("none") — ⌘ then scrolls
        #expect(M.action(dx: 0, dy: -3, command: false, option: true, shift: false, precise: false, wheel: .vertical, zoomModifier: .option) == .zoom(1 / 1.1))
        #expect(M.action(dx: 0, dy: 3, command: false, option: false, shift: false, precise: false, wheel: .vertical, zoomModifier: .none) == .zoom(1.1))
        #expect(M.action(dx: 0, dy: 3, command: true, option: false, shift: false, precise: false, wheel: .vertical, zoomModifier: .none) == .scroll(dx: 0, dy: 3))
        #expect(M.action(dx: 0, dy: 0, command: true, option: false, shift: false, precise: true, wheel: .vertical, zoomModifier: .command) == .none)
    }

    @Test func dropMeterLevels() {
        var m = FrameDropMeter()
        let fd = FrameRate.fps30.frameDuration
        var t = Time.zero
        for _ in 0..<90 { t += fd; m.presented(t, frameDuration: fd) }
        #expect(m.level == .ok && m.dropRatio == 0)
        for _ in 0..<40 { t += fd * 2; m.presented(t, frameDuration: fd) }   // every other frame dropped
        #expect(m.level == .lagging, "\(m.dropRatio)")
        for _ in 0..<200 { t += fd; m.presented(t, frameDuration: fd) }
        #expect(m.level == .ok)
        m.presented(t + Time(5), frameDuration: fd)                             // a seek is not a drop
        #expect(m.level == .ok)
        for i in 0..<120 { t += fd * (i % 8 == 0 ? 2 : 1); m.presented(t, frameDuration: fd) }
        #expect(m.level == .dropping, "\(m.dropRatio)")
    }

    func store() async throws -> EditorStore {
        var p = TestProject(canvas: Size2(320, 180))
        _ = try await p.addVideo(.solid(.red), seconds: 2)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return s
    }

    @Test func optimizationStepsLowerPreviewCost() async throws {
        let s = try await store()
        let h = s.playerUI.health
        s.previewQuality = .auto
        #expect(h.optimize(s, deep: false) && s.previewQuality == .half)
        #expect(!h.optimize(s, deep: false))                  // smart stops at half
        s.setUsesProxies(false)
        #expect(h.optimize(s, deep: true) && s.playerUI.usesProxies)
        #expect(h.optimize(s, deep: true) && s.previewQuality == .quarter)
        #expect(!h.optimize(s, deep: true))
    }

    @Test func frameRatePromptAndSmoothPlayback() async throws {
        let s = try await store()
        var a = s.project.media[0]
        a.frameRate = .fps60
        s.offerFrameRate(of: a)
        #expect(s.timelineUI.frameRatePrompt == .fps60)
        s.changeProjectFrameRate(.fps60)
        #expect(s.project.settings.frameRate == .fps60 && s.timelineUI.frameRatePrompt == nil)
        // the 30 fps clip is now below the project rate → optical flow on
        #expect(s.smoothPlayback(true) == 1)
        #expect(s.project.timeline.allClips.first { $0.mediaID != nil }?.smoothSlowMo == .opticalFlow)
        s.undo()
        #expect(s.project.timeline.allClips.first { $0.mediaID != nil }?.smoothSlowMo == nil)
        a.frameRate = .fps60
        s.offerFrameRate(of: a)                              // same as the project: no prompt
        #expect(s.timelineUI.frameRatePrompt == nil)
    }

    @Test func timelinesThroughStore() async throws {
        let s = try await store()
        s.newTimeline()
        #expect(s.timelineSlots.count == 2 && s.project.timeline.allClips.isEmpty)
        s.cycleTimeline(1)
        #expect(s.project.timeline.allClips.count == 1)
        s.renameTimeline(s.timelineSlots[0].id, to: "Main edit")
        #expect(s.timelineSlots[0].name == "Main edit")
        s.duplicateTimeline(s.timelineSlots[0].id)
        #expect(s.timelineSlots.count == 3 && s.timelineSlots[1].name.contains("Main edit"))
        s.deleteTimeline(s.timelineSlots[1].id)
        #expect(s.timelineSlots.count == 2)
        s.undo()
        #expect(s.timelineSlots.count == 3)
    }

    @Test func keystrokeFeedCollapsesRepeats() {
        let f = KeystrokeFeed()
        f.lifetimeOverride = 60
        f.push("⌘B"); f.push("⌘B"); f.push("Space")
        #expect(f.items.map(\.text) == ["⌘B", "Space"] && f.items[0].count == 2)
        for k in ["A", "B", "C", "D"] { f.push(k) }
        #expect(f.items.count == 4 && f.items.last?.text == "D")
    }

    @Test func duplicateFrameInsertsOneFrameHold() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let id = try await p.addVideo(.solid(.red), seconds: 2)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [id]
        s.transport.playhead = Time(1)
        s.duplicateFrame()
        let main = s.project.timeline.mainTrack!.clips
        #expect(main.count == 3)
        #expect(main[1].isFreezeFrame && main[1].duration == s.project.settings.frameRate.frameDuration)
        #expect(abs(s.project.duration.seconds - (2 + s.project.settings.frameRate.frameDuration.seconds)) < 0.001)
    }
}

/// PB-011 guides: typed positions, saved with the project, restored on load, never undoable.
@MainActor @Suite struct FinisherGuideTests {
    @Test func parsePixelsAndPercent() {
        #expect(GuidePositionMath.parse("540", length: 1080, percent: false) == 0.5)
        #expect(GuidePositionMath.parse("25 %", length: 1080, percent: false) == 0.25)
        #expect(GuidePositionMath.parse("12,5", length: 1080, percent: true) == 0.125)
        #expect(GuidePositionMath.parse("270px", length: 1080, percent: true) == 0.25)
        #expect(GuidePositionMath.parse("2000", length: 1080, percent: false) == nil)
        #expect(GuidePositionMath.parse("abc", length: 1080, percent: false) == nil)
    }

    @Test func guidesPersistWithTheProject() throws {
        let s = EditorStore()
        s.playerUI.guides.append(CanvasGuide(axis: .vertical, position: 0.3))
        #expect(s.project.guides == [ProjectGuide(vertical: true, position: 0.3)])
        #expect(s.session.undoStack.isEmpty)
        let data = try JSONEncoder().encode(s.projectForSave)
        let back = try JSONDecoder().decode(Project.self, from: data)
        let t = EditorStore()
        t.load(project: back)
        #expect(t.playerUI.guides.count == 1 && t.playerUI.guides[0].axis == .vertical && t.playerUI.guides[0].position == 0.3)
        t.load(project: Project())
        #expect(t.playerUI.guides.isEmpty)
    }
}

/// MI-009 lag prompt flow.
@MainActor @Suite struct FinisherLagPromptTests {
    @Test func heavyImportOffersTranscode() {
        let s = EditorStore()
        var a = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/fin-lag.mp4"), duration: Time(5),
                           pixelSize: Size2(3840, 2160), frameRate: .fps60, hasVideo: true, hasAudio: false, contentHash: UUID().uuidString)
        s.perform(AddMedia([a]))
        s.offerTranscode([a])
        #expect(s.timelineUI.lagPrompt == [a.id])
        s.transcodeForPlayback([a.id])
        #expect(s.timelineUI.lagPrompt == nil && s.playerUI.usesProxies)
        a.pixelSize = Size2(1280, 720); a.frameRate = .fps30
        s.offerTranscode([a])
        #expect(s.timelineUI.lagPrompt == nil)
    }
}

/// MI-018 store flow: an FCPXML opens as a new timeline tab (missing media reported).
@MainActor @Suite struct FinisherImportTimelineTests {
    @Test func fcpxmlBecomesANewTimeline() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10"><resources>
        <format id="r1" frameDuration="1/25s" width="1080" height="1920"/>
        <asset id="r2" name="Gone" start="0s" duration="10s" hasVideo="1"><media-rep kind="original-media" src="file:///tmp/fin-no-such-file.mov"/></asset>
        <effect id="r3" name="Basic Title" uid=".../Titles.localized/Basic Title.moti"/>
        </resources><library><event name="E"><project name="Imported cut"><sequence format="r1" duration="6s"><spine>
        <asset-clip ref="r2" offset="0s" start="1s" duration="3s"><title ref="r3" lane="1" offset="2s" start="0s" duration="1s"><text><text-style ref="t">Hi</text-style></text></title></asset-clip>
        <gap offset="3s" start="0s" duration="3s"/>
        </spine></sequence></project></event></library></fcpxml>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fin-import-\(UUID().uuidString).fcpxml")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = EditorStore()
        s.importTimeline(from: url)
        for _ in 0..<200 where s.timelineSlots.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(s.timelineSlots.count == 2)
        #expect(s.timelineSlots.first { $0.id == s.project.activeTimelineID }?.name == "Imported cut")
        #expect(s.project.settings.frameRate == .fps25 && s.project.settings.canvasSize == Size2(1080, 1920))
        // the missing media is skipped; the title (anchored at 2 s inside a clip starting at source 1 s) is at 1 s
        let text = s.project.timeline.allClips.first { if case .text = $0.content { return true }; return false }
        #expect(text?.start == Time(1))
    }
}
