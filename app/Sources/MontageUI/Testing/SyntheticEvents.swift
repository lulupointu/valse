import AppKit
import MontageCore
import MontageEngine

/// Synthetic input for the UI test driver. Events are posted to the app's own event queue (`NSApp.postEvent`), so they
/// go through the real `NSApplication.sendEvent` → window → hit-tested view path, including AppKit tracking loops
/// (NSSlider) that pull events with `nextEvent`. Nothing is sent to the WindowServer: the real cursor, keyboard focus
/// and other apps are never touched.
@MainActor
enum SyntheticEvents {
    /// Event number of the last synthetic press / move (ClickProbe diagnostics).
    nonisolated(unsafe) private(set) static var eventNumber = 1000
    private static var clock = ProcessInfo.processInfo.systemUptime

    private static func timestamp() -> TimeInterval {
        clock = max(clock + 0.0001, ProcessInfo.processInfo.systemUptime)
        return clock
    }

    static func mouse(_ type: NSEvent.EventType, at p: CGPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                      clickCount: Int = 1) -> NSEvent? {
        // Like the WindowServer: one event number per click (down, drags and up share it).
        if type == .leftMouseDown || type == .rightMouseDown || type == .mouseMoved { eventNumber += 1 }
        let pressure: Float = (type == .leftMouseUp || type == .rightMouseUp || type == .mouseMoved) ? 0 : 1
        if useCGEvents, let cgType = CGEventType(rawValue: UInt32(type.rawValue)) {
            let screen = window.convertPoint(toScreen: p)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged) ? .right : .left
            if let cg = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: CGPoint(x: screen.x, y: primaryH - screen.y),
                                mouseButton: button) {
                cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
                cg.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                cg.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
                cg.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                cg.timestamp = UInt64(timestamp() * 1e9)
                if let e = NSEvent(cgEvent: cg), e.window === window { return e }
            }
        }
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: timestamp(),
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                  clickCount: clickCount, pressure: pressure)
    }

    static func post(_ e: NSEvent?) {
        guard let e else { return }
        if [.leftMouseDown, .rightMouseDown].contains(e.type) { buttonsDown = e.type == .leftMouseDown ? 1 : 2 }
        NSApp.postEvent(e, atStart: false)
    }

    /// Simulated `NSEvent.pressedMouseButtons` while a synthetic press is queued (cleared when the queue drains).
    /// AppKit tracking loops (NSSlider) poll the real hardware button state and would end immediately otherwise.
    nonisolated(unsafe) static var buttonsDown = 0
    static let useCGEvents = ProcessInfo.processInfo.environment["MONTAGE_UITEST_CG"] == "1"
    nonisolated(unsafe) static weak var testWindow: NSWindow?
    private static var hooked = false
    static func installPressedButtonsHook() {
        guard !hooked, ProcessInfo.processInfo.environment["MONTAGE_UITEST_NOHOOK"] != "1", let m = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)) else { return }
        hooked = true
        let original = method_getImplementation(m)
        typealias Fn = @convention(c) (AnyClass, Selector) -> Int
        let orig = unsafeBitCast(original, to: Fn.self)
        let block: @convention(block) (AnyClass) -> Int = { cls in
            if UITestWindow.debug { print("      [buttons] \(SyntheticEvents.buttonsDown)") }
            return SyntheticEvents.buttonsDown != 0 ? SyntheticEvents.buttonsDown : orig(cls, #selector(getter: NSEvent.pressedMouseButtons))
        }
        method_setImplementation(m, imp_implementationWithBlock(block))

        // In-process only: the app believes it is active with the test window key (SwiftUI gestures check this);
        // the real WindowServer activation state is untouched.
        for sel in [#selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.mainWindow)] {
            if let im = class_getInstanceMethod(NSApplication.self, sel) {
                typealias WFn = @convention(c) (NSApplication, Selector) -> NSWindow?
                let o = unsafeBitCast(method_getImplementation(im), to: WFn.self)
                let blk: @convention(block) (NSApplication) -> NSWindow? = { app in
                    SyntheticEvents.testWindow ?? o(app, sel)
                }
                method_setImplementation(im, imp_implementationWithBlock(blk))
            }
        }
        if ProcessInfo.processInfo.environment["MONTAGE_UITEST_NO_ACTIVE"] != "1",
           let im = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) {
            let blk: @convention(block) (NSApplication) -> Bool = { _ in true }
            method_setImplementation(im, imp_implementationWithBlock(blk))
        }
        // Pointer position as seen by tracking loops: follow the synthetic events as they are dequeued.
        if let a = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.nextEvent(matching:until:inMode:dequeue:))),
           let b = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.montage_nextEvent(matching:until:inMode:dequeue:))) {
            method_exchangeImplementations(a, b)
        }
        if let ml = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.mouseLocation)) {
            typealias LocFn = @convention(c) (AnyClass, Selector) -> NSPoint
            let origLoc = unsafeBitCast(method_getImplementation(ml), to: LocFn.self)
            let locBlock: @convention(block) (AnyClass) -> NSPoint = { cls in
                SyntheticEvents.screenLocation ?? origLoc(cls, #selector(getter: NSEvent.mouseLocation))
            }
            method_setImplementation(ml, imp_implementationWithBlock(locBlock))
        }
    }

    /// Last synthetic pointer location (window coordinates of the test window / screen coordinates).
    nonisolated(unsafe) static var windowLocation: NSPoint?
    nonisolated(unsafe) static var screenLocation: NSPoint?

    static func observeDequeued(_ e: NSEvent) {
        guard let w = e.window as? UITestWindow else { return }
        switch e.type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged, .mouseMoved, .leftMouseUp, .rightMouseUp:
            windowLocation = e.locationInWindow
            screenLocation = w.convertPoint(toScreen: e.locationInWindow)
            if e.type == .leftMouseUp || e.type == .rightMouseUp { buttonsDown = 0 }
            if e.type == .mouseMoved { TooltipCenter.shared.mouseMoved(to: e.locationInWindow, in: w) }   // C6: tracking areas need real moves
        default: break
        }
    }

    /// Click (down + up) at a window point (bottom-left origin).
    static func click(at p: CGPoint, in w: NSWindow, modifiers: NSEvent.ModifierFlags = [], count: Int = 1, right: Bool = false) {
        for c in 1...max(1, count) {
            post(mouse(right ? .rightMouseDown : .leftMouseDown, at: p, in: w, modifiers: modifiers, clickCount: c))
            post(mouse(right ? .rightMouseUp : .leftMouseUp, at: p, in: w, modifiers: modifiers, clickCount: c))
        }
    }

    /// Press at `from`, `steps` drag events along the segment, release at `to`.
    static func drag(from a: CGPoint, to b: CGPoint, in w: NSWindow, steps: Int = 12, modifiers: NSEvent.ModifierFlags = []) {
        post(mouse(.leftMouseDown, at: a, in: w, modifiers: modifiers))
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            post(mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: w, modifiers: modifiers))
        }
        post(mouse(.leftMouseUp, at: b, in: w, modifiers: modifiers))
    }

    static func move(to p: CGPoint, in w: NSWindow) { post(mouse(.mouseMoved, at: p, in: w)) }

    /// Pixel-precise scroll-wheel event at a window point. Positive dy scrolls content down (wheel "up"), like AppKit.
    /// `phase` (U1): a trackpad-style continuous scroll in a gesture phase (1 began, 2 changed, 4 ended), so scroll
    /// views rubber-band as under a real two-finger swipe; nil = a classic wheel tick.
    static func scroll(at p: CGPoint, in w: NSWindow, dx: CGFloat, dy: CGFloat, modifiers: NSEvent.ModifierFlags = [],
                       phase: Int64? = nil) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()),
                               wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        let screen = w.convertPoint(toScreen: p)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryH - screen.y)
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        }
        return NSEvent(cgEvent: cg)
    }

    // MARK: Keys

    struct KeySpec { let code: UInt16; let chars: String; let charsIgnoringMods: String; let mods: NSEvent.ModifierFlags }

    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, "+": 24,
    ]
    private static let named: [String: (UInt16, String)] = [
        "space": (49, " "), "return": (36, "\r"), "enter": (36, "\r"), "tab": (48, "\t"), "delete": (51, "\u{7f}"),
        "backspace": (51, "\u{7f}"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "forwarddelete": (117, "\u{F728}"),
        "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
    ]

    static func modifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        for n in names {
            switch n.lowercased() {
            case "cmd", "command", "⌘": m.insert(.command)
            case "shift", "⇧": m.insert(.shift)
            case "opt", "option", "alt", "⌥": m.insert(.option)
            case "ctrl", "control", "⌃": m.insert(.control)
            default: break
            }
        }
        return m
    }

    /// Parses "cmd+shift+z", "space", "left", "b", "+" (the key is the last `+`-separated token; "cmd++" = ⌘+).
    static func parseKey(_ s: String) -> KeySpec? {
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if s.hasSuffix("++") || s == "+" { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods = modifiers(Array(parts.dropLast()))
        if let (code, ch) = named[keyName.lowercased()] {
            if [115, 116, 117, 119, 121, 123, 124, 125, 126].contains(code) { mods.insert(.function) }
            if (123...126).contains(code) { mods.insert(.numericPad) }
            return KeySpec(code: code, chars: ch, charsIgnoringMods: ch, mods: mods)
        }
        guard keyName.count == 1, let c = keyName.first else { return nil }
        let lower = Character(c.lowercased())
        if c.isUppercase { mods.insert(.shift) }
        let code = letterCodes[lower] ?? 0
        let ign = String(lower)
        let chars = mods.contains(.shift) ? ign.uppercased() : ign
        return KeySpec(code: code, chars: mods.contains(.command) ? ign : chars, charsIgnoringMods: ign, mods: mods)
    }

    static func key(_ spec: KeySpec, in w: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            post(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: spec.mods, timestamp: timestamp(),
                                  windowNumber: w.windowNumber, context: nil, characters: spec.chars,
                                  charactersIgnoringModifiers: spec.charsIgnoringMods, isARepeat: false, keyCode: spec.code))
        }
    }

    /// Types text into the first responder (one key event per character).
    static func type(_ text: String, in w: NSWindow) {
        for ch in text {
            let s = String(ch)
            let code = letterCodes[Character(s.lowercased())] ?? 0
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                post(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: ch.isUppercase ? .shift : [], timestamp: timestamp(),
                                      windowNumber: w.windowNumber, context: nil, characters: s,
                                      charactersIgnoringModifiers: s.lowercased(), isARepeat: false, keyCode: code))
            }
        }
    }

    // MARK: Sentinel (wait until every posted event was dispatched)

    private static var seen: Int = 0
    private static var monitor: Any?
    private static var nextToken = 1

    /// Posts a marker event behind everything queued and waits until the main loop dispatched it.
    private static var keyMonitor: Any?

    /// AppKit only routes key events to the real key window, and a test app never has one: while text is being
    /// edited, deliver the test window's key events to it directly (other keys keep the normal path: app shortcut
    /// monitor, menu key equivalents).
    static func installKeyRouting() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            let box = UncheckedSendable(e)
            let handled = MainActor.assumeIsolated { () -> Bool in
                let e = box.value
                guard let w = e.window as? UITestWindow, w.firstResponder is NSText,
                      !e.modifierFlags.contains(.command) else { return false }
                // OB-11: ↑ / ↓ of a focused numeric field step it, like the app key monitor (`TextFieldKeys.route`)
                if NumericFieldKeys.handle(e, window: w) { return true }
                w.sendEvent(e)
                return true
            }
            return handled ? nil : e
        }
    }

    static func drain(timeout: Double = 10) async -> Bool {
        installKeyRouting()
        UITestDriver.heartbeat()   // every driver wait goes through here (scripts/uitest.sh hang detection)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { e in
                if e.subtype.rawValue == 0x7E57 { MainActor.assumeIsolated { SyntheticEvents.seen = max(SyntheticEvents.seen, e.data1) } }
                return e
            }
        }
        nextToken += 1
        let token = nextToken
        post(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: timestamp(), windowNumber: 0,
                                context: nil, subtype: 0x7E57, data1: token, data2: 0))
        let deadline = Date().addingTimeInterval(timeout)
        while seen < token {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        buttonsDown = 0
        return true
    }
}

/// `NSDraggingInfo` for simulated drag & drop onto a destination view (no WindowServer drag session).
final class SyntheticDraggingInfo: NSObject, NSDraggingInfo {
    let window: NSWindow
    var location: NSPoint
    let pasteboard: NSPasteboard
    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        self.window = window; self.location = location; self.pasteboard = pasteboard
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension NSApplication {
    /// Swizzled with `nextEvent(matching:until:inMode:dequeue:)` by `SyntheticEvents.installPressedButtonsHook` (UI tests
    /// only): calls the original, then records the synthetic pointer state of the event being handed out.
    @objc func montage_nextEvent(matching mask: NSEvent.EventTypeMask, until date: Date?, inMode mode: RunLoop.Mode,
                                 dequeue: Bool) -> NSEvent? {
        let e = montage_nextEvent(matching: mask, until: date, inMode: mode, dequeue: dequeue)
        if dequeue, let e { SyntheticEvents.observeDequeued(e) }
        if UITestWindow.debug, mode == .eventTracking { print("      [track] mask \(mask.rawValue) → \(e.map { "\($0.type.rawValue)" } ?? "nil")") }
        return e
    }
}
