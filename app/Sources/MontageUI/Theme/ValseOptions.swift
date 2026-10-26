import AppKit
import SwiftUI
import MontageCore

// TEMPORARY (VALSE-APP round 10): the one open choice left, the editor logo's placement × opening animation,
// switchable live from the "Valse options" menu. Once picked: keep that branch in `TitleBar` / `EditorView`
// (`ValseOptions.shared.logo`), delete this file, its strings tables (ValseOptions.strings) and the
// `ValseOptions.menuItem()` line in AppMenu.swift. (Round 9's clip colours, Export, tabs, toolbar icons and sliders
// were picked in round 10 and are permanent now.)

@MainActor
public final class ValseOptions: ObservableObject {
    public static let shared = ValseOptions()
    static let enabled = true

    /// Never in UI tests, screenshots or offscreen windows: they always use the default (stable baselines).
    static let isTooling: Bool = {
        let a = CommandLine.arguments
        return a.contains("--uitest") || a.contains("--snapshot") || a.contains("--offscreen")
    }()
    static var menuVisible: Bool { enabled && !isTooling }

    /// The editor's Valse mark (`ValseEditorMark`). A: title bar left, draws itself in place. B: the same, plus a film
    /// strip swiping across the title bar. C: next to EditPilot / Export, draws in place.
    public enum Logo: String, CaseIterable { case a = "A", b = "B", c = "C" }

    @Published public var logo: Logo { didSet { if !Self.isTooling { AppDefaults.store.set(logo.rawValue, forKey: "ValseOpt.logo") } } }

    private init() {
        // review stills / clips force a value: VALSE_OPT_LOGO=A…C; tooling otherwise always gets the default
        if let v = ProcessInfo.processInfo.environment["VALSE_OPT_LOGO"], let l = Logo(rawValue: v) { logo = l; return }
        logo = Self.isTooling ? .a : (AppDefaults.store.string(forKey: "ValseOpt.logo").flatMap(Logo.init(rawValue:)) ?? .a)
    }

    // MARK: Menu

    /// "Valse options" menu (menu bar), one submenu, a check on the current option.
    static func menuItem() -> NSMenuItem {
        let root = NSMenuItem(title: tr("valseopt.menu"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr("valseopt.menu"))
        m.autoenablesItems = false
        let o = shared
        m.addItem(sub("valseopt.logo", Logo.allCases, { o.logo }, { o.logo = $0 }))
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

/// Refreshes the check marks every time a submenu opens.
@MainActor
final class ValseOptionsMenuDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    var refreshers: [@MainActor () -> Void] = []
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { refreshers.forEach { $0() } }
    }
}
