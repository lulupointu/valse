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
struct Options {
    var open: URL?
    var demo = false
    var lang: String?
    var background = false
    var windowIDFile: URL?
    var snapshot: URL?
    var quitAfter: Double?
    var size = CGSize(width: 1687, height: 983)

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
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        MontageBootstrap.registerResources()
        if let lang = options.lang { L10n.shared.setLanguageForSession(lang) }
        store = EditorStore()
        buildMenu()
        makeWindow()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return ShortcutRegistry.handle(e, store: self.store) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildMenu() }
        }
        Task { await loadInitialProject() }
        if let q = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
    }

    func loadInitialProject() async {
        do {
            if let url = options.open {
                try store.open(url)
            } else if options.demo {
                let p = try await DemoProject.make()
                store.autosaveEnabled = false
                store.load(project: p)
                store.seek(to: Time(2.5))
                store.selection = [p.timeline.mainTrack!.clips[1].id]
            }
        } catch {
            store.showToast(String(describing: error), error: true)
        }
        if let snap = options.snapshot {
            // give the compositor, thumbnails and SwiftUI layout time to settle
            try? await Task.sleep(for: .seconds(3))
            let ok = SnapshotRegistry.shared.writePNG(window: window, to: snap)
            FileHandle.standardError.write(Data("snapshot \(ok ? "written" : "FAILED"): \(snap.path)\n".utf8))
            if options.quitAfter == nil { NSApp.terminate(nil) }
        }
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: options.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1)
        w.minSize = NSSize(width: 1100, height: 680)
        w.title = "Montage"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: EditorView(store: store))
        w.center()
        if options.background {
            // Never cover or activate over other apps (another agent may be driving the screen): behind everything.
            w.orderBack(nil)
        } else {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window = w
        if let f = options.windowIDFile {
            try? "\(w.windowNumber)".write(to: f, atomically: true, encoding: .utf8)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store?.close() }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        func menu(_ titleKey: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let m = NSMenu(title: tr(titleKey))
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func item(_ key: String, _ equiv: String, _ mods: NSEvent.ModifierFlags = .command, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let target = ClosureTarget(action)
            let i = NSMenuItem(title: tr(key), action: #selector(ClosureTarget.fire), keyEquivalent: equiv)
            i.target = target
            i.representedObject = target  // retains the target
            i.keyEquivalentModifierMask = mods
            return i
        }
        menu("menu.app", [
            item("menu.about", "") { NSApp.orderFrontStandardAboutPanel(nil) },
            .separator(),
            item("menu.hide", "h") { NSApp.hide(nil) },
            item("menu.quit", "q") { NSApp.terminate(nil) },
        ])
        menu("menu.file", [
            item("menu.new", "n") { [weak self] in self?.newProject() },
            item("menu.open", "o") { [weak self] in self?.openProject() },
            item("menu.save", "s") { [weak self] in self?.store.save() },
            item("menu.saveAs", "s", [.command, .shift]) { [weak self] in self?.saveProjectAs() },
            .separator(),
            item("menu.import", "i") { [weak self] in self?.importMedia() },
            item("menu.export", "e") { [weak self] in self?.store.isExportSheetPresented = true },
        ])
        menu("menu.edit", [
            item("menu.undo", "z") { [weak self] in self?.store.undo() },
            item("menu.redo", "z", [.command, .shift]) { [weak self] in self?.store.redo() },
            .separator(),
            item("menu.split", "") { [weak self] in self?.store.splitAtPlayhead() },
            item("menu.delete", "") { [weak self] in self?.store.deleteSelection() },
            .separator(),
            NSMenuItem(title: tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
        ])
        menu("menu.view", [
            item("menu.zoomIn", "") { [weak self] in self?.store.zoom(by: 1.25) },
            item("menu.zoomOut", "") { [weak self] in self?.store.zoom(by: 0.8) },
            .separator(),
            item("menu.language.en", "") { L10n.shared.setLanguagePreference("en") },
            item("menu.language.fr", "") { L10n.shared.setLanguagePreference("fr") },
            item("menu.language.system", "") { L10n.shared.setLanguagePreference("system") },
        ])
        menu("menu.window", [
            item("menu.minimize", "m") { NSApp.keyWindow?.miniaturize(nil) },
            item("menu.fullscreen", "f", [.command, .control]) { NSApp.keyWindow?.toggleFullScreen(nil) },
        ])
        NSApp.mainMenu = main
    }

    func newProject() {
        store.close()
        store.load(project: Project())
    }

    func openProject() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.init(filenameExtension: ProjectPackage.fileExtension) ?? .package]
        p.treatsFilePackagesAsDirectories = false
        p.canChooseDirectories = true
        if p.runModal() == .OK, let u = p.url {
            do { try store.open(u) } catch { store.showToast(tr("error.unreadable"), error: true) }
        }
    }

    func saveProjectAs() {
        let p = NSSavePanel()
        p.nameFieldStringValue = store.projectName + "." + ProjectPackage.fileExtension
        if p.runModal() == .OK, let u = p.url { store.saveAs(u) }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// --background: accessory policy = no Dock icon and no activation on launch.
app.setActivationPolicy(CommandLine.arguments.contains("--background") ? .accessory : .regular)
app.run()
