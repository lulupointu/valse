import AppKit
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI

/// UI test process only (FLAKY-UI3): the app's accessibility window list never comes back empty while the test window
/// is up. AppKit leaves windows that are off the active Space out of AXWindows; the `a11yAudit` step then saw no
/// window and fell back to the in-process walk, which misses SwiftUI's Menu names ("unlabeled AXMenuButton" ×4).
/// `MONTAGE_UITEST_INJECT_AX_NO_WINDOWS=1` (driver self-test) drops AppKit's own list so this fallback is exercised.
final class UITestApplication: NSApplication {
    @MainActor static func install() {
        guard let app = NSApp, type(of: app) == NSApplication.self else { return }
        object_setClass(app, UITestApplication.self)
    }
    /// Times AppKit's own list was empty and the visible windows were listed instead (a11y.json `windowListFallbacks`).
    @MainActor static var fallbacks = 0
    override func accessibilityWindows() -> [Any]? {
        var list = UITestDriver.injectAXNoWindows ? [] : (super.accessibilityWindows() ?? [])
        if list.isEmpty {
            list = windows.filter { $0.isVisible && !($0 is NSPanel) }
            MainActor.assumeIsolated { Self.fallbacks += 1 }
        }
        return list
    }
}

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
    /// Unhandled synthetic keys would NSBeep through the user's speakers: tests stay silent.
    public override func noResponder(for eventSelector: Selector) {}
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
        // the driver queues the whole gesture (… up) before the down is dispatched; still, don't give up on the first
        // poll: a slider drag under load came back with no events and the slider never moved (u1_playhead_follow)
        var until = Date(timeIntervalSinceNow: 2)
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: until, inMode: .eventTracking, dequeue: true) {
            until = .distantPast
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
            slider.mouseDown(with: SyntheticEvents.pinned(d))   // handed over directly, not dequeued: pin it here
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
    /// The `id:` target of the click being delivered, and what its press / release found when dispatched (`ClickProbe`).
    static var clickProbe: ClickProbe?

    public override func sendEvent(_ received: NSEvent) {
        // every synthetic mouse event at the location it was posted at (also when dispatched without the main loop's
        // nextEvent, or re-located after it: FLAKY-SYS-UI)
        let original = SyntheticEvents.pinned(received)
        let event: NSEvent
        if let probe = Self.clickProbe, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(original.type) {
            guard let e = probe.filter(original, in: self) else { return }   // the element is gone: the click is not delivered
            event = e
        } else {
            event = original
        }
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
    /// Mouse still down after a `"hold": true` drag (released by `{"release": true}`), with its modifiers.
    private var heldMouse: (CGPoint, NSEvent.ModifierFlags)?
    /// Destination of a `"hold": true` drop (hovering, not dropped yet).
    private var heldDropView: NSView?
    private let probe = TimelineFrameProbe()
    private var launchMs: Double = 0
    /// The previous step was an input step with `"settle": 0`: the next `expect` checks at once (no retry).
    private var previousSettleZero = false
    /// Time the current `expect` waited for its condition (report.json `waitMs`).
    private var lastExpectWaitMs: Int?

    /// Creates the offscreen test window (call before building the content view; enables `.testID` geometry tracking).
    public static func makeWindow(size: CGSize) -> NSWindow {
        TestAnchors.isEnabled = true
        SyntheticEvents.installPressedButtonsHook()
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.offscreenOrigin, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        w.setFrameOrigin(UITestWindow.offscreenOrigin)
        // FLAKY-UI3: on every Space, so a Space switch on the shared machine during a run never takes the window off the
        // active Space (AppKit then leaves it out of the app's AXWindows: the a11yAudit fell back to the in-process walk)
        w.collectionBehavior.insert(.canJoinAllSpaces)
        UITestApplication.install()
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
        // (the language preference a script sets lives in this process's private AppDefaults domain; restored anyway
        // for runs where AppDefaults is not isolated)
        let savedLanguagePref = AppDefaults.store.object(forKey: L10n.overrideDefaultsKey)
        defer {
            if let savedLanguagePref { AppDefaults.store.set(savedLanguagePref, forKey: L10n.overrideDefaultsKey) }
            else { AppDefaults.store.removeObject(forKey: L10n.overrideDefaultsKey) }
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
        Self.heartbeatURL = out.appendingPathComponent(".heartbeat")
        Self.heartbeat(force: true)

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
        let stalls0 = Exporter.stallRestarts
        do {
            try await setUp(script)
            let steps = (script["steps"] as? [Any]) ?? []
            for (i, raw) in steps.enumerated() {
                guard let step = raw as? [String: Any] else { throw Failure("step \(i + 1) is not an object") }
                let s0 = Date()
                Self.heartbeat(force: true)
                let label = Self.describe(step)
                if let why = Self.osConditionUnmet(step) {
                    report.append(["index": i + 1, "step": label, "ok": true, "skipped": why])
                    log("  ⏭ \(i + 1). \(label) (\(why))")
                    continue
                }
                do {
                    lastExpectWaitMs = nil
                    try await perform(step, index: i + 1)
                    previousSettleZero = (step["settle"] as? NSNumber)?.doubleValue == 0
                    var entry: [String: Any] = ["index": i + 1, "step": label, "ok": true, "ms": Int(Date().timeIntervalSince(s0) * 1000)]
                    if let w = lastExpectWaitMs { entry["waitMs"] = w }
                    report.append(entry)
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
        // An export pass that stalled (Exporter restarts it once in the app) is a failure in a test run, never hidden.
        let stalls = Exporter.stallRestarts - stalls0
        metrics["export_stall_restarts"] = Double(stalls)
        if failed == nil, stalls > 0 { failed = "\(stalls) export pass(es) stalled and were restarted (Exporter.stallRestarts)" }
        // synthetic mouse events that reached the app elsewhere than posted and were put back (SyntheticEvents.pinned)
        if SyntheticEvents.relocationCount > 0 {
            metrics["mouse_event_relocated"] = Double(SyntheticEvents.relocationCount)
            for r in SyntheticEvents.relocations { warnings.append("synthetic mouse \(r); delivered where posted") }
        }
        // How long `expect`s had to wait for their condition (a latency regression shows here; uitest.sh warns)
        let waits = report.compactMap { $0["waitMs"] as? Int }
        metrics["expect_wait_ms_max"] = Double(waits.max() ?? 0)
        if let w = waits.max(), w > 2000, (metrics["quiesce_timeouts"] ?? 0) == 0 {
            warnings.append("an expect waited \(w) ms for its condition (UI settled: a slow reaction, not load?)")
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
        // `"requires": {"minOS": 14}`: the feature under test needs that macOS major version (e.g. a 14+ Vision API)
        if let min = ((script["requires"] as? [String: Any])?["minOS"] as? NSNumber)?.intValue, osMajor < min {
            return "requires macOS \(min)+ (running \(osMajor))"
        }
        // `"requires": {"content": true}`: the bundled music/SFX library audio (scripts/fetch_music_pack.sh cache)
        if (script["requires"] as? [String: Any])?["content"] as? Bool == true, ContentLibrary.availableMusic.isEmpty {
            return "requires the music/SFX library (run scripts/fetch_music_pack.sh)"
        }
        let required = ((script["requires"] as? [String: Any])?["models"] as? [String]) ?? []
        defer { ModelManager.shared.refresh() }
        // OB-07: UI tests never download: simulated downloads (`"modelDownloads": "hold"` stops at 40 %)
        ModelManager.shared.simulation = ModelManager.Simulation(rawValue: script["modelDownloads"] as? String ?? "") ?? .complete
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

    /// Machine settings that change pixels but not behaviour, pinned for the test process only (before NSApplication
    /// exists) so snapshots compare across machines: overlay scroll bars (a Mac with a mouse, or a VM, shows legacy
    /// 15 pt scrollers that narrow every scroll view) and the time zone the baselines were recorded in (dates in Home /
    /// the project switcher come from a fixed UTC clock).
    public nonisolated static func prepareProcess() {
        let d = UserDefaults.standard
        var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
        args["AppleShowScrollBars"] = "WhenScrolling"
        // no animated (smooth) wheel scrolling: a scroll step lands at once, so the next click never hits content that
        // is still gliding under it (wall-clock animation; ai_remove missed its checkbox under load)
        args["NSScrollAnimationEnabled"] = false
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        let tz = ProcessInfo.processInfo.environment["MONTAGE_UITEST_TZ"] ?? "Europe/Paris"
        if let z = TimeZone(identifier: tz) { NSTimeZone.default = z }
    }

    /// Major version of the running macOS (`MONTAGE_UITEST_OS_MAJOR` overrides it, to check OS-conditional scripts).
    static var osMajor: Int {
        if let v = ProcessInfo.processInfo.environment["MONTAGE_UITEST_OS_MAJOR"].flatMap(Int.init) { return v }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// Per-step environment condition: `"minOS": 14` runs the step only on macOS 14+, `"maxOS": 13` only up to macOS
    /// 13 — expected differences of older systems (a feature that needs a newer API); `"ffmpeg": true|false` only when
    /// the FFmpeg sidecar (MP3 export, exotic formats) is / isn't installed. Returns why the step is skipped.
    static func osConditionUnmet(_ step: [String: Any]) -> String? {
        if let v = (step["minOS"] as? NSNumber)?.intValue, osMajor < v { return "macOS \(v)+ only" }
        if let v = (step["maxOS"] as? NSNumber)?.intValue, osMajor > v { return "macOS ≤ \(v) only" }
        if let v = step["ffmpeg"] as? Bool, v != FFmpegSidecar.isAvailable { return v ? "needs FFmpeg" : "without FFmpeg only" }
        return nil
    }

    /// Baseline for a snapshot: `Baselines/macos<N>/<name>.png` when running on macOS N and that file exists (rendering
    /// differences of an older system: fonts, controls), else `Baselines/<name>.png`.
    func baselineURL(_ dir: URL, _ name: String) -> URL {
        let os = dir.appendingPathComponent("macos\(Self.osMajor)", isDirectory: true).appendingPathComponent("\(name).png")
        return FileManager.default.fileExists(atPath: os.path) ? os : dir.appendingPathComponent("\(name).png")
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
            await loadBarrier()
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
        case let s where s.hasPrefix("demo-transcript"):   // C4: demo + captions from known words (TranscriptDemo)
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
        await loadBarrier()
    }

    /// FLAKY-SYS-UI: the first step runs only once the editor that shows the loaded project is usable — the timeline
    /// laid out with finite geometry and rows for its tracks, the player sized (FLAKY-UI2 caught the timeline geometry
    /// non-finite right after a load: the first `clip:main/0` click selected nothing) — instead of a wall-clock settle
    /// that a loaded machine can outlast. A hang bound (`targetLimit`), not a speed budget: reported, then the script goes on.
    private func loadBarrier() async {
        let deadline = Date().addingTimeInterval(Self.targetLimit)
        var why = editorNotReady()
        while why != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            _ = await SyntheticEvents.drain(timeout: 1)
            why = editorNotReady()
        }
        if let why {
            metrics["load_barrier_timeouts", default: 0] += 1
            warnings.append("the editor was not ready \(Int(Self.targetLimit)) s after the project load: \(why)")
        } else {
            await quiesce()
        }
    }

    /// Why the editor showing the project is not usable yet (nil = ready, or no editor on screen: Home, a modal start).
    private func editorNotReady() -> String? {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let tl = timelineView, !tl.isHiddenOrHasHiddenAncestor else { return nil }
        guard tl.bounds.width > 0, tl.bounds.height > 0 else { return "timeline bounds \(tl.bounds)" }
        let l = tl.layoutNow
        let origin = tl.convert(CGPoint(x: l.x(.zero), y: TimelineLayout.rulerHeight / 2), to: nil)
        guard origin.x.isFinite, origin.y.isFinite else { return "timeline geometry not finite (\(origin))" }
        let tracks = store.project.timeline.tracks
        if tracks.contains(where: { !$0.clips.isEmpty }), l.rows.isEmpty { return "no timeline rows for \(tracks.count) track(s)" }
        if let pv = SnapshotRegistry.shared.player, pv.window === window, !pv.isHiddenOrHasHiddenAncestor,
           pv.bounds.width < 1 || pv.bounds.height < 1 {
            return "player bounds \(pv.bounds)"
        }
        return nil
    }

    // MARK: Steps

    static let actions = ["click", "press", "doubleClick", "rightClick", "contextMenu", "drag", "scroll", "hover", "key", "type", "menu", "drop", "dragExit", "release", "wait",
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
        for key in ["click", "doubleClick", "rightClick", "contextMenu", "drag", "hover"] {
            guard let t = step[key] else { continue }
            // a previous waitFor / expect may have returned while the layout its state change causes is still pending:
            // resolving the target from stale test-ID frames would click where the element WAS (ai_movement: a
            // finishing job's progress line collapsed and the click hit the chip below "Shake")
            await quiesce()
            // like a user: wait for the target to be on screen (an overloaded main thread lays it out late)
            await waitForTarget(t, step)
            if let t = t as? String, t.hasPrefix("id:"), scrollIntoView(t) { try await idle(settle: 0.2) }
        }
        if let t = step["click"] ?? step["doubleClick"] ?? step["rightClick"] {
            let p = try resolve(t, step)
            let right = step["rightClick"] != nil
            let count = step["doubleClick"] != nil ? 2 : ((step["count"] as? Int) ?? 1)
            // timeline context menu item: `{"rightClick": "clip:main/0", "menuItem": "tlmenu.separateAudio/tlmenu.splitScenes"}`
            // FB-06 dropdown: `{"click": "id:…", "menuItem": "<title or key>"}` (the menu the real click builds)
            let itemPath = step["menuItem"] as? String
            var captured: NSMenu?
            if itemPath != nil { TimelineView.uitestMenuSink = { captured = $0 }; DropdownMenu.uitestMenuSink = { captured = $0 } }
            defer { if itemPath != nil { TimelineView.uitestMenuSink = nil; DropdownMenu.uitestMenuSink = nil } }
            // Exact delivery (`id:` targets, ClickProbe): when the press is dispatched, the window is laid out and drawn
            // and the element located again. If it moved since it was resolved (layout in flux: either reading may be
            // the transient one, FLAKY-UI3), nothing is dispatched and it is clicked again once the UI settled; only the
            // last attempt goes to where it is THEN (`click_retargets` in report.json). If it is not on screen at that
            // moment, nothing is dispatched (provably
            // not delivered): wait for it and click again (`click_redeliveries`, ≤ 3 attempts). A dispatched press is
            // never repeated; an element rebuilt between press and release is reported (`click_release_anomalies`).
            // An `offset` click (beside the element) is located the same way: element + offset at dispatch.
            // Timeline targets (`clip:` / `time:` / `header:`) too (FLAKY-UI2: ai_auto_adjust / ai_relight_model's first
            // `clip:main/0` click selected nothing under load; with this probe the timeline geometry at dispatch was
            // caught non-finite once): located again from the timeline layout at dispatch, and the press must land on
            // the timeline view
            let timelineTarget = (t as? String).map { $0.hasPrefix("clip:") || $0.hasPrefix("time:") || $0.hasPrefix("header:") } ?? false
            // FLAKY-SYS-UI: `offset` clicks too (FLAKY-UI2's ai_relight untick was an offset click that missed after the
            // layout moved): the probe locates element + offset again at dispatch, like any other exact click
            // `player:` points too: located again from the player view at dispatch (a player resized under the click)
            let targetID = (t as? String).flatMap {
                $0.hasPrefix("id:") ? String($0.dropFirst(3)) : (timelineTarget || $0.hasPrefix("player:") ? $0 : nil)
            }
            let onView: NSView? = timelineTarget ? timelineView : nil
            var point = p
            for attempt in 1...3 {
                // fault injection (driver self-test): a stale resolved point / an element missing at dispatch
                let skew = targetID != nil ? Self.injectClickSkew : nil
                let vanish = attempt == 1 && Self.injectClickVanish
                let aim = skew.map { CGPoint(x: point.x + $0.dx, y: point.y - $0.dy) } ?? point
                let probe = targetID.map { id in
                    ClickProbe(id: id, expected: count, lastAttempt: attempt == 3, onView: onView, aim: aim, window: window) { [self] in
                        vanish ? nil : try? resolve(t, step)
                    }
                }
                UITestWindow.clickProbe = probe
                SyntheticEvents.click(at: aim, in: window, modifiers: mods, count: count, right: right)
                try await idle(settle: settle)
                UITestWindow.clickProbe = nil
                guard let probe else { break }
                for r in probe.relocated {
                    metrics["click_event_relocated", default: 0] += 1
                    warnings.append("click \(t): \(r); delivered at the element")
                }
                for r in probe.foreign {
                    metrics["click_foreign_events", default: 0] += 1
                    warnings.append("click \(t): a mouse event it did not post reached the window: \(r); dropped")
                }
                if let r = probe.retarget {
                    // not a failure: the press went where the element is at dispatch (report.json `click_retargets`)
                    metrics["click_retargets", default: 0] += 1
                    warnings.append("click \(t): the element \(r); pressed at its position at dispatch")
                }
                guard let why = probe.notDelivered() else {
                    if let a = probe.releaseAnomaly() { warnings.append("click \(t): \(a) (not repeated)"); metrics["click_release_anomalies", default: 0] += 1 }
                    break
                }
                metrics["click_redeliveries", default: 0] += 1
                warnings.append("click \(t) (attempt \(attempt)) was not delivered: \(why)")
                if attempt == 3 { throw Failure("click \(t) was not delivered 3 times: \(why)") }
                await quiesce()
                await waitForTarget(t, step)
                point = try resolve(t, step)
            }
            if let itemPath {
                guard let m = captured else { throw Failure("no context menu at \(t)") }
                try performMenu(itemPath, in: m)
                try await idle(settle: max(settle, 0.4))
            }
        } else if let t = step["contextMenu"] {
            // a view's context menu (SwiftUI `.contextMenu`, AppKit `menu` / `menu(for:)`), driven without popping it up
            // (a real popup runs a modal tracking loop): `{"contextMenu": "id:asset.preset.0", "item": "adjust.preset.delete"}`
            guard let item = step["item"] as? String else {
                throw Failure("contextMenu needs \"item\": an l10n key, title or item identifier (\"a/b\" for a submenu)")
            }
            let menu = try contextMenu(at: try resolve(t, step), target: t, modifiers: mods)
            try performMenu(item, in: menu)
            try await idle(settle: max(settle, 0.4))
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
            let hold = (step["hold"] as? Bool) == true
            if hold {
                // press + moves, mouse stays down (snapshot / dump mid-drag); `{"release": true}` ends it
                SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDown, at: a, in: window, modifiers: mods))
                _ = await SyntheticEvents.drain()
                for i in 1...max(1, steps) {
                    let t = CGFloat(i) / CGFloat(max(1, steps))
                    SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                                               in: window, modifiers: mods))
                    _ = await SyntheticEvents.drain()
                }
                heldMouse = (b, mods)
            } else if !(startView.map(UITestWindow.isSwiftUIView) ?? false) {
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
            // "phase": "began" | "changed" | "ended" = trackpad gesture events (U1: rubber-band checks)
            let phase: Int64? = (step["phase"] as? String).flatMap { ["began": 1, "changed": 2, "ended": 4][$0] }
            for _ in 0..<((step["repeat"] as? Int) ?? 1) { try deliverScroll(at: p, dx: dx, dy: dy, modifiers: mods, phase: phase) }
            try await idle(settle: settle)
        } else if let k = step["key"] as? String {
            guard let spec = SyntheticEvents.parseKey(k) else { throw Failure("unknown key \(k)") }
            for _ in 0..<((step["repeat"] as? Int) ?? 1) { SyntheticEvents.key(spec, in: window) }
            try await idle(settle: settle)
        } else if let text = step["type"] as? String {
            // typing goes to the focused text field: wait for the field editor to take focus (a click on a field
            // focuses it a few main-loop turns later on a loaded machine; the keys were lost: home_project_flow)
            let focusDeadline = Date().addingTimeInterval(3)
            while !(window.firstResponder is NSText), Date() < focusDeadline {
                try await Task.sleep(for: .milliseconds(20))
                _ = await SyntheticEvents.drain(timeout: 1)
            }
            if (step["replace"] as? Bool) == true { (window.firstResponder as? NSText)?.selectAll(nil) }
            SyntheticEvents.type(text, in: window)
            try await idle(settle: settle)
        } else if let path = step["menu"] as? String {
            try performMenu(path)
            try await idle(settle: max(settle, 0.4))
        } else if let payload = step["drop"] {
            try await drop(payload, on: try resolve(step["on"] ?? "id:timeline", step), hold: (step["hold"] as? Bool) == true)
            try await idle(settle: max(settle, 0.4))
        } else if step["release"] != nil {
            guard let (p, m) = heldMouse else { throw Failure("release without a held drag") }
            SyntheticEvents.post(SyntheticEvents.mouse(.leftMouseUp, at: p, in: window, modifiers: m))
            heldMouse = nil
            try await idle(settle: settle)
        } else if step["dragExit"] != nil {
            // the held drag (`"hold": true`) leaves the destination: cancels it
            guard let v = heldDropView else { throw Failure("dragExit without a held drop") }
            v.draggingExited(nil)
            heldDropView = nil
            try await idle(settle: settle)
        } else if let w = step["wait"] as? NSNumber {
            try await Task.sleep(for: .seconds(w.doubleValue))
            // and the input queued before / during it is dispatched (a loaded main loop may not have run it yet when the
            // time is up). No quiesce: a `wait` is for time-based behaviour (playback, tooltip delays) that keeps moving.
            _ = await SyntheticEvents.drain(timeout: 2)
        } else if step["idle"] != nil {
            try await idle(settle: (step["idle"] as? NSNumber)?.doubleValue ?? settle)
        } else if let name = step["snapshot"] as? String {
            try await snapshot(name, step)
        } else if let name = step["dump"] as? String {
            StateDump.write(StateDump.make(store), to: out.appendingPathComponent("\(name).json"))
        } else if let e = step["expect"] {
            // Eventually consistent (re-checked for up to `expectLimit` s): the state an input step causes can land a few
            // main-loop turns late on a loaded machine. A condition that never holds still fails, with its last errors.
            // `"now": true` (and any expect right after a `"settle": 0` step): checked once, immediately — for asserts
            // whose point is immediacy ("hidden at once", state during a gesture).
            let specs = (e as? [[String: Any]]) ?? [(e as? [String: Any]) ?? [:]]
            let now = (step["now"] as? Bool) ?? previousSettleZero
            let t0 = Date()
            let deadline = t0.addingTimeInterval(now ? 0 : Self.expectLimit)
            while true {
                let state = StateDump.make(store)
                let errors = specs.compactMap { JSONPath.check(state, $0) }
                if errors.isEmpty { break }
                if Date() >= deadline { throw Failure(errors.joined(separator: "\n      ") + (now ? " (checked at once: \"now\")" : "")) }
                Self.heartbeat()
                try await Task.sleep(for: .milliseconds(50))
            }
            lastExpectWaitMs = Int(Date().timeIntervalSince(t0) * 1000)
        } else if let e = step["waitFor"] as? [String: Any] {
            try await waitFor(e)
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
            // `"element": "id:x"` audits only that element's subtree (P1: the project switcher popover)
            let scope = (step["element"] as? String).map { $0.hasPrefix("id:") ? String($0.dropFirst(3)) : $0 }
            // FLAKY-UI3: "AXWindows empty" (the window was off the active Space) → the in-process fallback, which misses
            // SwiftUI's Menu names: the test window is on all Spaces and `UITestApplication` never lists no window
            var ax = AccessibilityAuditAX.run(scope: scope)   // in-process AX requests are served on the calling (main) thread
            // Under load the AX read can come back empty (→ the in-process fallback, which misses SwiftUI's names) or
            // before SwiftUI filled lazy names (Menu buttons). Re-read until clean, ≤ 2 × `expectLimit` (a hang bound,
            // load-independent); a really unlabeled element stays unlabeled and still fails after that.
            let allowed = (step["max"] as? Int) ?? 0
            let auditDeadline = Date().addingTimeInterval(2 * Self.expectLimit)
            while ax.error != nil || ax.checked == 0 || ax.unlabeled.count > allowed, Date() < auditDeadline {
                try await idle(settle: 0.5)
                ax = AccessibilityAuditAX.run(scope: scope)
            }
            var d: [String: Any]
            if ax.error == nil, ax.checked > 0 {
                d = ["checked": ax.checked, "unlabeled": ax.unlabeled, "roles": ax.roles, "source": "AXUIElement"]
            } else {
                d = AccessibilityAudit.dump(window, scope: scope); d["source"] = "in-process"; d["axError"] = ax.error ?? "empty"
                // why the real AX read failed (FLAKY-UI3): the test window's Space / visibility as AppKit sees them
                d["windows"] = NSApp.windows.map { w in
                    ["visible": w.isVisible, "activeSpace": w.isOnActiveSpace, "occlusion": w.occlusionState.rawValue,
                     "class": String(describing: type(of: w))] as [String: Any]
                }
            }
            if UITestApplication.fallbacks > 0 { d["windowListFallbacks"] = UITestApplication.fallbacks }
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
        if settle > 0 { await quiesce() }   // `"settle": 0` = check the state right after dispatch (tooltip delay)
    }

    // MARK: Load-independent waiting
    //
    // A wall-clock settle is not enough on an oversubscribed machine (several gates at once): the main thread may not
    // have run the work an input queued (SwiftUI updates, main-actor tasks, layout) by the time it elapses. The waits
    // below are waits for an observable condition; their limits only end a wait that never ends (hang detectors, never
    // speed budgets), so a run where the condition already holds takes no longer than before.

    /// Bound of re-checking an `expect` that does not hold yet.
    static let expectLimit = envSeconds("MONTAGE_UITEST_EXPECT_LIMIT", 10)
    /// Minimum `waitFor` timeout, whatever the script says.
    static let waitForFloor = envSeconds("MONTAGE_UITEST_WAIT_FLOOR", 30)
    /// Bound of waiting for a mouse target (`id:` element, clip row) to be on screen.
    static let targetLimit = envSeconds("MONTAGE_UITEST_TARGET_LIMIT", 10)
    /// Bound of waiting for a snapshot to render the same pixels twice / to match its baseline.
    static let snapshotLimit = envSeconds("MONTAGE_UITEST_SNAPSHOT_LIMIT", 30)   // a hang bound, like waitFor's floor
    /// Bound of `quiesce` (continuous change, e.g. playback, never quiesces: the step then goes on as before).
    static let quiesceLimit = envSeconds("MONTAGE_UITEST_QUIESCE_LIMIT", 10)

    /// Driver self-test fault injection for `id:` clicks: `MONTAGE_UITEST_INJECT_CLICK_SKEW="dx,dy"` aims every press
    /// dx, dy pt (+y down) off the resolved point (= a stale resolved point: the element moved before dispatch);
    /// `MONTAGE_UITEST_INJECT_CLICK_VANISH=1` makes the element absent at the first attempt's dispatch. Scripts must
    /// pass either way, with each click delivered exactly once.
    static let injectClickSkew: CGVector? = {
        let p = (ProcessInfo.processInfo.environment["MONTAGE_UITEST_INJECT_CLICK_SKEW"] ?? "").split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? CGVector(dx: p[0], dy: p[1]) : nil
    }()
    static let injectClickVanish = ProcessInfo.processInfo.environment["MONTAGE_UITEST_INJECT_CLICK_VANISH"] == "1"
    /// Driver self-test for `a11yAudit` (FLAKY-UI3): `MONTAGE_UITEST_INJECT_AX_NO_WINDOWS=1` drops AppKit's own
    /// accessibility window list (as for a test window off the active Space); audits must still read the real AX tree.
    static let injectAXNoWindows = ProcessInfo.processInfo.environment["MONTAGE_UITEST_INJECT_AX_NO_WINDOWS"] == "1"

    /// Absolute bound of one `waitFor` whose progress signals keep changing (a sanity net, not a speed budget).
    static let waitCeiling = envSeconds("MONTAGE_UITEST_WAIT_CEILING", 1800)

    nonisolated static func envSeconds(_ key: String, _ d: Double) -> Double {
        ProcessInfo.processInfo.environment[key].flatMap(Double.init) ?? d
    }

    /// State that moves while long work (AI / background jobs, offline audio stages, exports, model downloads) advances.
    static let progressPaths = ["ui.jobs", "ui.activeJobs", "ui.audioStage", "ui.export.jobs", "ui.models.progress"]

    /// `{"waitFor": {"path": …, <operator>: …, "timeout": s, "progress": ["extra.path", …]}}`: waits until the condition
    /// holds. `timeout` (≥ `waitForFloor`) is a HANG bound counted from the last observed progress, never a total: any
    /// change of the progress signals (`progressPaths`, the waited path's own value, the script's `progress` paths)
    /// restarts it. A job that a loaded machine makes slow keeps moving and is waited for; a stuck one (no change for
    /// `timeout` s) fails. `waitCeiling` ends a wait whose signals never stop changing.
    func waitFor(_ e: [String: Any]) async throws {
        let bound = max((e["timeout"] as? NSNumber)?.doubleValue ?? 10, Self.waitForFloor)
        var spec = e; spec["timeout"] = nil; spec["progress"] = nil
        let extra = (e["progress"] as? [String]) ?? (e["progress"] as? String).map { [$0] } ?? []
        let paths = Self.progressPaths + [(e["path"] as? String) ?? ""].filter { !$0.isEmpty } + extra
        func signature(_ s: [String: Any]) -> String {
            paths.map { p -> String in
                guard let v = JSONPath.get(s, p) else { return "-" }
                if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) {
                    return String(decoding: d, as: UTF8.self)
                }
                return "\(v)"
            }.joined(separator: "|")
        }
        // the same state `expect` reads (the full project JSON only when a path needs it: it is the costly part)
        let needsProject = ([(e["path"] as? String) ?? ""] + extra).contains { $0 == "project" || $0.hasPrefix("project.") }
        let t0 = Date()
        var lastChange = t0, lastSig = "", progressed = 0
        while true {
            let state = StateDump.make(store, includeProject: needsProject)
            guard let err = JSONPath.check(state, spec) else { break }
            let now = Date(), sig = signature(state)
            if sig != lastSig {
                if !lastSig.isEmpty { progressed += 1 }
                lastSig = sig; lastChange = now
            }
            if now.timeIntervalSince(lastChange) > bound {
                throw Failure("timed out: no progress for \(Int(bound)) s (waited \(Int(now.timeIntervalSince(t0))) s, \(progressed) progress change(s)): \(err)")
            }
            if now.timeIntervalSince(t0) > Self.waitCeiling {
                throw Failure("timed out: still not true after \(Int(Self.waitCeiling)) s although progressing (MONTAGE_UITEST_WAIT_CEILING): \(err)")
            }
            Self.heartbeat()
            try await Task.sleep(for: .milliseconds(50))
        }
        let waited = Date().timeIntervalSince(t0)
        if waited > bound { log(String(format: "      waited %.0f s (> the %.0f s hang bound: progress kept it alive, %d change(s))", waited, bound, progressed)) }
    }

    // MARK: Heartbeat (scripts/uitest.sh hang detection)
    //
    // uitest.sh kills a UI-test app only when the driver stopped making progress (no heartbeat for `--timeout` s), not
    // after a total time: a slow script on a loaded machine keeps beating, a hung main thread / an await that never
    // returns does not. The driver beats when a step starts and while it polls a condition (every wait in it has its
    // own bound); the file is `<out>/.heartbeat` (mtime).
    private static var heartbeatURL: URL?
    private static var lastBeat = Date.distantPast
    static func heartbeat(force: Bool = false) {
        guard let u = heartbeatURL else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastBeat) >= 1 else { return }
        lastBeat = now
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
    }

    /// What pending main-thread UI work changes: the on-screen test-ID frames (SwiftUI layout caught up), the edit
    /// revision, selection, inspector / asset tab, toast, first responder, app screen / modal.
    private func uiFingerprint() -> String {
        window.contentView?.layoutSubtreeIfNeeded()   // apply pending layout now (it would run at the next pass anyway)
        // and render it: SwiftUI hit-tests clicks against what it last rendered, not against the layout — a click on
        // an element laid out but not yet drawn (a screen that just appeared, under load) found nothing to act on
        window.displayIfNeeded()
        var parts: [String] = []
        for id in TestAnchors.shared.ids {
            if let r = TestAnchors.shared.frame(id) {
                parts.append("\(id)=\(Int(r.minX * 2)),\(Int(r.minY * 2)),\(Int(r.width * 2)),\(Int(r.height * 2))")
            }
        }
        parts.append("rev=\(store.session.revision) sel=\(store.selection.map(\.description).sorted()) "
                     + "tab=\(store.inspectorTab ?? "-")/\(store.activeAssetTab) toast=\(store.toast?.message ?? "-")")
        parts.append("first=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
        // the AppKit timeline (clip: / time: / header: targets are resolved from its layout): zoom, scroll, size —
        // not while playing (follow scrolling moves it continuously; playback steps must not wait for it)
        if let tl = timelineView, !store.transport.isPlaying {
            parts.append("tl=\(store.pixelsPerSecond),\(tl.scrollTime),\(tl.scrollY),\(Int(tl.bounds.width)),\(Int(tl.bounds.height))")
        }
        if let app = StateDump.appHook?() { parts.append("app=\(app["screen"] ?? "-")/\(app["modal"] ?? "-")") }
        return parts.joined(separator: ";")
    }

    /// Waits until the UI fingerprint is unchanged over two consecutive main-loop round trips (≥ 2 × 20 ms).
    func quiesce() async {
        let deadline = Date().addingTimeInterval(Self.quiesceLimit)
        var last = uiFingerprint(), stable = 0
        while stable < 2, Date() < deadline {
            _ = await SyntheticEvents.drain(timeout: 1)   // one trip through the main event queue
            try? await Task.sleep(for: .milliseconds(20))
            let now = uiFingerprint()
            if now == last { stable += 1 } else { stable = 0; last = now }
        }
        // report.json: how often the UI never settled (continuous change; a high count = a step racing the UI)
        if stable < 2 { metrics["quiesce_timeouts", default: 0] += 1 }
    }

    /// Waits (≤ `targetLimit`) until a mouse target resolves: an `id:` element is on screen, a clip row is laid out.
    /// A target that still does not resolve is reported by the step itself, as before.
    func waitForTarget(_ target: Any, _ step: [String: Any]) async {
        let deadline = Date().addingTimeInterval(Self.targetLimit)
        while (try? resolve(target, step)) == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            _ = await SyntheticEvents.drain(timeout: 1)
        }
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
            return try settled(tl.convert(CGPoint(x: x, y: r.midY), to: nil), tl)
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
            return try settled(tl.convert(CGPoint(x: l.x(Time(secs)), y: y), to: nil), tl)
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
            return try settled(tl.convert(CGPoint(x: r.minX + r.width * at.x, y: r.minY + r.height * at.y), to: nil), tl)
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

    /// A timeline target's window point, or a failure while the timeline geometry is not usable (non-finite: seen once
    /// right after a project load under load, FLAKY-UI2), so `waitForTarget` / the click probe wait it out.
    private func settled(_ p: CGPoint, _ tl: TimelineView) throws -> CGPoint {
        guard p.x.isFinite, p.y.isFinite else {
            throw Failure("timeline geometry not settled (point \(p), bounds \(tl.bounds), frame \(tl.frame), in window \(tl.window != nil))")
        }
        return p
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

    private func deliverScroll(at p: CGPoint, dx: Double, dy: Double, modifiers: NSEvent.ModifierFlags, phase: Int64? = nil) throws {
        guard let e = SyntheticEvents.scroll(at: p, in: window, dx: dx, dy: dy, modifiers: modifiers, phase: phase) else { throw Failure("cannot make scroll event") }
        if e.window === window {
            SyntheticEvents.post(e)
        } else if let host = window.contentView, let v = host.hitTest(host.superview?.convert(p, from: nil) ?? p) {
            v.scrollWheel(with: SyntheticEvents.pinned(e))   // handed over directly: pinned here (not dequeued)
        } else {
            throw Failure("nothing to scroll at \(p)")
        }
    }

    /// `"menu.edit/menu.undo"`: menu path by localization key (or literal title) from the menu bar.
    /// The context menu a right-click at `p` (window coordinates) would open: the hit view's or the nearest ancestor's
    /// `menu(for:)` (SwiftUI's hosting view builds `.contextMenu` items there; AppKit views return their `menu`).
    private func contextMenu(at p: CGPoint, target: Any, modifiers: NSEvent.ModifierFlags) throws -> NSMenu {
        guard let host = window.contentView,
              let event = SyntheticEvents.mouse(.rightMouseDown, at: p, in: window, modifiers: modifiers).map(SyntheticEvents.pinned) else {
            throw Failure("contextMenu \(target): no content view / event")
        }
        var view = host.hitTest(host.superview?.convert(p, from: nil) ?? p)
        while let v = view {
            if let m = v.menu(for: event), !m.items.isEmpty {
                m.update()
                return m
            }
            view = v.superview
        }
        throw Failure("contextMenu \(target): no context menu there")
    }

    private func performMenu(_ path: String, in root: NSMenu? = nil) throws {
        var menu = root ?? NSApp.mainMenu
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            guard let m = menu else { throw Failure("menu \(path): no menu at \(part)") }
            guard let idx = m.items.firstIndex(where: { $0.title == tr(part) || $0.title == part || $0.submenu?.title == tr(part)
                                                        || $0.identifier?.rawValue == part }) else {
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
            pb.writeObjects(files.map { URL(fileURLWithPath: $0, relativeTo: config.script.deletingLastPathComponent()).absoluteURL as NSURL })   // absolute: a relative NSURL loses its base on the pasteboard
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
    ///
    /// Load-independent: the window is rendered until two consecutive renders (a main-loop round trip apart) give the
    /// same pixels — no half-applied layout, late thumbnail or caret blink caught mid-way — and, with a baseline, until it
    /// matches (≤ `snapshotLimit` s; a real difference still fails, after that bound, with the last render's diff).
    private func snapshot(_ name: String, _ step: [String: Any]) async throws {
        let baseline = step["baseline"].map { ($0 as? String) ?? name }
        let url = out.appendingPathComponent("\(name).png")
        var base: (url: URL, pixels: ImageDiff.Pixels, diff: ImageDiff)?
        if let baseline, let dir = config.baselines {
            let b = baselineURL(dir, baseline)
            if !config.updateBaselines, FileManager.default.fileExists(atPath: b.path) {
                guard let px = ImageDiff.load(b).flatMap(ImageDiff.Pixels.init) else { throw Failure("cannot read \(b.path)") }
                var tolerance = (step["tolerance"] as? NSNumber)?.doubleValue ?? 0.005
                // a per-OS baseline (recorded in the 1x macOS 13 VM) sees run-to-run sub-pixel text jitter of ~0.7 %
                if b.deletingLastPathComponent().lastPathComponent.hasPrefix("macos") { tolerance = max(tolerance, 0.01) }
                base = (b, px, ImageDiff(threshold: (step["threshold"] as? Int) ?? 16, tolerance: tolerance))
            }
        }
        // without a baseline the PNG is only an artefact to look at: a short bound for content that keeps moving
        // (a playing preview's progress bar)
        let limit = base != nil || config.updateBaselines ? Self.snapshotLimit : min(Self.snapshotLimit, 2)
        let deadline = Date().addingTimeInterval(limit)
        var previous: ImageDiff.Pixels?
        var renders = 0
        while true {
            let img = try renderSnapshot(step, baseline: baseline != nil)
            renders += 1
            guard let px = ImageDiff.Pixels(img) else { throw Failure("snapshot pixels failed") }
            let stable = previous.map { $0.width == px.width && $0.height == px.height && $0.data == px.data } ?? false
            let timedOut = Date() > deadline
            if let base {
                let (r, d) = base.diff.compare(px, base.pixels)
                // matches the baseline AND the rendering has settled (two identical consecutive renders)
                if (r.passed && stable) || timedOut {
                    ImageDiff.writePNG(img, to: url)
                    metrics["snapshot_\(name)_diff_fraction"] = r.fraction
                    if renders > 2 { metrics["snapshot_\(name)_renders"] = Double(renders) }
                    if r.passed && stable { return }
                    if r.passed {   // timed out: matches, but never rendered the same twice — not a deterministic picture
                        throw Failure("snapshot \(name) matches its baseline but never rendered the same twice in \(Int(limit)) s (animated content?)")
                    }
                    if let di = d?.cgImage { ImageDiff.writePNG(di, to: out.appendingPathComponent("\(name).diff.png")) }
                    throw Failure(r.sizeMismatch ? "size \(img.width)x\(img.height) differs from baseline \(base.url.lastPathComponent)"
                                  : String(format: "%.2f%% pixels differ from baseline (tolerance %.2f%%; %d renders over %.0f s, last two %@), diff: %@",
                                           r.fraction * 100, base.diff.tolerance * 100, renders, Self.snapshotLimit,
                                           stable ? "identical" : "still changing", out.appendingPathComponent("\(name).diff.png").path))
                }
            } else if stable || timedOut {
                if !stable { warnings.append("snapshot \(name): rendering never settled in \(Int(limit)) s (animated content?)") }
                ImageDiff.writePNG(img, to: url)
                guard let baseline else { return }
                guard let dir = config.baselines else { warnings.append("no --baselines dir; \(name) not compared"); return }
                let b = baselineURL(dir, baseline)
                ImageDiff.writePNG(img, to: b)
                warnings.append("baseline \(config.updateBaselines ? "updated" : "created"): \(b.path) — LOOK at it and commit it")
                return
            }
            previous = px
            _ = await SyntheticEvents.drain(timeout: 1)
            try await Task.sleep(for: .milliseconds(renders < 3 ? 30 : 100))
        }
    }

    /// One render of a snapshot step: the window (offscreen renderer), cropped to `element`, `mask`s painted grey, scaled.
    private func renderSnapshot(_ step: [String: Any], baseline hasBaseline: Bool) throws -> CGImage {
        guard var img = SnapshotRegistry.shared.snapshot(window: window), let host = window.contentView else { throw Failure("snapshot failed") }
        let k = CGFloat(img.width) / host.bounds.width
        var cropOrigin = CGPoint.zero
        var cropTarget: (Int, Int)?
        if let el = step["element"] as? String {
            let rect: CGRect
            let id = el.hasPrefix("id:") ? String(el.dropFirst(3)) : el
            if let r = TestAnchors.shared.frame(id) { rect = r }
            else if let v = findView(id) {
                let r = v.convert(v.bounds, to: host)
                rect = host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
            } else { throw Failure("no element \(el) to snapshot") }
            var px = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
            if step["baseline"] != nil, abs(k - 2) > 0.01 {
                // Baselines are recorded on Retina (2 px/pt, then halved). On another backing scale (a 1x display / VM)
                // crop to the size that path would give, so fractional-point frames don't change the size by a pixel.
                let r2 = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2).integral
                let t = (Int(r2.width * 0.5), Int(r2.height * 0.5))
                cropTarget = t
                px = CGRect(x: (rect.minX * k).rounded(.down), y: (rect.minY * k).rounded(.down),
                            width: (CGFloat(t.0) * k).rounded(), height: (CGFloat(t.1) * k).rounded())
            }
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
                // a `.testID` frame, else an AppKit view's (e.g. the Metal `player` view)
                let viewRect = findView(id).map { v -> CGRect in
                    let r = v.convert(v.bounds, to: host)
                    return host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
                }
                guard let r = TestAnchors.shared.frame(id) ?? viewRect else { throw Failure("no element \(m) to mask") }
                // window points, top-left → pixels of the (cropped) image, bottom-left origin
                let x = r.minX * k - cropOrigin.x, yTop = r.minY * k - cropOrigin.y
                ctx.fill(CGRect(x: x, y: CGFloat(img.height) - yTop - r.height * k, width: r.width * k, height: r.height * k).integral)
            }
            if let m = ctx.makeImage() { img = m }
        }
        let scale = (step["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? (hasBaseline ? 1 / k : 1)
        if let t = cropTarget, step["scale"] == nil {
            if img.width != t.0 || img.height != t.1, let s = Self.resize(img, to: t) { img = s }
        } else if abs(scale - 1) > 0.001, let s = Self.resize(img, scale) { img = s }
        return img
    }

    static func resize(_ img: CGImage, _ k: CGFloat) -> CGImage? {
        resize(img, to: (Int(CGFloat(img.width) * k), Int(CGFloat(img.height) * k)))
    }

    static func resize(_ img: CGImage, to size: (Int, Int)) -> CGImage? {
        let w = max(1, size.0), h = max(1, size.1)
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
        // PERF-R1: measure at full clocks, not at the DVFS state of a quiet machine (see PerfClockWarmer)
        let warmer = PerfClockWarmer()
        warmer.start()
        defer { warmer.stop() }
        if PerfClockWarmer.enabled { try await Task.sleep(for: .milliseconds(50)) }   // let the cluster ramp up
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
                tl.scrollWheel(with: SyntheticEvents.pinned(e))
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
            sv.scrollWheel(with: SyntheticEvents.pinned(e))
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

/// Delivery of one synthetic `id:` click, decided when NSWindow dispatches its PRESS (not checked afterwards).
///
/// The point the driver resolved can be stale by the time the main loop dispatches the event: a layout pass ran in
/// between (an element moved / collapsed), or the layout moved without being drawn yet — SwiftUI hit-tests against what
/// it last rendered, so a frame check against TestAnchors after the fact could disagree with where the press really
/// landed (the old "verify, then re-send" check: false "landed outside" misses under load — ai_editpilot_fr
/// pilot.suggestion.3 / pilot.close, perf timeline_500 toolbar.zoomFit — and a re-send risked a second press on an
/// element that had acted). Now, at the press: the window is laid out AND drawn (then layout = what SwiftUI
/// hit-tests), the target is located again (`locate` = the driver's `resolve`) and the press, its release and a double
/// click's second pair are dispatched THERE. An element that is not on screen at that moment gets nothing (the events
/// are dropped): provably not delivered, so the driver may click again. A dispatched press is never repeated.
///
/// FLAKY-UI3: (1) "moved" used to compare the element with the EVENT's location, and a posted NSEvent sometimes
/// reaches `sendEvent` with another `locationInWindow` than it was created with (inspector_masks_speed: aimed 300,193,
/// press at -5556,-5640, same window / frame; ai_tts_style's −46 pt "move" of `inspector.tab.tts` and
/// f4_se_a11y_editor's 1343 pt one were the same thing). The old fix-up added the press's error to the release, which
/// arrived uncorrupted, so the release landed 46 pt beside the tab: no click, the tab stayed Text. Now the element is
/// compared with the point the driver AIMED at, and every event of the click is delivered at the element's located
/// point (relocations are reported: `click_event_relocated`). (2) A real move between resolution and dispatch means
/// the layout is in flux and either reading may be transient: the press is dropped (nothing delivered), the driver
/// waits for the UI to settle, resolves again and re-clicks; only the last attempt goes to the position at dispatch.
@MainActor
final class ClickProbe {
    let id: String
    let expected: Int
    /// The driver's last attempt: a moved element is pressed where it is at dispatch instead of being dropped.
    let lastAttempt: Bool
    /// The element's TestAnchors frame when the click was resolved (nil for timeline targets / AppKit views).
    private let resolvedFrame: CGRect?
    private let locate: () -> CGPoint?
    /// Where every event of the click is delivered (the element's position at the first press).
    private var target: CGPoint?
    /// Events that reached the window somewhere else than where they were posted (report.json warnings).
    private(set) var relocated: [String] = []
    private var dropped: String?
    private var owners: [UUID?] = []
    private var presses = 0, releases = 0
    /// How far the press was moved to the element's position at dispatch (nil = it was where the driver aimed).
    private(set) var retarget: String?

    /// AppKit view the press must hit (`clip:` targets: the timeline). Something else on top of that point at dispatch
    /// (an overlay, a view not laid out yet) = provably not delivered: dropped, clicked again once it is clear.
    private weak var onView: NSView?

    /// The aimed point and the window frame when the click was resolved (diagnostics of a moved target).
    private let aim: CGPoint?
    private let windowFrame: CGRect?

    init(id: String, expected: Int, lastAttempt: Bool = true, onView: NSView? = nil, aim: CGPoint? = nil, window: NSWindow? = nil,
         locate: @escaping () -> CGPoint?) {
        self.id = id; self.expected = expected; self.lastAttempt = lastAttempt; self.onView = onView; self.locate = locate
        self.aim = aim; windowFrame = window?.frame
        resolvedFrame = TestAnchors.shared.frame(id)
        firstEventNumber = SyntheticEvents.eventNumber + 1
    }

    /// The click's own presses carry event numbers firstEventNumber ..< firstEventNumber + expected (SyntheticEvents
    /// numbers each press; its release shares the number).
    private let firstEventNumber: Int
    /// Mouse button events that reached the window during this click but were not posted by it (dropped, reported).
    private(set) var foreign: [String] = []

    private static func describe(_ r: CGRect?) -> String {
        r.map { String(format: "(%.1f, %.1f, %.1f×%.1f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"
    }

    /// The event to dispatch instead of `e` (nil = drop it).
    func filter(_ e: NSEvent, in window: NSWindow) -> NSEvent? {
        if dropped != nil { return nil }
        let down = e.type == .leftMouseDown || e.type == .rightMouseDown
        guard (firstEventNumber..<(firstEventNumber + expected)).contains(e.eventNumber) else {
            // posted by the driver while handling this click (the slider emulation re-posts its release): as is
            if e.eventNumber >= firstEventNumber, e.eventNumber <= SyntheticEvents.eventNumber { return e }
            // not one of this click's events (a real or stale event): never delivered to the test window
            foreign.append(String(format: "%@ #%d at %.0f,%.0f (click #%d)", down ? "press" : "release", e.eventNumber,
                                  e.locationInWindow.x, e.locationInWindow.y, firstEventNumber))
            return nil
        }
        if target == nil {
            guard down else { return e }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()   // render the layout: SwiftUI hit-tests against the last rendered frame
            guard let p = locate() else {
                dropped = "the element was not on screen when the press was dispatched (nothing was delivered)"
                return nil
            }
            guard p.x.isFinite, p.y.isFinite else {
                dropped = "the element's geometry was not settled when the press was dispatched (\(p); nothing was delivered)"
                return nil
            }
            if let onView, let host = window.contentView {
                let hit = host.hitTest(host.superview?.convert(p, from: nil) ?? p)
                if !(hit.map { $0 === onView || $0.isDescendant(of: onView) } ?? false) {
                    dropped = "the press point was covered by \(hit.map { String(describing: type(of: $0)) } ?? "nothing") at dispatch (nothing was delivered)"
                    return nil
                }
            }
            let frame = TestAnchors.shared.frame(id)
            if let f = frame, f.width < 1 || f.height < 1 {
                dropped = "the element's frame was degenerate at dispatch (\(Self.describe(f)); nothing was delivered)"
                return nil
            }
            // the element moved: compare with the point the driver aimed at (not the event's location, see above)
            let from = aim ?? e.locationInWindow
            let d = CGVector(dx: p.x - from.x, dy: p.y - from.y)
            if abs(d.dx) > 0.5 || abs(d.dy) > 0.5 {
                let moved = String(format: "moved %.1f, %.1f pt between resolution and dispatch", d.dx, -d.dy)
                    + " (frame \(Self.describe(resolvedFrame)) → \(Self.describe(frame)))"
                guard lastAttempt else {
                    dropped = "the element \(moved): layout in flux, nothing was delivered"
                    return nil
                }
                retarget = moved
            }
            target = p
        }
        if down { presses += 1 } else { releases += 1 }
        owners.append(TestAnchors.shared.owner(id))
        guard let p = target else { return e }
        let at = e.locationInWindow
        if abs(at.x - p.x) <= 0.5, abs(at.y - p.y) <= 0.5 { return e }
        // (written so that a non-finite location — seen too, it crashed an Int() conversion — counts as relocated)
        if let aim, !(abs(at.x - aim.x) <= 0.5 && abs(at.y - aim.y) <= 0.5) {
            // the event did not arrive where it was posted (FLAKY-UI3: inspector_masks_speed aimed 300,193, the press
            // arrived at -5556,-5640 in the same window): every event of the click goes to the located point
            relocated.append(String(format: "%@ #%d at %.0f,%.0f instead of %.0f,%.0f (last synthetic #%d; window %@ → %@)",
                                    down ? "press" : "release", e.eventNumber, at.x, at.y, aim.x, aim.y, SyntheticEvents.eventNumber,
                                    Self.describe(windowFrame), Self.describe(window.frame)))
        }
        guard let moved = NSEvent.mouseEvent(with: e.type, location: p, modifierFlags: e.modifierFlags, timestamp: e.timestamp,
                                             windowNumber: e.windowNumber, context: nil, eventNumber: e.eventNumber,
                                             clickCount: e.clickCount, pressure: e.pressure) else { return e }
        SyntheticEvents.windowLocation = p
        SyntheticEvents.screenLocation = window.convertPoint(toScreen: p)
        return moved
    }

    /// Why the click provably did NOT reach the element (nothing was dispatched to it: safe to click again); nil otherwise.
    func notDelivered() -> String? {
        if let dropped { return dropped }
        if presses < expected { return "\(presses) of \(expected) press(es) dispatched" }
        return nil
    }

    /// Anomalies AFTER the press reached the element (reported, never re-clicked: the element may already have acted —
    /// e.g. an action on press that rebuilds it).
    func releaseAnomaly() -> String? {
        // (a release consumed by an AppKit tracking loop — NSTextField, NSSlider — never reaches sendEvent: not an anomaly)
        if releases < expected { return nil }
        if Set(owners.map { $0?.uuidString ?? "-" }).count > 1 { return "the element was rebuilt between press and release" }
        return nil
    }
}

