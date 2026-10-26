import AppKit
import SwiftUI
import MontageCore

// TEMPORARY (VALSE-APP round 9): the open design choices of the app-wide Valse redesign, switchable live from the
// "Valse options" menu in the menu bar so the owner can compare them in the real app. Once each is picked: keep the
// chosen branch at every `ValseOptions.shared.<choice>` use, delete this file, its strings tables
// (ValseOptions.strings) and the `ValseOptions.menuItem()` line in AppMenu.swift.

@MainActor
public final class ValseOptions: ObservableObject {
    public static let shared = ValseOptions()
    /// The one switch: false removes the menu (the defaults below then apply everywhere).
    static let enabled = true
    /// Posted on every change (AppKit-drawn views such as the timeline redraw on it).
    public static let didChange = Notification.Name("ValseOptionsDidChange")

    /// Never in UI tests, screenshots or offscreen windows: they always use the defaults (stable baselines).
    static let isTooling: Bool = {
        let a = CommandLine.arguments
        return a.contains("--uitest") || a.contains("--snapshot") || a.contains("--offscreen")
    }()
    static var menuVisible: Bool { enabled && !isTooling }

    /// 1. Timeline clip colours. A: today's functional colours (cool CapCut family). B: the same roles moved into the
    /// Valse palette (teal / burgundy / mustard / orange family, desaturated for long viewing).
    public enum ClipColors: String, CaseIterable { case a = "A", b = "B" }
    /// 2. Export button. A: mustard brand CTA (the one loud thing, like Home's New project). B: teal primary.
    /// C: quiet (control fill, mint glyph).
    public enum ExportStyle: String, CaseIterable { case a = "A", b = "B", c = "C" }
    /// 3. Selected panel tab (asset panel, inspector, segmented tabs). A: mint label + teal underline bar.
    /// B: mint sticker (mint fill, ink label). C: raised neutral pill, mint label.
    public enum TabStyle: String, CaseIterable { case a = "A", b = "B", c = "C" }
    /// 4. Toolbar icon buttons (timeline toolbar, player bar, top bar). A: plain glyph, brightens on hover.
    /// B: quiet key (soft fill on hover, like the selection bar keys).
    public enum ToolIcons: String, CaseIterable { case a = "A", b = "B" }
    /// 5. Inspector sliders (filled part of the track + knob tint). A: cream (calm). B: teal. Switches stay teal.
    public enum SliderAccent: String, CaseIterable { case a = "A", b = "B" }
    public var sliderTint: Color { sliders == .a ? Theme.Valse.cream : Theme.accent }

    @Published public var clipColors: ClipColors {
        didSet { Theme.valseClipPalette = clipColors == .b; save(clipColors.rawValue, "clip") }
    }
    @Published public var export: ExportStyle { didSet { save(export.rawValue, "export") } }
    @Published public var tabs: TabStyle { didSet { save(tabs.rawValue, "tabs") } }
    @Published public var toolIcons: ToolIcons { didSet { save(toolIcons.rawValue, "tools") } }
    @Published public var sliders: SliderAccent { didSet { save(sliders.rawValue, "sliders") } }

    private init() {
        let env = ProcessInfo.processInfo.environment
        func load<T: RawRepresentable>(_ key: String, _ d: T) -> T where T.RawValue == String {
            // review stills force a value: VALSE_OPT_<KEY>=A…; tooling otherwise always gets the default
            if let v = env["VALSE_OPT_\(key.uppercased())"], let t = T(rawValue: v) { return t }
            guard !Self.isTooling else { return d }
            return AppDefaults.store.string(forKey: "ValseOpt.\(key)").flatMap(T.init(rawValue:)) ?? d
        }
        clipColors = load("clip", ClipColors.a)
        export = load("export", ExportStyle.a)
        tabs = load("tabs", TabStyle.a)
        toolIcons = load("tools", ToolIcons.b)
        sliders = load("sliders", SliderAccent.a)
        Theme.valseClipPalette = clipColors == .b
    }

    private func save(_ v: String, _ key: String) {
        if !Self.isTooling { AppDefaults.store.set(v, forKey: "ValseOpt.\(key)") }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Menu

    /// "Valse options" menu (menu bar). One submenu per open choice, a check on the current option.
    static func menuItem() -> NSMenuItem {
        let root = NSMenuItem(title: tr("valseopt.menu"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr("valseopt.menu"))
        m.autoenablesItems = false
        let o = shared
        m.addItem(sub("valseopt.clip", ClipColors.allCases, { o.clipColors }, { o.clipColors = $0 }))
        m.addItem(sub("valseopt.export", ExportStyle.allCases, { o.export }, { o.export = $0 }))
        m.addItem(sub("valseopt.tabs", TabStyle.allCases, { o.tabs }, { o.tabs = $0 }))
        m.addItem(sub("valseopt.tools", ToolIcons.allCases, { o.toolIcons }, { o.toolIcons = $0 }))
        m.addItem(sub("valseopt.sliders", SliderAccent.allCases, { o.sliders }, { o.sliders = $0 }))
        root.submenu = m
        return root
    }

    private static func sub<T: RawRepresentable & Equatable>(_ key: String, _ all: [T], _ get: @escaping @MainActor () -> T,
                                                              _ set: @escaping @MainActor (T) -> Void) -> NSMenuItem
        where T.RawValue == String {
        let item = NSMenuItem(title: tr(key), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr(key))
        m.autoenablesItems = false
        let delegate = ValseOptionsMenuDelegate()
        for v in all {
            let i = PlayerMenuAction.item(tr("\(key).\(v.rawValue.lowercased())")) { MainActor.assumeIsolated { set(v) } }
            m.addItem(i)
            delegate.refreshers.append { [weak i] in i?.state = get() == v ? .on : .off }
        }
        m.delegate = delegate
        objc_setAssociatedObject(m, &ValseOptionsMenuDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        item.submenu = m
        return item
    }
}

/// Slider tint from the open choice (`ValseOptions.sliders`).
struct ValseSliderTint: ViewModifier {
    @ObservedObject private var options = ValseOptions.shared
    func body(content: Content) -> some View { content.tint(options.sliderTint) }
}

extension View {
    /// Every slider in the editor (inspector rows, zoom, cover, library previews).
    func valseSliderTint() -> some View { modifier(ValseSliderTint()) }
}

/// Refreshes the check marks every time a submenu opens.
@MainActor
final class ValseOptionsMenuDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    var refreshers: [@MainActor () -> Void] = []
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { refreshers.forEach { $0() } }
    }
}
