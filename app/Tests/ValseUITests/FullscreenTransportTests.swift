import Testing
import AppKit
import Foundation
import ValseCore
@testable import ValseUI

/// PB-006b full-screen overlay transport: visibility state machine (idle / pins / dead-band / key flash), seek-bar
/// maths (x ↔ time, snapping, fine scrub ⌥ + drag-away bands, scroll frames), context label, shortcut gating and the
/// compound range. No real window, no waiting: the model's clock and timer are injected.
@MainActor @Suite(.serialized) struct FullscreenTransportTests {
    // MARK: Visibility state machine

    final class Clock { var t: TimeInterval = 100 }

    func model(idle: TimeInterval = 3) -> (FullscreenControlsModel, Clock) {
        let m = FullscreenControlsModel(), c = Clock()
        m.now = { c.t }
        m.schedule = { _, _ in }   // tests call tick() after moving the clock
        m.hidesCursor = false
        m.idleTimeout = idle
        return (m, c)
    }

    @Test func entersVisibleThenHidesAfterIdle() {
        let (m, c) = model()
        m.enter(voiceOver: false)
        #expect(m.visibility == .visible && m.showCount == 1)
        c.t += 2.9; m.tick()
        #expect(m.visibility == .visible)
        c.t += 0.2; m.tick()
        #expect(m.visibility == .hidden)
    }

    @Test func pointerMovesPastTheDeadBandWakeAndRestartTheTimer() {
        let (m, c) = model()
        m.enter(voiceOver: false)
        m.pointerMoved(to: CGPoint(x: 100, y: 100))
        c.t += 3.1; m.tick()
        #expect(!m.isShown)
        m.pointerMoved(to: CGPoint(x: 101, y: 101))   // 1.4 pt: noise, stays hidden
        #expect(!m.isShown)
        m.pointerMoved(to: CGPoint(x: 103, y: 101))   // cumulative 3.4 pt
        #expect(m.isShown && m.showCount == 2)
        c.t += 2; m.tick()
        m.pointerMoved(to: CGPoint(x: 120, y: 101))   // restarts the 3 s
        c.t += 2; m.tick()
        #expect(m.isShown)
        c.t += 1.1; m.tick()
        #expect(!m.isShown)
    }

    @Test func pinsPreventTimeoutAndUnpinRestartsIt() {
        let (m, c) = model()
        m.enter(voiceOver: false)
        m.pin(.hover)
        #expect(m.visibility == .pinned)
        c.t += 30; m.tick()
        #expect(m.visibility == .pinned)
        m.pin(.drag); m.unpin(.hover)
        c.t += 30; m.tick()
        #expect(m.visibility == .pinned)
        m.unpin(.drag)
        #expect(m.visibility == .visible)
        c.t += 3; m.tick()
        #expect(m.visibility == .hidden)
    }

    @Test func voiceOverPinsForever() {
        let (m, c) = model()
        m.enter(voiceOver: true)
        c.t += 100; m.tick()
        #expect(m.visibility == .pinned && m.pins == [.voiceOver])
    }

    @Test func leavingTheWindowHidesAtOnceButNotWhileDragging() {
        let (m, _) = model()
        m.enter(voiceOver: false)
        m.pin(.hover)
        m.pointerLeft()
        #expect(m.visibility == .hidden)
        m.wake(); m.pin(.drag)
        m.pointerLeft()
        #expect(m.visibility == .pinned)
    }

    @Test func keyFlashesTheProgressLineOnlyWhileHidden() {
        let (m, c) = model()
        m.enter(voiceOver: false)
        m.keyActed()
        #expect(!m.isFlashing && m.flashCount == 0)   // bar visible: nothing more
        c.t += 3; m.tick()
        m.keyActed()
        #expect(m.isFlashing && m.flashCount == 1 && !m.isShown)
        c.t += 1.4; m.tick()
        #expect(m.isFlashing)
        c.t += 0.2; m.tick()
        #expect(!m.isFlashing)
        m.keyActed()
        m.pointerMoved(to: .zero); m.pointerMoved(to: CGPoint(x: 50, y: 0))   // a mouse move replaces it with the bar
        #expect(m.isShown && !m.isFlashing)
    }

    @Test func idleTimeoutInfinityNeverHides() {
        let (m, c) = model(idle: .infinity)
        m.enter(voiceOver: false)
        c.t += 1000; m.tick()
        #expect(m.isShown)
    }

    @Test func escapeCancelsADragFirst() {
        let (m, _) = model()
        m.enter(voiceOver: false)
        var cancelled = 0
        m.cancelDrag = { cancelled += 1; return true }
        #expect(!m.handleEscape())   // not scrubbing: esc leaves full screen
        m.isScrubbing = true
        #expect(m.handleEscape() && cancelled == 1)
    }

    @Test func exitResetsEverything() {
        let (m, _) = model()
        m.enter(voiceOver: false)
        m.pin(.drag); m.isScrubbing = true; m.hoverTime = 2
        m.exit()
        #expect(m.visibility == .hidden && m.pins.isEmpty && !m.isScrubbing && m.hoverTime == nil)
        m.pointerMoved(to: .zero); m.pointerMoved(to: CGPoint(x: 100, y: 0))
        #expect(!m.isShown)   // inactive outside full screen
    }

    // MARK: Seek-bar maths

    let tr = ScrubTrack(width: 1000, duration: Time(10), rate: .fps30)

    @Test func xToTimeIsClampedAndFrameSnapped() {
        #expect(tr.time(atX: 500) == Time(5))
        #expect(tr.time(atX: -40) == .zero)
        #expect(tr.time(atX: 5000) == Time(10) - FrameRate.fps30.frameDuration)   // last frame, never the end
        let t = tr.time(atX: 333.3)
        #expect(FrameRate.fps30.snap(t) == t)
        #expect(abs(tr.x(of: Time(2.5)) - 250) < 0.001)
        #expect(ScrubTrack(width: 0, duration: 10, rate: .fps30).time(atX: 10) == .zero)
        #expect(ScrubTrack(width: 100, duration: .zero, rate: .fps30).lastFrame == .zero)
    }

    @Test func snapsWithinSixPoints() {
        let r = tr.snapped(Time(5.04), to: [Time(5), Time(9)])   // 0.4 pt away
        #expect(r.snapped && r.time == Time(5))
        #expect(tr.snapped(Time(5.05), to: [Time(5)]).snapped)        // 5 pt
        let none = tr.snapped(Time(5.07), to: [Time(5)])            // 7 pt
        #expect(!none.snapped && none.time == Time(5.07))
        #expect(tr.near([Time(5), Time(5.05), Time(8)], x: 500) == [0, 1])
    }

    @Test func absoluteDragFollowsThePointer() {
        var d = ScrubDrag(x: 100, track: tr)
        #expect(d.time == Time(1))
        let r = d.update(x: 700, distanceAbove: 0, option: false, track: tr)
        #expect(r.time == Time(7) && !d.isFine && d.label == nil)
        let s = d.update(x: 502, distanceAbove: 10, option: false, track: tr, snapTargets: [Time(5)])
        #expect(s.snapped && s.time == Time(5))
    }

    @Test func optionDragIsTenTimesSlowerAndRelative() {
        var d = ScrubDrag(x: 500, track: tr)                   // 5 s
        _ = d.update(x: 500, distanceAbove: 0, option: true, track: tr)
        let r = d.update(x: 600, distanceAbove: 0, option: true, track: tr)   // +100 pt = +1 s at 1× → +0.1 s
        #expect(r.time == Time(5.1) && d.label == .option)
        // releasing ⌥ re-anchors: the knob does not jump; back to absolute = under the pointer
        let back = d.update(x: 600, distanceAbove: 0, option: false, track: tr)
        #expect(back.time == Time(6))
    }

    @Test func dragAwayBandsSlowDown() {
        #expect(ScrubSpeed.band(distanceAbove: -20) == .normal)
        #expect(ScrubSpeed.band(distanceAbove: 59) == .normal)
        #expect(ScrubSpeed.band(distanceAbove: 60) == .half)
        #expect(ScrubSpeed.band(distanceAbove: 130) == .quarter)
        #expect(ScrubSpeed.band(distanceAbove: 400) == .frame)
        var d = ScrubDrag(x: 500, track: tr)
        _ = d.update(x: 500, distanceAbove: 70, option: false, track: tr)       // half: anchor at 5 s
        #expect(d.update(x: 600, distanceAbove: 70, option: false, track: tr).time == Time(5.5))
        #expect(d.label == .half)
        _ = d.update(x: 600, distanceAbove: 150, option: false, track: tr)      // quarter: re-anchor at 5.5 s
        #expect(d.update(x: 700, distanceAbove: 150, option: false, track: tr).time == tr.clamp(Time(5.75)))
        _ = d.update(x: 700, distanceAbove: 300, option: false, track: tr)      // frame by frame: 8 pt per frame
        let f = d.update(x: 724, distanceAbove: 300, option: false, track: tr).time
        #expect(f == tr.clamp(Time(5.75)) + FrameRate.fps30.frameDuration * 3.0)
        #expect(d.label == .frame)
        _ = d.update(x: -500, distanceAbove: 300, option: false, track: tr)
        #expect(d.time >= .zero)
    }

    @Test func scrollStepsWholeFrames() {
        var s = ScrollFrameStepper()
        #expect(s.frames(dx: -5, dy: 0, precise: true) == 0)
        #expect(s.frames(dx: -5, dy: 0, precise: true) == 1)    // 10 pt → 1 frame, 2 carried
        #expect(s.frames(dx: -14, dy: 0, precise: true) == 2)
        #expect(s.frames(dx: 16, dy: 0, precise: true) == -2)
        #expect(s.frames(dx: 0, dy: 30, precise: true) == 0)    // vertical trackpad scroll is not a seek
        #expect(s.frames(dx: 0, dy: -1, precise: false) == 1)   // wheel down = forward one frame
        #expect(s.frames(dx: 0, dy: 3, precise: false) == -1)
    }

    // MARK: Context label (compound breadcrumb, timelines, preview)

    @Test func contextLabel() {
        #expect(FullscreenContext.label(previewTitle: nil, compoundPath: [], rootName: "Main timeline", timelineNames: ["A"], activeTimeline: "A") == nil)
        #expect(FullscreenContext.label(previewTitle: nil, compoundPath: ["Intro", "Logo"], rootName: "Main timeline", timelineNames: [],
                                        activeTimeline: nil) == "Main timeline › Intro › Logo")
        #expect(FullscreenContext.label(previewTitle: nil, compoundPath: [], rootName: "Main timeline", timelineNames: ["A", "B"],
                                        activeTimeline: "B") == "B")
        #expect(FullscreenContext.label(previewTitle: "Previewing — Effects", compoundPath: ["X"], rootName: "M", timelineNames: [],
                                        activeTimeline: nil) == "Previewing — Effects")
    }

    // MARK: Store integration: compound range, shortcuts, nudge

    func store() throws -> (EditorStore, [ClipID]) {
        let (p, ids) = try TimelineUITests().project(clips: 3)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        s.playerUI.fullscreenCoordinator.windowProvider = { nil }
        return (s, ids)
    }

    func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func insideACompoundTheBarSpansTheCompound() throws {
        var (p, ids) = try TimelineUITests().project(clips: 3)
        let cid = try TimelineOps.createCompound([ids[1]], name: "Intro", in: &p)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        s.playerUI.fullscreenCoordinator.windowProvider = { nil }
        #expect(ScrubSource(s).duration == Time(12))
        s.enterCompound(cid)
        s.setPlayerFullscreen(true)
        let src = ScrubSource(s)
        #expect(src.duration == Time(4) && src.duration == s.projectDuration)
        #expect(CompoundEditing.path(s.project) == ["Intro"])
        s.setPlayerFullscreen(false)
    }

    @Test func editingShortcutsAreSwallowedInFullscreenButReviewKeysStay() throws {
        let (s, ids) = try store()
        s.selection = [ids[0]]
        s.setPlayerFullscreen(true)
        let clips = s.project.timeline.allClips.count, depth = s.canUndo
        #expect(ShortcutRegistry.handle(key("q", 12), store: s))                 // delete left: swallowed
        #expect(ShortcutRegistry.handle(key("b", 11, .command), store: s))       // split: swallowed
        #expect(ShortcutRegistry.handle(key("\u{7F}", 51), store: s))            // delete: swallowed
        #expect(ShortcutRegistry.handle(key("z", 6, .command), store: s))        // undo: swallowed
        #expect(s.project.timeline.allClips.count == clips && s.canUndo == depth)
        s.selection = []
        #expect(ShortcutRegistry.handle(key("m", 46), store: s))                 // marker: allowed
        #expect(s.project.timeline.markers.count == 1)
        #expect(ShortcutRegistry.handle(key("i", 34), store: s))                 // in point: allowed
        #expect(s.project.timeline.inPoint != nil)
        s.setPlayerFullscreen(false)
        #expect(ShortcutRegistry.handle(key("v", 9), store: s))                  // outside full screen: editing works again
    }

    @Test func arrowsNeverNudgeInFullscreen() throws {
        let (s, ids) = try store()
        s.selection = [ids[0]]
        s.playerUI.canvasHasFocus = true
        #expect(s.canvasNudgeEnabled)
        s.setPlayerFullscreen(true)
        #expect(!s.canvasNudgeEnabled)
        s.playerUI.isDetachedFullscreen = true
        s.setPlayerFullscreen(false)
        #expect(s.playerUI.isViewingFullscreen && !s.canvasNudgeEnabled)   // the detached window's full screen too
        s.playerUI.isDetachedFullscreen = false
    }

    @Test func enteringShowsTheBarAndLeavingRevealsThePlayhead() throws {
        let (s, _) = try store()
        s.timelineUI.viewWidth = 400 + Double(TimelineLayout.headerWidth)
        s.pixelsPerSecond = 100   // 4 s visible
        s.timelineUI.scrollTime = 0
        s.setPlayerFullscreen(true)
        #expect(s.playerUI.fullscreenControls.isShown)
        s.transport.playhead = Time(9)
        s.setPlayerFullscreen(false)
        #expect(!s.playerUI.fullscreenControls.isShown)
        #expect(abs(s.timelineUI.scrollTime - (9 - 4.0 / 3)) < 0.001)   // playhead at 1/3 of the visible width
        s.setPlayerFullscreen(true)
        s.transport.playhead = Time(9.5)                                 // visible: nothing moves
        s.setPlayerFullscreen(false)
        #expect(abs(s.timelineUI.scrollTime - (9 - 4.0 / 3)) < 0.001)
    }

    @Test func thumbnailSizes() {
        #expect(FullscreenThumbnailLoader.pointSize(canvas: Size2(1920, 1080)) == CGSize(width: 160, height: 90))
        #expect(FullscreenThumbnailLoader.pixelHeight(canvas: Size2(1920, 1080)) == 180)
        let portrait = FullscreenThumbnailLoader.pointSize(canvas: Size2(1080, 1920))
        #expect(portrait.height == 120 && portrait.width < 70)
    }
}
