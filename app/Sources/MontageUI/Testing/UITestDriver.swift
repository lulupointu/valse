import AppKit
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI

/// The UI test window: never activated, placed far off every screen, so tests can't cover or steal input from the
/// user's apps. It reports itself as key so first clicks are not swallowed and controls render in their active state.
public final class UITestWindow: NSWindow {
    public static let offscreenOrigin: CGPoint = {
        if let s = ProcessInfo.processInfo.environment["MONTAGE_UITEST_ORIGIN"] {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 { return CGPoint(x: p[0], y: p[1]) }
        }
        return CGPoint(x: -30000, y: -30000)
    }()
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
    public override var isKeyWindow: Bool { true }
    public override var isMainWindow: Bool { true }
    static let fakeVisible = ProcessInfo.processInfo.environment["MONTAGE_UITEST_VISIBLE"] == "1"
    public override var occlusionState: NSWindow.OcclusionState { Self.fakeVisible ? [.visible] : super.occlusionState }
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    public override func center() { setFrameOrigin(Self.offscreenOrigin) }
    public override func makeKeyAndOrderFront(_ sender: Any?) { orderBack(sender) }
    static let debug = ProcessInfo.processInfo.environment["MONTAGE_UITEST_DEBUG"] == "1"
    private var mouseTarget: NSView?

    /// The test app is never active, so NSWindow treats every click as a "first click" into an inactive window and
    /// only delivers it to views that accept first mouse. SwiftUI answers per gesture: `Button` yes, `onTapGesture` /
    /// `DragGesture` no — so those never fired. In the UI test process only, every SwiftUI hosting class accepts first
    /// mouse (what a click into the already-active window would do).
    private static var firstMouseClasses: Set<ObjectIdentifier> = []
    static func acceptFirstMouse(_ hit: NSView) {
        var v: NSView? = hit
        while let x = v {
            if let cls = object_getClass(x), firstMouseClasses.insert(ObjectIdentifier(cls)).inserted {
                let blk: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
                class_replaceMethod(cls, #selector(NSView.acceptsFirstMouse(for:)), imp_implementationWithBlock(blk), "B24@0:8@16")
            }
            v = x.superview
        }
    }

    /// SwiftUI-internal views (event handling goes through NSWindow's own dispatch) vs AppKit views.
    static func isSwiftUIView(_ v: NSView) -> Bool {
        if v is NSControl || v is NSText { return false }  // AppKit controls hosted by SwiftUI (NSSlider, NSTextField…)
        let name = String(reflecting: type(of: v))
        return name.hasPrefix("SwiftUI.") || name.contains("NSHostingView") || name.contains("_NSHosting")
    }
    static let emulateSliders = ProcessInfo.processInfo.environment["MONTAGE_UITEST_NATIVE_SLIDERS"] != "1"
    static let sliderJump = ProcessInfo.processInfo.environment["MONTAGE_UITEST_SLIDER_CELL"] != "1"

    /// NSSlider's own tracking loop stops after the first synthetic drag (it polls hardware state we can't fake), so
    /// slider drags are replayed through the cell's tracking API with the already-queued events of the gesture.
    private func trackSlider(_ slider: NSSlider, down: NSEvent) {
        guard let cell = slider.cell else { return }
        var events: [NSEvent] = []
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .eventTracking, dequeue: true) {
            events.append(e)
            if e.type == .leftMouseUp { break }
        }
        func local(_ e: NSEvent) -> NSPoint { slider.convert(e.locationInWindow, from: nil) }
        func value(at p: NSPoint) -> Double {
            let knob = (cell as? NSSliderCell)?.knobThickness ?? 0
            let b = slider.bounds
            let f = slider.isVertical ? (p.y - b.minY - knob / 2) / max(1, b.height - knob) : (p.x - b.minX - knob / 2) / max(1, b.width - knob)
            let k = min(max(Double(slider.isVertical && slider.isFlipped ? 1 - f : f), 0), 1)
            return slider.minValue + (slider.maxValue - slider.minValue) * k
        }
        if Self.sliderJump, let end = events.last {
            // Native path: a press at the final position (the slider jumps there) + release, through NSSlider.mouseDown.
            let p = end.locationInWindow
            guard let d = SyntheticEvents.mouse(.leftMouseDown, at: p, in: self, modifiers: down.modifierFlags),
                  let u = SyntheticEvents.mouse(.leftMouseUp, at: p, in: self, modifiers: down.modifierFlags) else { return }
            NSApp.postEvent(u, atStart: true)
            slider.mouseDown(with: d)
            return
        }
        var last = local(down)
        _ = cell.startTracking(at: last, in: slider)
        slider.doubleValue = value(at: last)
        slider.sendAction(slider.action, to: slider.target)
        for e in events {
            let p = local(e)
            if e.type == .leftMouseDragged {
                _ = cell.continueTracking(last: last, current: p, in: slider)
                slider.doubleValue = value(at: p)
                slider.sendAction(slider.action, to: slider.target)
            } else {
                slider.doubleValue = value(at: p)
                cell.stopTracking(last: last, current: p, in: slider, mouseIsUp: true)
                slider.sendAction(slider.action, to: slider.target)
            }
            last = p
        }
    }
    public override var mouseLocationOutsideOfEventStream: NSPoint {
        SyntheticEvents.windowLocation ?? super.mouseLocationOutsideOfEventStream
    }

    /// Mouse events are routed here like NSWindow does for an active window (hit-test on down, then the same view gets
    /// drags and the up). AppKit drops clicks on windows of an inactive app, and a test app is never active.
    public override func sendEvent(_ event: NSEvent) {
        let hit = { [self] in contentView.flatMap { $0.hitTest($0.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) } }
        if Self.debug {
            print("      [event] \(event.type.rawValue) at \(event.locationInWindow) → \(hit().map { String(describing: type(of: $0)) } ?? "nil")")
        }
        // SwiftUI content (the hosting view itself) handles events through NSWindow's own dispatch; AppKit views
        // (timeline, player, NSSlider/NSPopUpButton inside SwiftUI) get them directly.
        func isSwiftUI(_ v: NSView?) -> Bool { v.map(Self.isSwiftUIView) ?? true }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let v = hit() else { return }
            mouseTarget = v
            if let slider = v as? NSSlider, event.type == .leftMouseDown, Self.emulateSliders {
                trackSlider(slider, down: event); mouseTarget = nil; return
            }
            if isSwiftUI(v) { Self.acceptFirstMouse(v); super.sendEvent(event); return }
            if v.acceptsFirstResponder { makeFirstResponder(v) }
            event.type == .leftMouseDown ? v.mouseDown(with: event) : v.rightMouseDown(with: event)
        case .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp:
            if isSwiftUI(mouseTarget) {
                super.sendEvent(event)
                if event.type == .leftMouseUp || event.type == .rightMouseUp { mouseTarget = nil }
                return
            }
            switch event.type {
            case .leftMouseDragged: mouseTarget?.mouseDragged(with: event)
            case .rightMouseDragged: mouseTarget?.rightMouseDragged(with: event)
            case .leftMouseUp: mouseTarget?.mouseUp(with: event); mouseTarget = nil
            default: mouseTarget?.rightMouseUp(with: event); mouseTarget = nil
            }
        case .mouseMoved, .scrollWheel:
            let v = hit()
            if isSwiftUI(v) { super.sendEvent(event) }
            else if event.type == .mouseMoved { v?.mouseMoved(with: event) } else { v?.scrollWheel(with: event) }
        default: super.sendEvent(event)
        }
    }
}

/// Runs a JSON UI test script inside the app (`Montage --uitest script.json`, wrapped by scripts/uitest.sh).
/// Script format, step reference and examples: docs/TESTING.md. Exit code 0 = all steps passed.
@MainActor
public final class UITestDriver {
    public struct Config {
        public var script: URL
        public var outDir: URL?
        public var baselines: URL?
        public var updateBaselines = false
        public init(script: URL, outDir: URL? = nil, baselines: URL? = nil, updateBaselines: Bool = false) {
            self.script = script; self.outDir = outDir; self.baselines = baselines; self.updateBaselines = updateBaselines
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    let store: EditorStore
    let window: NSWindow
    let config: Config
    private var out: URL!
    private var metrics: [String: Double] = [:]
    private var report: [[String: Any]] = []
    private var warnings: [String] = []
    /// Destination of a `"hold": true` drop (hovering, not dropped yet).
    private var heldDropView: NSView?
    private let probe = TimelineFrameProbe()
    private var launchMs: Double = 0

    /// Creates the offscreen test window (call before building the content view; enables `.testID` geometry tracking).
    public static func makeWindow(size: CGSize) -> NSWindow {
        TestAnchors.isEnabled = true
        SyntheticEvents.installPressedButtonsHook()
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.offscreenOrigin, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        w.setFrameOrigin(UITestWindow.offscreenOrigin)
        SyntheticEvents.testWindow = w
        return w
    }

    /// App-level project setups (e.g. W12's `"project": "home"`): return true when handled.
    public static var projectHook: (@MainActor (String) async throws -> Bool)?

    public init(store: EditorStore, window: NSWindow, config: Config) {
        self.store = store; self.window = window; self.config = config
    }

    // MARK: Run

    public func run() async -> Int32 {
        let savedLanguagePref = UserDefaults.standard.object(forKey: L10n.overrideDefaultsKey)
        defer {
            if let savedLanguagePref { UserDefaults.standard.set(savedLanguagePref, forKey: L10n.overrideDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.overrideDefaultsKey) }
        }
        let t0 = Date()
        let script: [String: Any]
        do { script = try Self.loadScript(config.script) } catch {
            log("✘ cannot read script \(config.script.path): \(error)"); return 2
        }
        let name = (script["name"] as? String) ?? config.script.deletingPathExtension().lastPathComponent
        out = config.outDir ?? URL(fileURLWithPath: "build/uitest/\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log("▶ \(name)  (out: \(out.path))")

        // Launch to an editor window that has laid out and drawn once (before the script's project is loaded).
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        launchMs = ProcessLaunch.millisecondsSinceStart()
        if let reason = Self.applyModelPolicy(script) {
            StateDump.write(["name": name, "script": config.script.path, "passed": true, "skipped": reason, "steps": [Any]()],
                            to: out.appendingPathComponent("report.json"))
            log("⏭ \(name) SKIPPED: \(reason)")
            return Self.skipExitCode
        }
        var failed: String?
        do {
            try await setUp(script)
            let steps = (script["steps"] as? [Any]) ?? []
            for (i, raw) in steps.enumerated() {
                guard let step = raw as? [String: Any] else { throw Failure("step \(i + 1) is not an object") }
                let s0 = Date()
                let label = Self.describe(step)
                do {
                    try await perform(step, index: i + 1)
                    report.append(["index": i + 1, "step": label, "ok": true, "ms": Int(Date().timeIntervalSince(s0) * 1000)])
                    log("  ✔ \(i + 1). \(label)")
                } catch {
                    report.append(["index": i + 1, "step": label, "ok": false, "error": "\(error)"])
                    log("  ✘ \(i + 1). \(label)\n      \(error)")
                    failed = "step \(i + 1) (\(label)): \(error)"
                    break
                }
            }
        } catch {
            failed = "setup: \(error)"
            log("  ✘ setup: \(error)")
        }
        // Always leave a final state + picture for debugging.
        StateDump.write(StateDump.make(store), to: out.appendingPathComponent(failed == nil ? "final.json" : "failure.json"))
        if failed != nil, let img = SnapshotRegistry.shared.snapshot(window: window) {
            ImageDiff.writePNG(img, to: out.appendingPathComponent("failure.png"))
        }
        let summary: [String: Any] = [
            "name": name, "script": config.script.path, "passed": failed == nil, "error": failed ?? NSNull(),
            "seconds": Date().timeIntervalSince(t0), "steps": report, "metrics": metrics, "warnings": warnings,
        ]
        StateDump.write(summary, to: out.appendingPathComponent("report.json"))
        for w in warnings { log("  ⚠︎ \(w)") }
        log(failed == nil ? "✔ \(name) passed (\(report.count) steps, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s)"
                          : "✘ \(name) FAILED: \(failed!)")
        return failed == nil ? 0 : 1
    }

    /// Exit code of a script whose preconditions are not met (scripts/uitest.sh reports it as SKIPPED, not failed).
    public static let skipExitCode: Int32 = 3

    /// AI models are environment-dependent, so by default a script sees an EMPTY models folder: every model is
    /// "not installed" on every machine and AI scripts assert the "Download model" UX. A script that needs real
    /// inference declares `"requires": {"models": ["coreml.lama-800"]}`: it then uses the user's models folder
    /// (`MONTAGE_MODELS_DIR` or ~/Library/Application Support/Montage/Models) and is SKIPPED (reason returned) when one is missing.
    static func applyModelPolicy(_ script: [String: Any]) -> String? {
        // `"requires": {"content": true}`: the bundled music/SFX library audio (scripts/fetch_music_pack.sh cache)
        if (script["requires"] as? [String: Any])?["content"] as? Bool == true, ContentLibrary.availableMusic.isEmpty {
            return "requires the music/SFX library (run scripts/fetch_music_pack.sh)"
        }
        let required = ((script["requires"] as? [String: Any])?["models"] as? [String]) ?? []
        defer { ModelManager.shared.refresh() }
        ModelCatalog.isSandboxed = required.isEmpty
        if required.isEmpty {
            ModelCatalog.directoryOverride = FileManager.default.temporaryDirectory
                .appendingPathComponent("montage-uitest-models-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return nil
        }
        if let d = ProcessInfo.processInfo.environment["MONTAGE_MODELS_DIR"], !d.isEmpty {
            ModelCatalog.directoryOverride = URL(fileURLWithPath: d, isDirectory: true)
        } else {
            ModelCatalog.directoryOverride = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Montage/Models", isDirectory: true)
        }
        let missing = required.filter { id in ModelCatalog.spec(id).flatMap(ModelCatalog.installedURL) == nil }
        guard !missing.isEmpty else { return nil }
        return "requires model(s) \(missing.joined(separator: ", ")) not installed in \(ModelCatalog.modelsDirectory.path) "
            + "(download in Settings ▸ AI models, or set MONTAGE_MODELS_DIR)"
    }

    static func loadScript(_ url: URL) throws -> [String: Any] {
        let text = try String(contentsOf: url, encoding: .utf8)
        // `//` line comments are allowed.
        let stripped = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        guard let obj = try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
            throw Failure("top level must be an object")
        }
        return obj
    }

    func log(_ s: String) { print(s); fflush(stdout) }

    // MARK: Setup

    private func setUp(_ script: [String: Any]) async throws {
        store.autosaveEnabled = false
        L10n.shared.setLanguageForSession((script["lang"] as? String) ?? "en")
        if let size = script["size"] as? [NSNumber], size.count == 2 {
            window.setContentSize(NSSize(width: size[0].doubleValue, height: size[1].doubleValue))
        }
        let project = (script["project"] as? String) ?? "empty"
        if let hook = Self.projectHook, try await hook(project) {
            try await idle(settle: (script["settle"] as? NSNumber)?.doubleValue ?? 1.5)
            return
        }
        switch project {
        case "empty":
            store.load(project: Project())
        case "demo":
            store.load(project: try await DemoProject.make())
        case "demo-bin":
            var p = try await DemoProject.make()
            p.timeline = Timeline()
            store.load(project: p)
        case let s where s.hasPrefix("demo-transcript"):   // C4: demo + a known transcript (TranscriptDemo)
            try await TranscriptDemo.load(s, into: store)
        case let s where s.hasPrefix("media:"):   // W13: N bin items (demo media repeated), empty timeline
            let n = Int(s.split(separator: ":").last ?? "") ?? 1000
            store.load(project: try await StressProject.makeBin(items: n))
        case let s where s.hasPrefix("stress"):
            // "stress:<clips>[:<media items in the bin>]"
            let parts = s.split(separator: ":")
            let n = parts.count > 1 ? Int(parts[1]) ?? 500 : 500
            let m = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            store.load(project: try await StressProject.make(clips: n, media: m))
        default:
            let url = URL(fileURLWithPath: project, relativeTo: config.script.deletingLastPathComponent())
            // open a temp copy: the session lock / saves never touch the checked-in fixture
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("montage-uitest-\(UUID().uuidString)")
                .appendingPathComponent(url.lastPathComponent)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            try? FileManager.default.removeItem(at: copy.appendingPathComponent(".session.lock"))
            try store.open(copy)
        }
        store.autosaveEnabled = false
        try await idle(settle: (script["settle"] as? NSNumber)?.doubleValue ?? 1.5)
    }

    // MARK: Steps

    static let actions = ["click", "press", "doubleClick", "rightClick", "drag", "scroll", "hover", "key", "type", "menu", "drop", "dragExit", "wait",
                          "idle", "snapshot", "dump", "expect", "waitFor", "seek", "select", "perf", "metric", "log", "a11yAudit"]

    static func describe(_ step: [String: Any]) -> String {
        guard let a = actions.first(where: { step[$0] != nil }) else { return "?" }
        let v = step[a]
        let s = (v as? String) ?? (v.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "")
        return "\(a) \(s)"
    }

    private func perform(_ step: [String: Any], index: Int) async throws {
        let mods = SyntheticEvents.modifiers((step["modifiers"] as? [String]) ?? [])
        let settle = (step["settle"] as? NSNumber)?.doubleValue ?? 0.25
        if let name = step["perf"] as? String { return try await perf(name, step) }  // may carry "drag"/"scroll" targets
        for key in ["click", "doubleClick", "rightClick", "drag", "hover"] {
            if let t = step[key] as? String, t.hasPrefix("id:"), scrollIntoView(t) { try await idle(settle: 0.2) }
        }
        if let t = step["click"] ?? step["doubleClick"] ?? step["rightClick"] {
            let p = try resolve(t, step)
            let right = step["rightClick"] != nil
            let count = step["doubleClick"] != nil ? 2 : ((step["count"] as? Int) ?? 1)
            // timeline context menu item: `{"rightClick": "clip:main/0", "menuItem": "tlmenu.separateAudio/tlmenu.splitScenes"}`
            let itemPath = right ? step["menuItem"] as? String : nil
            var captured: NSMenu?
            if itemPath != nil { TimelineView.uitestMenuSink = { captured = $0 } }
            defer { if itemPath != nil { TimelineView.uitestMenuSink = nil } }
            SyntheticEvents.click(at: p, in: window, modifiers: mods, count: count, right: right)
            try await idle(settle: settle)
            if let itemPath {
                guard let m = captured else { throw Failure("no context menu at \(t)") }
                try performMenu(itemPath, in: m)
                try await idle(settle: max(settle, 0.4))
            }
        } else if let t = step["drag"] {
            let a = try resolve(t, step)
            let b: CGPoint
            if let to = step["to"] {
                var s2 = step; s2["at"] = step["toAt"]; s2["offset"] = step["toOffset"]
                b = try resolve(to, s2)
            }
            else if let by = step["by"] as? [NSNumber], by.count == 2 { b = CGPoint(x: a.x + by[0].doubleValue, y: a.y - by[1].doubleValue) }
            else { throw Failure("drag needs \"to\" or \"by\"") }
            let steps = (step["steps"] as? Int) ?? 12
            let host = window.contentView
            let startView = host.flatMap { $0.hitTest($0.superview?.convert(a, from: nil) ?? a) }
            if !(startView.map(UITestWindow.isSwiftUIView) ?? false) {
                // AppKit views (incl. tracking loops like NSSlider/NSTextField) get the whole gesture queued at once
                SyntheticEvents.drag(from: a, to: b, in: window, steps: steps, modifiers: mods)
            } else {
                // one event per frame, like a real drag (SwiftUI gestures need the run loop between events)
                SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDown, at: a, in: window, modifiers: mods))
                _ = await SyntheticEvents.drain()
                try await Task.sleep(for: .milliseconds(30))
                for i in 1...max(1, steps) {
                    let t = CGFloat(i) / CGFloat(max(1, steps))
                    SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                                               in: window, modifiers: mods))
                    _ = await SyntheticEvents.drain()
                    try await Task.sleep(for: .milliseconds(16))
                }
                SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseUp, at: b, in: window, modifiers: mods))
            }
            try await idle(settle: settle)
        } else if let t = step["press"] as? String {
            let id = t.hasPrefix("id:") ? String(t.dropFirst(3)) : t
            guard let el = axElement(id) as? NSAccessibilityProtocol else { throw Failure("no accessibility element \(id)") }
            guard el.accessibilityPerformPress() else { throw Failure("\(id) has no press action") }
            try await idle(settle: settle)
        } else if let t = step["hover"] {
            SyntheticEvents.move(to: try resolve(t, step), in: window)
            try await idle(settle: settle)
        } else if let t = step["scroll"] {
            let p = try resolve(t, step)
            let dx = (step["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (step["dy"] as? NSNumber)?.doubleValue ?? 0
            for _ in 0..<((step["repeat"] as? Int) ?? 1) { try deliverScroll(at: p, dx: dx, dy: dy, modifiers: mods) }
            try await idle(settle: settle)
        } else if let k = step["key"] as? String {
            guard let spec = SyntheticEvents.parseKey(k) else { throw Failure("unknown key \(k)") }
            for _ in 0..<((step["repeat"] as? Int) ?? 1) { SyntheticEvents.key(spec, in: window) }
            try await idle(settle: settle)
        } else if let text = step["type"] as? String {
            if (step["replace"] as? Bool) == true { (window.firstResponder as? NSText)?.selectAll(nil) }
            SyntheticEvents.type(text, in: window)
            try await idle(settle: settle)
        } else if let path = step["menu"] as? String {
            try performMenu(path)
            try await idle(settle: max(settle, 0.4))
        } else if let payload = step["drop"] {
            try await drop(payload, on: try resolve(step["on"] ?? "id:timeline", step), hold: (step["hold"] as? Bool) == true)
            try await idle(settle: max(settle, 0.4))
        } else if step["dragExit"] != nil {
            // the held drag (`"hold": true`) leaves the destination: cancels it
            guard let v = heldDropView else { throw Failure("dragExit without a held drop") }
            v.draggingExited(nil)
            heldDropView = nil
            try await idle(settle: settle)
        } else if let w = step["wait"] as? NSNumber {
            try await Task.sleep(for: .seconds(w.doubleValue))
        } else if step["idle"] != nil {
            try await idle(settle: (step["idle"] as? NSNumber)?.doubleValue ?? settle)
        } else if let name = step["snapshot"] as? String {
            try snapshot(name, step)
        } else if let name = step["dump"] as? String {
            StateDump.write(StateDump.make(store), to: out.appendingPathComponent("\(name).json"))
        } else if let e = step["expect"] {
            let state = StateDump.make(store)
            let specs = (e as? [[String: Any]]) ?? [(e as? [String: Any]) ?? [:]]
            let errors = specs.compactMap { JSONPath.check(state, $0) }
            if !errors.isEmpty { throw Failure(errors.joined(separator: "\n      ")) }
        } else if let e = step["waitFor"] as? [String: Any] {
            let deadline = Date().addingTimeInterval((e["timeout"] as? NSNumber)?.doubleValue ?? 10)
            var spec = e; spec["timeout"] = nil
            while let err = JSONPath.check(StateDump.make(store, includeProject: false), spec) {
                if Date() > deadline { throw Failure("timed out: \(err)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        } else if let t = step["seek"] as? NSNumber {
            store.seek(to: Time(t.doubleValue))
            try await idle(settle: settle)
        } else if let sel = step["select"] {
            let targets = (sel as? [Any]) ?? [sel]
            store.selection = Set(try targets.map { try clip(from: $0).id })
            try await idle(settle: settle)
        } else if let name = step["perf"] as? String {
            try await perf(name, step)
        } else if let m = step["metric"] as? String {
            if m == "open_project" { try await measureOpenProject() } else { try recordMetric(m) }
        } else if let s = step["log"] as? String {
            log("      \(s)")
        } else if let name = step["a11yAudit"] as? String {
            // SE-017: VoiceOver audit of what is on screen; fails when more than `max` (default 0) elements have no name
            AccessibilityAudit.enableTree()
            try await idle(settle: 0.5)
            // the real AX API (what VoiceOver uses) from a background thread while the main thread serves it
            let ax = AccessibilityAuditAX.run()   // in-process AX requests are served on the calling (main) thread
            var d: [String: Any]
            if ax.error == nil, ax.checked > 0 {
                d = ["checked": ax.checked, "unlabeled": ax.unlabeled, "roles": ax.roles, "source": "AXUIElement"]
            } else {
                d = AccessibilityAudit.dump(window); d["source"] = "in-process"; d["axError"] = ax.error ?? "empty"
            }
            StateDump.write(d, to: out.appendingPathComponent("\(name).a11y.json"))
            let bad = (d["unlabeled"] as? [String]) ?? []
            log("      a11y \(name): \(d["checked"] ?? 0) elements checked, \(bad.count) unlabeled")
            if bad.count > ((step["max"] as? Int) ?? 0) { throw Failure("unlabeled accessibility elements: \(bad.prefix(30).joined(separator: ", "))") }
        } else {
            throw Failure("unknown step (actions: \(Self.actions.joined(separator: ", ")))")
        }
    }

    /// Waits until every posted event was dispatched, no gesture is open, then `settle` seconds for async UI work.
    func idle(settle: Double) async throws {
        guard await SyntheticEvents.drain() else { throw Failure("event queue did not drain (modal loop?)") }
        try await Task.sleep(for: .seconds(settle))
        _ = await SyntheticEvents.drain()
    }

    // MARK: Targets

    /// Resolves a target to a window point (AppKit window coordinates, bottom-left origin).
    ///
    /// - `"id:<testID>"` (SwiftUI `.testID` / AppKit accessibilityIdentifier), centre or `"at": [fx, fy]` (0…1, top-left)
    /// - `"clip:<track>/<index>[:leading|:trailing|:body|:<0…1>]"` — track = model index or `main`
    /// - `"time:<seconds>[@<track>|@ruler]"` — a time on the timeline (default: ruler)
    /// - `"player:<fx>,<fy>"` — a point in the preview (0…1, top-left)
    /// - `"point:<x>,<y>"` — window content coordinates (points, top-left)
    /// Optional `"offset": [dx, dy]` (points, +y down) is added.
    /// In-process accessibility element with this identifier (SwiftUI exposes `.testID` views as AX elements).
    func axElement(_ id: String) -> NSAccessibilityElementProtocol? {
        var seen = 0
        func walk(_ e: Any, depth: Int) -> NSAccessibilityElementProtocol? {
            seen += 1
            guard seen < 20000, depth < 60, let el = e as? NSAccessibilityElementProtocol & NSObjectProtocol else { return nil }
            if let ax = el as? NSAccessibilityProtocol, ax.accessibilityIdentifier() == id { return el }
            let kids = (el as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            if UITestWindow.debug, depth < 6 { log("      [ax] \(String(repeating: " ", count: depth))\(type(of: el)) id=\((el as? NSAccessibilityProtocol)?.accessibilityIdentifier() ?? "") kids=\(kids.count)") }
            for k in kids { if let f = walk(k, depth: depth + 1) { return f } }
            return nil
        }
        return window.contentView.flatMap { walk($0, depth: 0) }
    }

    /// Scrolls the enclosing scroll view so a `.testID` element is fully visible (like a user would before clicking).
    /// Returns true if it scrolled.
    func scrollIntoView(_ target: Any) -> Bool {
        guard let s = target as? String, let host = window.contentView else { return false }
        let id = s.hasPrefix("id:") ? String(s.dropFirst(3)) : s
        guard let r0 = TestAnchors.shared.frame(id) else { return false }
        let r = host.convert(r0, to: nil)  // window coords
        var scrolled = false
        func walk(_ v: NSView) {
            for sub in v.subviews { walk(sub) }
            guard !scrolled, let sv = v as? NSScrollView, let doc = sv.documentView else { return }
            let visible = sv.contentView.convert(sv.contentView.bounds, to: nil)
            let docRect = doc.convert(doc.bounds, to: nil)
            guard docRect.contains(CGPoint(x: r.midX, y: r.midY)), !visible.contains(r) else { return }
            // window coords are bottom-left: positive dy = element is above the visible area
            var dy: CGFloat = 0
            if r.minY < visible.minY { dy = r.minY - visible.minY - 8 } else if r.maxY > visible.maxY { dy = r.maxY - visible.maxY + 8 }
            var dx: CGFloat = 0
            if r.minX < visible.minX { dx = r.minX - visible.minX - 8 } else if r.maxX > visible.maxX { dx = r.maxX - visible.maxX + 8 }
            let clip = sv.contentView
            var o = clip.bounds.origin
            o.x += dx
            o.y += clip.isFlipped ? -dy : dy
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
            sv.reflectScrolledClipView(clip)
            scrolled = true
        }
        walk(host)
        return scrolled
    }

    func resolve(_ target: Any, _ step: [String: Any]) throws -> CGPoint {
        var p = try resolveBase(target, step)
        if let off = step["offset"] as? [NSNumber], off.count == 2 { p.x += off[0].doubleValue; p.y -= off[1].doubleValue }
        return p
    }

    private func resolveBase(_ target: Any, _ step: [String: Any]) throws -> CGPoint {
        guard let s = target as? String else { throw Failure("target must be a string, got \(target)") }
        let (kind, rest) = s.firstIndex(of: ":").map { (String(s[..<$0]), String(s[s.index(after: $0)...])) } ?? (s, "")
        let at = (step["at"] as? [NSNumber]).map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) } ?? CGPoint(x: 0.5, y: 0.5)
        switch kind {
        case "id":
            if let r = TestAnchors.shared.frame(rest), let host = window.contentView {
                return host.convert(CGPoint(x: r.minX + r.width * at.x, y: r.minY + r.height * at.y), to: nil)
            }
            if let v = findView(rest) { return point(in: v, unit: at) }
            throw Failure("no element with id \"\(rest)\" (visible: \(TestAnchors.shared.ids.joined(separator: ", ")))")
        case "clip":
            let parts = rest.split(separator: ":").map(String.init)
            let c = try clip(from: "clip:" + (parts.first ?? ""))
            guard let tl = timelineView else { throw Failure("no timeline view") }
            let l = tl.layoutNow
            guard let loc = store.project.timeline.locate(c.id), let row = l.rows.first(where: { $0.trackIndex == loc.track }) else {
                throw Failure("clip row not visible")
            }
            let r = l.clipRect(c, row: row)
            let region = parts.count > 1 ? parts[1] : "body"
            let x: CGFloat
            switch region {
            case "leading": x = r.minX + 2
            case "trailing": x = r.maxX - 2
            case "body": x = r.width > 40 ? r.minX + r.width * 0.5 : r.midX
            default:
                guard let f = Double(region) else { throw Failure("bad clip region \(region)") }
                x = r.minX + r.width * f
            }
            if UITestWindow.debug { log("      [clip] \(rest) rect \(r) row \(row.trackIndex) x \(x) bounds \(tl.bounds)") }
            if x < TimelineLayout.headerWidth || x > tl.bounds.width { throw Failure("clip \(rest) is scrolled out of view (x=\(Int(x)))") }
            return tl.convert(CGPoint(x: x, y: r.midY), to: nil)
        case "time":
            guard let tl = timelineView else { throw Failure("no timeline view") }
            let parts = rest.split(separator: "@").map(String.init)
            guard let secs = Double(parts[0]) else { throw Failure("bad time \(rest)") }
            let l = tl.layoutNow
            var y = TimelineLayout.rulerHeight / 2
            if parts.count > 1, parts[1] != "ruler" {
                let ti = parts[1] == "main" ? store.project.timeline.mainTrackIndex : Int(parts[1])
                guard let ti, let row = l.rows.first(where: { $0.trackIndex == ti }) else { throw Failure("no row for track \(parts[1])") }
                y = row.y + row.height / 2
            }
            return tl.convert(CGPoint(x: l.x(Time(secs)), y: y), to: nil)
        case "header":
            // header:<track>/<item>: a track-header control (type, lock, eye, mute, more; cover on the main track)
            guard let tl = timelineView else { throw Failure("no timeline view") }
            let parts = rest.split(separator: "/").map(String.init)
            guard parts.count == 2 else { throw Failure("expected header:<track>/<item>, got \(rest)") }
            let ti = parts[0] == "main" ? store.project.timeline.mainTrackIndex : Int(parts[0])
            let l = tl.layoutNow
            guard let ti, let row = l.rows.first(where: { $0.trackIndex == ti }) else { throw Failure("no row for track \(parts[0])") }
            let r: CGRect
            if parts[1] == "cover" {
                guard row.isMain else { throw Failure("only the main track has a Cover button") }
                r = tl.coverButtonRect(row)
            } else {
                guard let item = tl.headerItems(store.project.timeline.tracks[ti], row: row).first(where: { $0.id == parts[1] }) else {
                    throw Failure("no header item \(parts[1])")
                }
                r = item.rect
            }
            return tl.convert(CGPoint(x: r.minX + r.width * at.x, y: r.minY + r.height * at.y), to: nil)
        case "player":
            guard let pv = SnapshotRegistry.shared.player else { throw Failure("no player view") }

            let f = rest.split(separator: ",").compactMap { Double($0) }
            return point(in: pv, unit: f.count == 2 ? CGPoint(x: f[0], y: f[1]) : at)
        case "point":
            let f = rest.split(separator: ",").compactMap { Double($0) }
            guard f.count == 2, let host = window.contentView else { throw Failure("bad point \(rest)") }
            return CGPoint(x: f[0], y: host.bounds.height - f[1])
        default:
            if TestAnchors.shared.frame(s) != nil || findView(s) != nil { return try resolveBase("id:" + s, step) }
            throw Failure("unknown target \(s)")
        }
    }

    /// `clip:<track>/<index>` or `clip:selected`.
    func clip(from target: Any) throws -> Clip {
        guard let s = target as? String, s.hasPrefix("clip:") else { throw Failure("expected clip:<track>/<index>, got \(target)") }
        let body = String(s.dropFirst(5)).split(separator: ":").first.map(String.init) ?? ""
        let tl = store.project.timeline
        if body == "selected" {
            guard let c = store.selectedClips.first else { throw Failure("no selected clip") }
            return c
        }
        let parts = body.split(separator: "/").map(String.init)
        guard parts.count == 2, let ci = Int(parts[1]) else { throw Failure("bad clip target \(s)") }
        guard let ti = parts[0] == "main" ? tl.mainTrackIndex : Int(parts[0]), tl.tracks.indices.contains(ti) else {
            throw Failure("no track \(parts[0]) (tracks: \(tl.tracks.count))")
        }
        let clips = tl.tracks[ti].clips
        let j = ci < 0 ? clips.count + ci : ci
        guard clips.indices.contains(j) else { throw Failure("track \(parts[0]) has \(clips.count) clips, no index \(ci)") }
        return clips[j]
    }

    var timelineView: TimelineView? { SnapshotRegistry.shared.timeline.flatMap { $0.window === window ? $0 : nil } }

    private func point(in v: NSView, unit: CGPoint) -> CGPoint {
        let b = v.bounds
        let y = v.isFlipped ? b.minY + b.height * unit.y : b.maxY - b.height * unit.y
        return v.convert(CGPoint(x: b.minX + b.width * unit.x, y: y), to: nil)
    }

    func findView(_ id: String) -> NSView? {
        func walk(_ v: NSView) -> NSView? {
            if v.accessibilityIdentifier() == id { return v }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return window.contentView.flatMap(walk)
    }

    // MARK: Scroll, menu, drop

    private func deliverScroll(at p: CGPoint, dx: Double, dy: Double, modifiers: NSEvent.ModifierFlags) throws {
        guard let e = SyntheticEvents.scroll(at: p, in: window, dx: dx, dy: dy, modifiers: modifiers) else { throw Failure("cannot make scroll event") }
        if e.window === window {
            SyntheticEvents.post(e)
        } else if let host = window.contentView, let v = host.hitTest(host.superview?.convert(p, from: nil) ?? p) {
            v.scrollWheel(with: e)
        } else {
            throw Failure("nothing to scroll at \(p)")
        }
    }

    /// `"menu.edit/menu.undo"`: menu path by localization key (or literal title) from the menu bar.
    private func performMenu(_ path: String, in root: NSMenu? = nil) throws {
        var menu = root ?? NSApp.mainMenu
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            guard let m = menu else { throw Failure("menu \(path): no menu at \(part)") }
            guard let idx = m.items.firstIndex(where: { $0.title == tr(part) || $0.title == part || $0.submenu?.title == tr(part) }) else {
                throw Failure("menu \(path): no item \(part) (have: \(m.items.map(\.title).joined(separator: ", ")))")
            }
            if i == parts.count - 1 {
                m.update()
                guard m.items[idx].isEnabled || m.items[idx].action == nil else { throw Failure("menu item \(part) is disabled") }
                m.performActionForItem(at: idx)
            } else {
                menu = m.items[idx].submenu
            }
        }
    }

    /// Simulated drag & drop: `{"media": 0 | "name"}`, `{"mediaList": [0, 1]}`, `{"effect": id}`, `{"transition": id}`,
    /// `{"sticker": id}`, `{"text": styleID}`, `{"string": "<raw payload>"}` or `{"files": [paths]}` dropped at a point.
    /// `"hold": true` stops after draggingEntered/Updated (the drag hovers there: state dump `ui.dropPreview`); a later
    /// `drop` completes it elsewhere, `{"dragExit": true}` cancels it.
    private func drop(_ payload: Any, on p: CGPoint, hold: Bool = false) async throws {
        guard let d = payload as? [String: Any] else { throw Failure("drop payload must be an object") }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.montage.uitest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        if let m = d["media"] {
            let media = store.project.media
            let asset = (m as? Int).flatMap { media.indices.contains($0) ? media[$0] : nil } ?? media.first { $0.name == m as? String }
            guard let asset else { throw Failure("no media \(m) in the bin (\(media.count) items)") }
            pb.setString(DragPayload.media(asset.id), forType: .string)
        } else if let e = d["effect"] as? String { pb.setString(DragPayload.effect(e), forType: .string) }
        else if let e = d["transition"] as? String { pb.setString(DragPayload.transition(e), forType: .string) }
        else if let e = d["sticker"] as? String { pb.setString(DragPayload.sticker(e), forType: .string) }
        else if let e = d["text"] as? String { pb.setString(DragPayload.textStyle(e), forType: .string) }
        else if let list = d["mediaList"] as? [Int] {   // W13: several bin items (multi-selection drag)
            let media = store.project.media
            pb.setString(DragPayload.mediaList(list.compactMap { media.indices.contains($0) ? media[$0].id : nil }), forType: .string)
        }
        else if let raw = d["string"] as? String { pb.setString(raw, forType: .string) }   // any payload, e.g. montage-stock:<id>
        else if let files = d["files"] as? [String] {
            pb.writeObjects(files.map { URL(fileURLWithPath: $0, relativeTo: config.script.deletingLastPathComponent()).absoluteURL as NSURL })
        } else { throw Failure("unknown drop payload \(d)") }

        guard let host = window.contentView, var v = host.hitTest(host.superview?.convert(p, from: nil) ?? p) else { throw Failure("no view at drop point") }
        while v.registeredDraggedTypes.isEmpty, let s = v.superview { v = s }
        guard !v.registeredDraggedTypes.isEmpty else { throw Failure("no drop destination at point") }
        let info = SyntheticDraggingInfo(window: window, location: p, pasteboard: pb)
        let op = v.draggingEntered(info)
        _ = v.draggingUpdated(info)
        guard !op.isEmpty else { throw Failure("destination refused the drag") }
        if hold { heldDropView = v; return }
        heldDropView = nil
        guard v.prepareForDragOperation(info), v.performDragOperation(info) else { throw Failure("drop was not accepted") }
        v.concludeDragOperation(info)
    }

    // MARK: Snapshots

    /// `{"snapshot": "name", "element": "id:timeline", "baseline": true, "tolerance": 0.01, "threshold": 24, "scale": 0.5}`
    private func snapshot(_ name: String, _ step: [String: Any]) throws {
        guard var img = SnapshotRegistry.shared.snapshot(window: window), let host = window.contentView else { throw Failure("snapshot failed") }
        let k = CGFloat(img.width) / host.bounds.width
        var cropOrigin = CGPoint.zero
        if let el = step["element"] as? String {
            let rect: CGRect
            let id = el.hasPrefix("id:") ? String(el.dropFirst(3)) : el
            if let r = TestAnchors.shared.frame(id) { rect = r }
            else if let v = findView(id) {
                let r = v.convert(v.bounds, to: host)
                rect = host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
            } else { throw Failure("no element \(el) to snapshot") }
            let px = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
            guard let c = img.cropping(to: px) else { throw Failure("crop failed") }
            img = c
            cropOrigin = CGPoint(x: px.minX, y: px.minY)
        }
        if let masks = step["mask"] as? [String], !masks.isEmpty {
            // Volatile regions (disk sizes, dates, clocks…): painted flat grey in the snapshot AND in the baseline.
            guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure("mask failed") }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            for m in masks {
                let id = m.hasPrefix("id:") ? String(m.dropFirst(3)) : m
                guard let r = TestAnchors.shared.frame(id) else { throw Failure("no element \(m) to mask") }
                // window points, top-left → pixels of the (cropped) image, bottom-left origin
                let x = r.minX * k - cropOrigin.x, yTop = r.minY * k - cropOrigin.y
                ctx.fill(CGRect(x: x, y: CGFloat(img.height) - yTop - r.height * k, width: r.width * k, height: r.height * k).integral)
            }
            if let m = ctx.makeImage() { img = m }
        }
        let baseline = step["baseline"].map { ($0 as? String) ?? name }
        let scale = (step["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? (baseline != nil ? 1 / k : 1)
        if abs(scale - 1) > 0.001, let s = Self.resize(img, scale) { img = s }
        let url = out.appendingPathComponent("\(name).png")
        ImageDiff.writePNG(img, to: url)
        guard let baseline else { return }
        guard let dir = config.baselines else { warnings.append("no --baselines dir; \(name) not compared"); return }
        let base = dir.appendingPathComponent("\(baseline).png")
        if config.updateBaselines || !FileManager.default.fileExists(atPath: base.path) {
            ImageDiff.writePNG(img, to: base)
            warnings.append("baseline \(config.updateBaselines ? "updated" : "created"): \(base.path) — LOOK at it and commit it")
            return
        }
        let diff = ImageDiff(threshold: (step["threshold"] as? Int) ?? 16, tolerance: (step["tolerance"] as? NSNumber)?.doubleValue ?? 0.005)
        guard let r = diff.compare(url, base, diffURL: out.appendingPathComponent("\(name).diff.png")) else { throw Failure("cannot read \(base.path)") }
        metrics["snapshot_\(name)_diff_fraction"] = r.fraction
        if !r.passed {
            throw Failure(r.sizeMismatch ? "size \(img.width)x\(img.height) differs from baseline \(base.lastPathComponent)"
                          : String(format: "%.2f%% pixels differ from baseline (tolerance %.2f%%), diff: %@", r.fraction * 100,
                                   diff.tolerance * 100, out.appendingPathComponent("\(name).diff.png").path))
        }
    }

    static func resize(_ img: CGImage, _ k: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Perf

    /// `{"perf": "timeline_scroll", "frames": 300, "on": "id:timeline", "dx": -24, "dy": 0, "modifiers": ["cmd"],
    ///   "alternate": true}` — delivers one scroll event per frame through the real `scrollWheel` path, then measures the
    /// timeline frame (CPU build + GPU encode). Metrics: `<name>_cpu_p50_ms`, `_cpu_p95_ms`, `_cpu_max_ms`, `_gpu_p95_ms`.
    private func perf(_ name: String, _ step: [String: Any]) async throws {
        if step["drag"] != nil || step["scroll"] != nil || step["edit"] != nil { return try await perfInteraction(name, step) }
        if name.hasPrefix("asset") || step["view"] as? Bool == true { try await viewScrollPerf(name, step); return }
        guard let tl = timelineView else { throw Failure("no timeline view") }
        let p = try resolve(step["on"] ?? "id:timeline", step)
        let frames = (step["frames"] as? Int) ?? 240
        let dx = (step["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (step["dy"] as? NSNumber)?.doubleValue ?? 0
        let mods = SyntheticEvents.modifiers((step["modifiers"] as? [String]) ?? [])
        let alternate = (step["alternate"] as? Bool) ?? false
        let period = max(1, (step["period"] as? Int) ?? 60)
        var cpu: [Double] = [], gpu: [Double] = [], wall: [Double] = []
        _ = probe.measure(tl)  // warm-up
        for i in 0..<frames {
            let sign: Double = alternate && (i / period) % 2 == 1 ? -1 : 1
            if dx != 0 || dy != 0, let e = SyntheticEvents.scroll(at: p, in: window, dx: dx * sign, dy: dy * sign, modifiers: mods) {
                tl.scrollWheel(with: e)
            }
            let (c, g, w) = probe.measure(tl)
            cpu.append(c); gpu.append(g); wall.append(w)
            if i % 30 == 29 { await Task.yield() }
        }
        let c = Percentiles(cpu), g = Percentiles(gpu), w = Percentiles(wall)
        metrics["\(name)_cpu_p50_ms"] = c.p50
        metrics["\(name)_cpu_p95_ms"] = c.p95
        metrics["\(name)_cpu_max_ms"] = c.max
        metrics["\(name)_gpu_p95_ms"] = g.p95
        metrics["\(name)_wall_p50_ms"] = w.p50
        metrics["\(name)_wall_p95_ms"] = w.p95
        log(String(format: "      %@: cpu p50 %.2f ms, p95 %.2f ms, max %.2f ms; wall p95 %.2f ms; gpu p95 %.2f ms (%d frames)", name, c.p50, c.p95, c.max, w.p95, g.p95, frames))
        try await idle(settle: 0.1)
    }

    /// Interaction perf (any view, SwiftUI included): `{"perf": "inspector_drag", "drag": "id:slider.opacity", "at": [0.1, 0.5],
    /// "toAt": [0.9, 0.5], "frames": 90}` (drag back and forth, one event per frame) or `{"perf": "assets_scroll", "scroll":
    /// "id:panel.assets", "dy": -30, "frames": 120, "alternate": true, "period": 30}`. Per event: main-thread CPU time
    /// from posting it through one 16 ms frame (event handling + SwiftUI/observation updates + view draws it triggers)
    /// and dispatch wall time. Also counts preview frames composed meanwhile (live preview).
    /// Metrics: `<name>_main_cpu_p50_ms`, `_main_cpu_p95_ms`, `_dispatch_p95_ms`, `_preview_frames`, `_compose_p95_ms`.
    private func perfInteraction(_ name: String, _ step: [String: Any]) async throws {
        let frames = (step["frames"] as? Int) ?? 90
        let mods = SyntheticEvents.modifiers((step["modifiers"] as? [String]) ?? [])
        var cpu: [Double] = [], dispatch: [Double] = []
        CompositorStats.shared.reset()
        let freeze = (step["anchors"] as? String ?? "frozen") == "frozen"
        func measure(_ send: () throws -> Void) async throws {
            let c0 = ThreadCPU.nanoseconds(), w0 = DispatchTime.now().uptimeNanoseconds
            try send()
            _ = await SyntheticEvents.drain()
            let w1 = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(for: .milliseconds(16))
            cpu.append(Double(ThreadCPU.nanoseconds() - c0) / 1e6)
            dispatch.append(Double(w1 - w0) / 1e6)
        }
        func pauseAnchors() async throws {
            guard freeze else { return }
            TestAnchors.live.tracking = false
            try await idle(settle: 0.15)
        }
        defer { TestAnchors.live.tracking = true }
        if let t = step["drag"] {
            if let id = t as? String, id.hasPrefix("id:"), scrollIntoView(id) { try await idle(settle: 0.2) }
            let a = try resolve(t, step)
            var s2 = step; s2["at"] = step["toAt"]; s2["offset"] = step["toOffset"]
            let b = try resolve(step["to"] ?? t, s2)
            try await pauseAnchors()
            SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDown, at: a, in: window, modifiers: mods))
            _ = await SyntheticEvents.drain()
            try await Task.sleep(for: .milliseconds(30))
            let half = max(1, frames / 4)
            for i in 0..<frames {
                // triangle wave a → b → a … so every event changes the value
                let ph = Double(i % (2 * half)) / Double(half)
                let f = CGFloat(ph <= 1 ? ph : 2 - ph)
                let pt = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                try await measure { SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDragged, at: pt, in: window, modifiers: mods)) }
            }
            SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseUp, at: a, in: window, modifiers: mods))
        } else if let target = step["edit"] {
            // programmatic gesture edits (no input event): what one live-edit tick costs the UI
            let id = try clip(from: target).id
            try await pauseAnchors()
            store.beginGesture("cmd.editClip")
            for i in 0..<frames {
                let v = 0.5 + 0.4 * Double(i % 2)
                try await measure { store.updateGesture { p in p.timeline[clip: id]?.opacity = v } }
            }
            store.endGesture()
        } else if let t = step["scroll"] {
            let p = try resolve(t, step)
            let dx = (step["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (step["dy"] as? NSNumber)?.doubleValue ?? 0
            let alternate = (step["alternate"] as? Bool) ?? false
            let period = max(1, (step["period"] as? Int) ?? 60)
            try await pauseAnchors()
            for i in 0..<frames {
                let sign: Double = alternate && (i / period) % 2 == 1 ? -1 : 1
                try await measure { try deliverScroll(at: p, dx: dx * sign, dy: dy * sign, modifiers: mods) }
            }
        }
        TestAnchors.live.tracking = true
        try await idle(settle: 0.3)
        let st = CompositorStats.shared.snapshot()
        let c = Percentiles(cpu), d = Percentiles(dispatch), k = Percentiles(st.costsMs)
        if ProcessInfo.processInfo.environment["MONTAGE_PERF_RAW"] == "1" {
            print("      raw cpu: " + cpu.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        metrics["\(name)_main_cpu_p50_ms"] = c.p50
        metrics["\(name)_main_cpu_p95_ms"] = c.p95
        metrics["\(name)_dispatch_p95_ms"] = d.p95
        metrics["\(name)_preview_frames"] = Double(st.frames)
        metrics["\(name)_compose_p95_ms"] = k.p95
        log(String(format: "      %@: main cpu p50 %.2f ms, p95 %.2f ms, max %.2f; dispatch p95 %.2f ms; preview %d frames, compose p95 %.2f ms (%d events)",
                   name, c.p50, c.p95, c.max, d.p95, st.frames, k.p95, frames))
    }

    /// `{"perf": "asset_scroll", "on": "id:media.grid", "frames": 300, "dy": -40, "alternate": true, "period": 60}` —
    /// scrolls a SwiftUI/AppKit scroll view (asset panel grids) one wheel event per frame and measures the main-thread
    /// time to deliver the event and bring the window up to date (layout + display, i.e. lazy cell creation and
    /// thumbnail binding). Metrics: `<name>_p50_ms`, `_p95_ms`, `_max_ms`, `<name>_distance_pt` (scrolled distance).
    private func viewScrollPerf(_ name: String, _ step: [String: Any]) async throws {
        let p = try resolve(step["on"] ?? "id:asset.grid", step)
        guard let host = window.contentView, let hit = host.hitTest(host.superview?.convert(p, from: nil) ?? p) else {
            throw Failure("no view at \(step["on"] ?? "")")
        }
        var v: NSView? = hit
        while let x = v, !(x is NSScrollView) { v = x.superview }
        let sv = (v as? NSScrollView) ?? hit.enclosingScrollView
        guard let sv else { throw Failure("no scroll view under \(step["on"] ?? "")") }
        let frames = (step["frames"] as? Int) ?? 240
        let dy = (step["dy"] as? NSNumber)?.doubleValue ?? -40
        let alternate = (step["alternate"] as? Bool) ?? false
        let period = max(1, (step["period"] as? Int) ?? 60)
        var times: [Double] = []
        var distance = 0.0
        var last = sv.contentView.bounds.origin.y
        for i in 0..<frames {
            let sign: Double = alternate && (i / period) % 2 == 1 ? -1 : 1
            guard let e = SyntheticEvents.scroll(at: p, in: window, dx: 0, dy: dy * sign) else { continue }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let before = sv.contentView.bounds.origin.y
            sv.scrollWheel(with: e)
            if sv.contentView.bounds.origin.y == before, let doc = sv.documentView {
                // SwiftUI's hosting scroll view ignores phase-less synthetic wheel events: move the viewport the same
                // distance directly (the same clip-view bounds change a real wheel scroll makes).
                let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                sv.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, before - dy * sign), maxY)))
                sv.reflectScrolledClipView(sv.contentView)
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            let y = sv.contentView.bounds.origin.y
            distance += abs(y - last); last = y
            if i % 10 == 9 { await Task.yield() }
        }
        let c = Percentiles(times)
        metrics["\(name)_p50_ms"] = c.p50
        metrics["\(name)_p95_ms"] = c.p95
        metrics["\(name)_max_ms"] = c.max
        metrics["\(name)_distance_pt"] = distance
        log(String(format: "      %@: p50 %.2f ms, p95 %.2f ms, max %.2f ms, scrolled %.0f pt (%d frames)", name, c.p50, c.p95, c.max, distance, frames))
        try await idle(settle: 0.1)
    }

    /// `{"metric": "memory"}` → `memory_mb`, `memory_peak_mb` (physical footprint).
    private func recordMetric(_ m: String) throws {
        switch m {
        case "memory":
            let f = ProcessMemory.footprint()
            metrics["memory_mb"] = Double(f.current) / 1_048_576
            metrics["memory_peak_mb"] = Double(f.peak) / 1_048_576
            log(String(format: "      memory %.0f MB (peak %.0f MB)", Double(f.current) / 1_048_576, Double(f.peak) / 1_048_576))
        case "launch":
            metrics["launch_ms"] = launchMs
            log(String(format: "      launch to editor drawn: %.0f ms", launchMs))
        default: throw Failure("unknown metric \(m)")
        }
    }

    /// `{"metric": "open_project"}`: saves the current project to a temp package and times `store.open` through the
    /// first laid-out + drawn window and timeline frame → `open_project_ms` (wall), `open_project_cpu_ms` (main thread).
    private func measureOpenProject() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-perf-open-\(UUID().uuidString).montage")
        try ProjectPackage.save(store.project, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let c0 = ThreadCPU.nanoseconds(), w0 = DispatchTime.now().uptimeNanoseconds
        try store.open(url)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let tl = timelineView { _ = probe.measure(tl) }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e6, cpu = Double(ThreadCPU.nanoseconds() - c0) / 1e6
        metrics["open_project_ms"] = wall
        metrics["open_project_cpu_ms"] = cpu
        log(String(format: "      open project (%d clips, %d media): %.0f ms (main cpu %.0f ms)",
                   store.project.timeline.tracks.reduce(0) { $0 + $1.clips.count }, store.project.media.count, wall, cpu))
        store.autosaveEnabled = false
        try await idle(settle: 0.5)
    }
}

/// `"project": "stress:500"` — many short clips on several tracks (perf harness).
public enum StressProject {
    /// `"project": "media:1000"` — a bin of `n` items (the demo media repeated with distinct ids, names and cache keys,
    /// so every card loads its own thumbnail), empty timeline (asset-panel scroll perf).
    public static func makeBin(items n: Int) async throws -> Project {
        var p = try await DemoProject.make()
        let base = p.media
        guard !base.isEmpty else { return p }
        p.media = (0..<n).map { i in
            var a = base[i % base.count]
            a.id = MediaID()
            a.name = String(format: "%@ %04d", a.name, i + 1)
            a.contentHash = "\(a.contentHash)-bin\(i)"
            return a
        }
        p.timeline = Timeline()
        p.name = "media-\(n)"
        return p
    }

    /// `media` > 0 pads the bin to that many items (copies of the demo media with their own ids / names / cache keys,
    /// so thumbnails are generated per item like a real big bin).
    public static func make(clips n: Int, media: Int = 0) async throws -> Project {
        var p = try await DemoProject.make()
        let videos = p.media.filter { $0.kind == .video }
        let audio = p.media.filter { $0.kind == .audio }
        guard !videos.isEmpty else { return p }
        let nMain = n * 6 / 10, nOverlay = n * 2 / 10, nAudio = n - nMain - nOverlay
        func clip(_ a: MediaAsset, _ start: Double, _ d: Double) -> Clip {
            var c = TimelineOps.makeClip(for: a, at: Time(start))
            c.duration = Time(min(d, a.duration.seconds))
            return c
        }
        var main = Track(kind: .video, isMain: true)
        main.clips = (0..<nMain).map { clip(videos[$0 % videos.count], Double($0), 1) }
        var overlay = Track(kind: .video)
        overlay.clips = (0..<nOverlay).map { clip(videos[($0 + 1) % videos.count], Double($0) * 3, 2) }
        var music = Track(kind: .audio)
        if let a = audio.first ?? videos.first { music.clips = (0..<nAudio).map { clip(a, Double($0) * 3, 2.5) } }
        var tl = Timeline()
        tl.tracks = [main, overlay, music]
        p.timeline = tl
        p.name = "stress-\(n)"
        let base = p.media
        var k = 0
        while p.media.count < media, !base.isEmpty {
            var a = base[k % base.count]
            a.id = MediaID(); a.name = "\(k + 1) \(a.name)"; a.contentHash += "-s\(k)"
            p.media.append(a); k += 1
        }
        return p
    }
}
