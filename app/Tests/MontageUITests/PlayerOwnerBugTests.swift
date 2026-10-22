import Testing
import Foundation
import AppKit
import MontageCore
import MontageEngine
@testable import MontageUI

/// Owner bug reports on the player canvas and key routing: OB-04 (text box resize keeps its centre), OB-11 (caret keys
/// in text fields, ↑ / ↓ in numeric fields), OB-12 (a click on another layer over the selection selects it).
@MainActor @Suite(.serialized) struct PlayerOwnerBugTests {
    let canvas = Size2(1920, 1080)

    func geometry(center: Vec2, half: Vec2, rotation: Double = 0) -> LayerGeometry {
        var g = LayerGeometry(sourceSize: Size2(2, 2), canvasSize: canvas, transform: Transform(), fitsCanvas: false)
        g.center = center; g.halfSize = half; g.rotation = rotation
        return g
    }

    // MARK: OB-04

    @Test func textBoxResizeFromTheCentreNeverMovesTheBox() {
        let g = geometry(center: Vec2(960, 540), half: Vec2(200, 40))
        // shrink, expand, past the minimum (pointer across the centre) and far past the maximum: the centre stays
        for x in [1100.0, 1400, 960, 700, 1e6] {
            for edge in [1, 3] {
                let r = CanvasHandles.textBoxResize(g, edge: edge, dragTo: Vec2(x, 540), fromCenter: true, layerScale: 1,
                                                    canvasWidth: canvas.width)
                #expect(r.shift == .zero)
                #expect(r.width >= 0.03 && r.width <= 4)
            }
        }
        let small = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(1060, 540), fromCenter: true, layerScale: 1, canvasWidth: canvas.width)
        #expect(abs(small.width - 200.0 / 1920) < 1e-9)
    }

    @Test func oneSideResizeFollowsTheRealBoxWidthAndStopsAtItsLimits() {
        // the text hugs its lines: natural width 400 px (half 200), longest word 120 px (half 60)
        let half: (Double) -> Double = { w in min(max(w * 1920 / 2, 60), 200) }
        let g = geometry(center: Vec2(960, 540), half: Vec2(200, 40))
        // expanding beyond the natural width: the box can't grow, so it must not move
        for x in [1300.0, 1600, 3000] {
            let r = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(x, 540), fromCenter: false, layerScale: 1,
                                                canvasWidth: canvas.width, halfWidth: half)
            #expect(abs(r.shift.x) < 1e-9 && abs(r.shift.y) < 1e-9)
        }
        // shrinking: left edge (760) stays → 300 px wide, centre 910
        let s = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(1060, 540), fromCenter: false, layerScale: 1,
                                            canvasWidth: canvas.width, halfWidth: half)
        #expect(abs(s.shift.x - -50) < 1e-9)
        // at the minimum (longest word) the shift no longer changes however far the pointer goes
        let a = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(800, 540), fromCenter: false, layerScale: 1,
                                            canvasWidth: canvas.width, halfWidth: half)
        let b = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(100, 540), fromCenter: false, layerScale: 1,
                                            canvasWidth: canvas.width, halfWidth: half)
        #expect(abs(a.shift.x - -140) < 1e-9 && a.shift == b.shift)
    }

    /// Real text layout: setting the wrap width the centre drag computes keeps the laid-out box centred on the position.
    @Test func realTextBoxStaysCentredWhenItsWidthChanges() throws {
        var p = Project(settings: ProjectSettings(canvasSize: canvas))
        let c = Clip(content: .text(TextContent(string: "Hello wonderful world of text")), start: .zero, duration: Time(3))
        try TimelineOps.insert(c, into: &p)
        let before = try #require(CanvasLayers.at(Time(1), project: p).first)
        for x in [before.geometry.center.x + 80, before.geometry.center.x + 900, before.geometry.center.x + 5] {
            let r = CanvasHandles.textBoxResize(before.geometry, edge: 1, dragTo: Vec2(x, before.geometry.center.y), fromCenter: true,
                                                layerScale: 1, canvasWidth: canvas.width)
            var q = p
            guard var clip = q.timeline.clip(c.id), case .text(var t) = clip.content else { Issue.record("no text"); return }
            t.boxWidth = r.width
            clip.content = .text(t)
            q.timeline[clip: c.id] = clip
            let after = try #require(CanvasLayers.at(Time(1), project: q).first)
            #expect(abs(after.geometry.center.x - before.geometry.center.x) < 1e-6)
            #expect(abs(after.geometry.center.y - before.geometry.center.y) < 1e-6)
        }
    }

    // MARK: OB-12

    @Test func clickOnAnotherLayerOverTheSelectionSelectsIt() {
        let video = CanvasLayer(clipID: ClipID(), geometry: geometry(center: Vec2(960, 540), half: Vec2(960, 540)), isText: false, isLocked: false)
        let text = CanvasLayer(clipID: ClipID(), geometry: geometry(center: Vec2(960, 800), half: Vec2(200, 40)), isText: true, isLocked: false)
        let layers = [video, text]
        // the video is selected: a click on the text (stacked above) goes to the text
        #expect(CanvasLayers.bodyPressTarget(layers, selected: video.clipID, at: Vec2(960, 800))?.clipID == text.clipID)
        // elsewhere on the video: keep transforming the video
        #expect(CanvasLayers.bodyPressTarget(layers, selected: video.clipID, at: Vec2(200, 200)) == nil)
        // the text is selected and on top: it keeps the press
        #expect(CanvasLayers.bodyPressTarget(layers, selected: text.clipID, at: Vec2(960, 800)) == nil)
        // a locked layer above the selection doesn't take it
        var locked = text; locked.isLocked = true
        #expect(CanvasLayers.bodyPressTarget([video, locked], selected: video.clipID, at: Vec2(960, 800)) == nil)
    }

    // MARK: OB-11

    func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        let fn: NSEvent.ModifierFlags = (123...126).contains(code) ? [.function, .numericPad] : [.function]
        func f(_ k: Int) -> String { String(Character(UnicodeScalar(UInt32(k))!)) }
        let ch: String
        switch code {
        case 123: ch = f(NSLeftArrowFunctionKey)
        case 124: ch = f(NSRightArrowFunctionKey)
        case 125: ch = f(NSDownArrowFunctionKey)
        case 126: ch = f(NSUpArrowFunctionKey)
        default: ch = "a"
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods.union(code == 0 ? [] : fn), timestamp: 0,
                                windowNumber: 0, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false,
                                keyCode: code)!
    }

    func editingWindow(_ text: String) -> (NSWindow, NSTextField) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let tf = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        tf.stringValue = text
        w.contentView?.addSubview(tf)
        #expect(w.makeFirstResponder(tf))
        return (w, tf)
    }

    @Test func caretKeysGoToTheFocusedTextFieldNotToShortcuts() throws {
        let (w, _) = editingWindow("abcd")
        let editor = try #require(w.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(TextFieldKeys.route(key(123), window: w))        // ← moves the caret
        #expect(editor.selectedRange().location == 3)
        #expect(TextFieldKeys.route(key(123, .shift), window: w)) // ⇧← extends the selection
        #expect(editor.selectedRange() == NSRange(location: 2, length: 1))
        #expect(TextFieldKeys.route(key(124), window: w))        // →
        #expect(!TextFieldKeys.route(key(123, .command), window: w))   // ⌘← stays a menu / editor shortcut
        #expect(!TextFieldKeys.route(key(0), window: w))         // letters keep the normal path
        // no text focused: shortcuts as usual
        w.makeFirstResponder(nil)
        #expect(!TextFieldKeys.route(key(123), window: w))
        w.close()
    }

    @Test func upDownStepAFocusedNumericField() {
        let (w, _) = editingWindow("10")
        #expect(NumericFieldKeys.steps(keyCode: 126, shift: false) == 1)
        #expect(NumericFieldKeys.steps(keyCode: 125, shift: true) == -10)
        #expect(NumericFieldKeys.steps(keyCode: 123, shift: false) == nil)
        var steps: [Int] = []
        let token = UUID()
        NumericFieldKeys.focus(token, step: { steps.append($0) })
        #expect(TextFieldKeys.route(key(126), window: w))
        #expect(TextFieldKeys.route(key(125, .shift), window: w))
        #expect(!NumericFieldKeys.handle(key(126, .option), window: w))
        #expect(steps == [1, -10])
        NumericFieldKeys.update(UUID(), step: { _ in Issue.record("another field's closure") })   // ignored
        #expect(NumericFieldKeys.handle(key(126), window: w))
        #expect(steps == [1, -10, 1])
        NumericFieldKeys.blur(token)
        #expect(!NumericFieldKeys.handle(key(126), window: w))
        w.close()
    }
}
