import Testing
import Foundation
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
        f.lifetime = 60
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
