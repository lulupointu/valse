import AppKit
import SwiftUI
import MontageCore
import MontageEngine
import MontageUI

/// Command-line options (used by scripts/screenshot.sh and agents):
///   --open <path.montage>     open a project
///   --demo                    open a generated demo project
///   --lang en|fr              UI language for this session (does not change the saved preference)
///   --background              never activate / steal focus (window opens behind other apps)
///   --window-id-file <path>   write the main window's CGWindowID (for `screencapture -l`)
///   --snapshot <png>          render the window offscreen to a PNG (no Screen Recording permission needed)
///   --quit-after <seconds>    quit automatically
///   --size <w>x<h>            initial window size in points (default 1687x983, CapCut's default)
///   --uitest <script.json>    run a UI test script in an offscreen, never-activated window, then exit (docs/TESTING.md)
///     --uitest-out <dir>      where snapshots / dumps / report.json go (default build/uitest/<name>)
///     --baselines <dir>       screenshot baselines (app/Tests/Baselines); --update-baselines rewrites them
///   --home-demo <n>           temporary library with n sample projects (settings isolated); --ui-state <spec> opens a dialog
///   --imgdiff <a.png> <b.png> [--threshold 16] [--tolerance 0.005] [--diff out.png]   compare two images, JSON result
///   --analyze-content <manifest.json> <content-dir> <out.json>   analyse the music/SFX library (fetch_music_pack.sh)
struct Options {
    var open: URL?
    var demo = false
    var lang: String?
    var background = false
    var windowIDFile: URL?
    var snapshot: URL?
    var quitAfter: Double?
    /// --player-state "seek=7,select=text,rulers,guide=h:0.33,safe=tiktok,zoom=1.5" (screenshots, see PlayerDebugState)
    var playerState: String?
    var size = CGSize(width: 1687, height: 983)
    var uitest: URL?
    var uitestOut: URL?
    var baselines: URL?
    var updateBaselines = false
    /// --home-demo <n>: fill a temporary project library with n sample projects (screenshots, perf); isolates settings.
    var homeDemo: Int?
    /// --ui-state "settings=performance" | "shortcuts" | "newProject" | "home" | "versions" | "details=0" … (screenshots)
    var uiState: String?

    init(_ args: [String]) {
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--open": open = next().map { URL(fileURLWithPath: $0) }
            case "--demo": demo = true
            case "--lang": lang = next()
            case "--background": background = true
            case "--window-id-file": windowIDFile = next().map { URL(fileURLWithPath: $0) }
            case "--snapshot": snapshot = next().map { URL(fileURLWithPath: $0) }
            case "--quit-after": quitAfter = next().flatMap(Double.init)
            case "--player-state": playerState = next()
            case "--uitest": uitest = next().map { URL(fileURLWithPath: $0) }
            case "--uitest-out": uitestOut = next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--baselines": baselines = next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--update-baselines": updateBaselines = true
            case "--home-demo": homeDemo = next().flatMap(Int.init)
            case "--ui-state": uiState = next()
            case "--size":
                if let s = next() {
                    let p = s.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { size = CGSize(width: p[0], height: p[1]) }
                }
            default: break
            }
            i += 1
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options = Options(CommandLine.arguments)
    var window: NSWindow!
    var store: EditorStore!
    var app: AppModel!
    var menuBuilder: AppMenuBuilder?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        MontageBootstrap.registerResources()
        if let lang = options.lang { L10n.shared.setLanguageForSession(lang) }
        if options.uitest != nil || options.homeDemo != nil { HomeSandbox.isolate(uitest: options.uitest != nil) }
        store = EditorStore()
        AppShutdown.store = store
        app = AppModel(store: store)
        // UI tests and --open/--demo start in the editor; the normal launch shows Home.
        if options.uitest != nil || options.open != nil || options.demo { app.screen = .editor }
        buildMenu()
        makeWindow()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // OB-11: arrows / Home / End move the caret of a focused text field (any window, modals included)
            if TextFieldKeys.route(e) { return nil }
            guard let self, e.window === self.window, self.app.modal == nil else { return e }
            if self.app.screen == .home {
                // ⌫ / ⌘⌫ on Home: trash the selected projects (in the Trash: delete forever)
                let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
                guard e.keyCode == 51 || e.keyCode == 117, m.isEmpty || m == .command, !(e.window?.firstResponder is NSText),
                      !self.app.selectedIDs.isEmpty else { return e }
                self.app.trashOrDeleteSelection()
                return nil
            }
            // P1 project switcher open: its keys first; other keys go to its search field, never to editor shortcuts
            if self.app.switcher.isOpen { return self.app.switcher.handle(e) ? nil : e }
            return ShortcutRegistry.handle(e, store: self.store) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildMenu() }
        }
        NotificationCenter.default.addObserver(forName: Keymap.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildMenu() }
        }
        if options.uitest == nil { CacheCleaner.runAutomaticCleanup(AppPreferences.shared.settings) }
        Task { await loadInitialProject() }
        if let q = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
    }

    func loadInitialProject() async {
        if let script = options.uitest {
            let config = UITestDriver.Config(script: script, outDir: options.uitestOut, baselines: options.baselines,
                                             updateBaselines: options.updateBaselines)
            UITestDriver.projectHook = { [weak self] spec in try await self?.app.uitestSetUp(spec) ?? false }
            StateDump.appHook = { [weak self] in self?.app.stateDump() ?? [:] }
            let code = await UITestDriver(store: store, window: window, config: config).run()
            await AppShutdown.stopBackgroundWork()
            AppShutdown.exit(code)
        }
        do {
            if let n = options.homeDemo { await app.populateDemoLibrary(count: n) }
            if let url = options.open {
                app.open(url)
            } else if options.demo {
                let p = try await DemoProject.make()
                store.autosaveEnabled = false
                store.load(project: p)
                store.seek(to: Time(2.5))
                store.selection = [p.timeline.mainTrack!.clips[1].id]            }
        } catch {
            store.showToast(String(describing: error), error: true)
        }
        if let spec = options.playerState { PlayerDebugState.apply(spec, to: store) }
        if let spec = options.uiState { await app.applyDebugState(spec) }
        if let snap = options.snapshot {
            // give the compositor, thumbnails and SwiftUI layout time to settle
            try? await Task.sleep(for: .seconds(3))
            let ok = SnapshotRegistry.shared.writePNG(window: window, to: snap)
            FileHandle.standardError.write(Data("snapshot \(ok ? "written" : "FAILED"): \(snap.path)\n".utf8))
            if options.quitAfter == nil { NSApp.terminate(nil) }
        }
    }

    func makeWindow() {
        let w = options.uitest != nil ? UITestDriver.makeWindow(size: options.size)
            : NSWindow(contentRect: NSRect(origin: .zero, size: options.size),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1)
        w.minSize = NSSize(width: 1100, height: 680)
        w.title = "Montage"
        w.delegate = self
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(app: app))
        // No title-bar safe area: content runs under the transparent title bar, so the editor's 36 pt TitleBar holds the
        // traffic lights like CapCut's single bar (UX_GAPS W12-2), and Home's sidebar starts at the window top.
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        w.contentView = host
        w.center()
        if options.uitest != nil {
            w.orderBack(nil)  // offscreen (UITestWindow), never activated
        } else if options.background {
            // Never cover or activate over other apps (another agent may be driving the screen): behind everything.
            w.orderBack(nil)
        } else {
            w.makeKeyAndOrderFront(nil)
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
        window = w
        if let f = options.windowIDFile {
            try? "\(w.windowNumber)".write(to: f, atomically: true, encoding: .utf8)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// P1 (CapCut): the red close button in the editor goes back to Home ("Saved to project"); on Home it quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool { app?.windowShouldClose() ?? true }

    /// Finder "Open With" / drop on the Dock icon (MI-028): projects open, media files are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let store, let app else { return }
        let projects = urls.filter { $0.pathExtension.lowercased() == ProjectPackage.fileExtension }
        if let p = projects.first { app.open(p) }
        let media = urls.filter { !projects.contains($0) }
        if !media.isEmpty, app.screen == .editor { store.importMedia(media) }
    }
    func applicationWillTerminate(_ notification: Notification) { store?.close() }

    /// Quit saves the open project (version + cover) before exiting.
    /// Also stops background AI / media jobs first: quitting while Core ML or Metal work is mid-flight crashed in the
    /// frameworks' exit teardown (LaMa inference, STATUS cross-team row).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let saves = app != nil && app.screen == .editor && store.packageURL != nil && options.uitest == nil
        Task {
            await AppShutdown.stopBackgroundWork()
            if saves { await store.closeProject() }
            if AppShutdown.workStillRunning { store?.close(); AppShutdown.exit(0) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu

    func buildMenu() {
        let b = menuBuilder ?? AppMenuBuilder(app: app)
        b.importMedia = { [weak self] in self?.importMedia() }
        menuBuilder = b
        NSApp.mainMenu = b.build()
    }

    func importMedia() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.movie, .audio, .image, .folder]
        if p.runModal() == .OK { store.importFiles(p.urls) }
    }
}

/// Closure target for menu items.
final class ClosureTarget: NSObject {
    private let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

// UI tests: private per-process settings domain + pasteboard, set before anything reads a setting (AppDefaults)
if CommandLine.arguments.contains("--uitest") { AppDefaults.isolateForUITest() }
if let i = CommandLine.arguments.firstIndex(of: "--imgdiff") { exit(ImageDiffCLI.run(Array(CommandLine.arguments[(i + 1)...]))) }
// scripts/fetch_music_pack.sh: offline analysis of the content library (beats, key, peaks, similarity features)
if let i = CommandLine.arguments.firstIndex(of: "--analyze-content") { exit(ContentAnalyzer.runCLI(Array(CommandLine.arguments[(i + 1)...]))) }
Tooltips.install()   // hover tooltips after 0.4 s app-wide (CapCut-like), C3
if CommandLine.arguments.contains("--uitest") { UITestDriver.prepareProcess() }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// --background: accessory policy = no Dock icon and no activation on launch.
let headless = CommandLine.arguments.contains("--background") || CommandLine.arguments.contains("--uitest")
app.setActivationPolicy(headless ? .accessory : .regular)
app.run()
