import AppKit
import SwiftUI
import MontageCore

// TEMPORARY (VALSE-APP round 13): the neutral chrome ladder is switchable live from "Valse options ▸ Chrome colours"
// so the owner can compare palettes in the real app. Accents (teal, mint, mustard, orange, burgundy, cream), clip
// colours and the viewer's neutral black never change. Once a palette is picked: write its values back into
// `Theme` as constants, delete this file, its strings tables (ValseOptions.strings) and the menu line in AppMenu.swift.
// The values are generated from the current warm ladder in OKLCH (same lightness steps, new hue / chroma; text3
// raised to >= 4.5:1 on every control fill in the alternatives) by scratchpad/valse/palettes.py.

/// Every neutral of the chrome, one slot per token (`Theme`, `Theme.TL`, `Theme.Valse`, `IStyle`, `ExportStyle`).
nonisolated public struct ChromePalette: Sendable, Equatable {

    public let window: UInt32
    public let home: UInt32
    public let panel: UInt32
    public let panelHeader: UInt32
    public let inset: UInt32
    public let control: UInt32
    public let buttonSecondary: UInt32
    public let stepper: UInt32
    public let segmentSelected: UInt32
    public let trackMain: UInt32
    public let menu: UInt32
    public let separator: UInt32
    public let headerSeparator: UInt32
    public let tlBackground: UInt32
    public let tlLaneMain: UInt32
    public let tlLane: UInt32
    public let tlHeader: UInt32
    public let tlHeaderChip: UInt32
    public let tlScrollThumb: UInt32
    public let tlTick: UInt32
    public let canvas: UInt32
    public let sidebar: UInt32
    public let surface: UInt32
    public let raised: UInt32
    public let vControl: UInt32
    public let vControlHover: UInt32
    public let stroke: UInt32
    public let iTrack: UInt32
    public let iField: UInt32
    public let iDropdown: UInt32
    public let iTile: UInt32
    public let iStrip: UInt32
    public let iGraph: UInt32
    public let iconDim: UInt32
    public let textPrimary: UInt32
    public let textSecondary: UInt32
    public let textTertiary: UInt32
    public let ruler: UInt32
    public let emptyText: UInt32
    public let iLabel: UInt32
    public let iIcon: UInt32
}

nonisolated public enum ChromeOption: String, CaseIterable, Sendable {
    /// Current warm charcoal (default) · soft charcoal · graphite · ink · plum · deep contrast.
    case warm, soft, graphite, ink, plum, deep

    nonisolated public var palette: ChromePalette {
        switch self {
        case .warm: return ChromePalette(window: 0x131210,
                         home: 0x121110,
                         panel: 0x1C1A17,
                         panelHeader: 0x2C2925,
                         inset: 0x131210,
                         control: 0x34302B,
                         buttonSecondary: 0x3D3934,
                         stepper: 0x34302B,
                         segmentSelected: 0x3A3631,
                         trackMain: 0x22201D,
                         menu: 0x2A2723,
                         separator: 0x2E2A25,
                         headerSeparator: 0x080706,
                         tlBackground: 0x1C1A17,
                         tlLaneMain: 0x22201D,
                         tlLane: 0x1E1C19,
                         tlHeader: 0x201E1B,
                         tlHeaderChip: 0x2A2723,
                         tlScrollThumb: 0x3A3631,
                         tlTick: 0x5A544C,
                         canvas: 0x121110,
                         sidebar: 0x161513,
                         surface: 0x1C1A17,
                         raised: 0x24211D,
                         vControl: 0x2A2723,
                         vControlHover: 0x34302B,
                         stroke: 0x2E2A25,
                         iTrack: 0x4A453E,
                         iField: 0x131210,
                         iDropdown: 0x2E2B27,
                         iTile: 0x3A3631,
                         iStrip: 0x34302B,
                         iGraph: 0x100F0D,
                         iconDim: 0x6E675D,
                         textPrimary: 0xF1EBDD,
                         textSecondary: 0xBDB5A6,
                         textTertiary: 0x958D80,
                         ruler: 0x8F877A,
                         emptyText: 0xC9C1B2,
                         iLabel: 0xE2DBCC,
                         iIcon: 0xCEC6B7)
        case .soft: return ChromePalette(window: 0x131211,
                         home: 0x121111,
                         panel: 0x1B1A19,
                         panelHeader: 0x252321,
                         inset: 0x131211,
                         control: 0x32302E,
                         buttonSecondary: 0x3B3937,
                         stepper: 0x32302E,
                         segmentSelected: 0x383634,
                         trackMain: 0x21201F,
                         menu: 0x292725,
                         separator: 0x2C2A28,
                         headerSeparator: 0x080707,
                         tlBackground: 0x1B1A19,
                         tlLaneMain: 0x21201F,
                         tlLane: 0x1D1C1B,
                         tlHeader: 0x1F1E1D,
                         tlHeaderChip: 0x252321,
                         tlScrollThumb: 0x383634,
                         tlTick: 0x575450,
                         canvas: 0x121111,
                         sidebar: 0x161514,
                         surface: 0x1B1A19,
                         raised: 0x23211F,
                         vControl: 0x292725,
                         vControlHover: 0x32302E,
                         stroke: 0x2C2A28,
                         iTrack: 0x484542,
                         iField: 0x131211,
                         iDropdown: 0x2D2B29,
                         iTile: 0x383634,
                         iStrip: 0x32302E,
                         iGraph: 0x100F0E,
                         iconDim: 0x6D6760,
                         textPrimary: 0xF0EBE1,
                         textSecondary: 0xBBB5AA,
                         textTertiary: 0x9E988F,
                         ruler: 0x9E988F,
                         emptyText: 0xC7C1B6,
                         iLabel: 0xE0DBD0,
                         iIcon: 0xCCC6BB)
        case .graphite: return ChromePalette(window: 0x121212,
                         home: 0x111111,
                         panel: 0x1A1A1A,
                         panelHeader: 0x2A2929,
                         inset: 0x121212,
                         control: 0x313130,
                         buttonSecondary: 0x3A3A39,
                         stepper: 0x313130,
                         segmentSelected: 0x373736,
                         trackMain: 0x202020,
                         menu: 0x282727,
                         separator: 0x2B2B2A,
                         headerSeparator: 0x070707,
                         tlBackground: 0x1A1A1A,
                         tlLaneMain: 0x202020,
                         tlLane: 0x1C1C1C,
                         tlHeader: 0x1E1E1E,
                         tlHeaderChip: 0x282727,
                         tlScrollThumb: 0x373736,
                         tlTick: 0x565554,
                         canvas: 0x111111,
                         sidebar: 0x151515,
                         surface: 0x1A1A1A,
                         raised: 0x222121,
                         vControl: 0x282727,
                         vControlHover: 0x313130,
                         stroke: 0x2B2B2A,
                         iTrack: 0x464645,
                         iField: 0x121212,
                         iDropdown: 0x2C2B2B,
                         iTile: 0x373736,
                         iStrip: 0x313130,
                         iGraph: 0x0F0F0F,
                         iconDim: 0x6A6864,
                         textPrimary: 0xEDEBE6,
                         textSecondary: 0xB8B6B0,
                         textTertiary: 0x9B9994,
                         ruler: 0x9B9994,
                         emptyText: 0xC4C2BC,
                         iLabel: 0xDEDBD6,
                         iIcon: 0xC9C7C1)
        case .ink: return ChromePalette(window: 0x111215,
                         home: 0x101113,
                         panel: 0x181B1E,
                         panelHeader: 0x262A2F,
                         inset: 0x111215,
                         control: 0x2C3137,
                         buttonSecondary: 0x353A40,
                         stepper: 0x2C3137,
                         segmentSelected: 0x32373D,
                         trackMain: 0x1E2124,
                         menu: 0x24282D,
                         separator: 0x262B31,
                         headerSeparator: 0x060709,
                         tlBackground: 0x181B1E,
                         tlLaneMain: 0x1E2124,
                         tlLane: 0x1A1D20,
                         tlHeader: 0x1C1F22,
                         tlHeaderChip: 0x24282D,
                         tlScrollThumb: 0x32373D,
                         tlTick: 0x4F565E,
                         canvas: 0x101113,
                         sidebar: 0x141518,
                         surface: 0x181B1E,
                         raised: 0x1E2227,
                         vControl: 0x24282D,
                         vControlHover: 0x2C3137,
                         stroke: 0x262B31,
                         iTrack: 0x40464F,
                         iField: 0x111215,
                         iDropdown: 0x282C31,
                         iTile: 0x32373D,
                         iStrip: 0x2C3137,
                         iGraph: 0x0E0F12,
                         iconDim: 0x6A6864,
                         textPrimary: 0xEEEBE6,
                         textSecondary: 0xB9B5B0,
                         textTertiary: 0x9B9994,
                         ruler: 0x9B9994,
                         emptyText: 0xC5C1BC,
                         iLabel: 0xDEDBD6,
                         iIcon: 0xCAC6C1)
        case .plum: return ChromePalette(window: 0x141112,
                         home: 0x121111,
                         panel: 0x1D191B,
                         panelHeader: 0x2E272A,
                         inset: 0x141112,
                         control: 0x362E32,
                         buttonSecondary: 0x3F373B,
                         stepper: 0x362E32,
                         segmentSelected: 0x3C3438,
                         trackMain: 0x231F21,
                         menu: 0x2C2528,
                         separator: 0x30282C,
                         headerSeparator: 0x080707,
                         tlBackground: 0x1D191B,
                         tlLaneMain: 0x231F21,
                         tlLane: 0x1F1B1D,
                         tlHeader: 0x211D1F,
                         tlHeaderChip: 0x2C2528,
                         tlScrollThumb: 0x3C3438,
                         tlTick: 0x5C5256,
                         canvas: 0x121111,
                         sidebar: 0x171415,
                         surface: 0x1D191B,
                         raised: 0x261F22,
                         vControl: 0x2C2528,
                         vControlHover: 0x362E32,
                         stroke: 0x30282C,
                         iTrack: 0x4D4247,
                         iField: 0x141112,
                         iDropdown: 0x30292C,
                         iTile: 0x3C3438,
                         iStrip: 0x362E32,
                         iGraph: 0x110E0F,
                         iconDim: 0x6C6763,
                         textPrimary: 0xF1EAE5,
                         textSecondary: 0xBCB4AF,
                         textTertiary: 0x9D9792,
                         ruler: 0x9D9792,
                         emptyText: 0xC8C0BB,
                         iLabel: 0xE1DAD5,
                         iIcon: 0xCDC5C0)
        case .deep: return ChromePalette(window: 0x0C0B0A,
                         home: 0x0C0B0A,
                         panel: 0x161513,
                         panelHeader: 0x1D1B19,
                         inset: 0x0A0908,
                         control: 0x33302D,
                         buttonSecondary: 0x3C3936,
                         stepper: 0x33302D,
                         segmentSelected: 0x393633,
                         trackMain: 0x1B1A18,
                         menu: 0x242220,
                         separator: 0x33312E,
                         headerSeparator: 0x000000,
                         tlBackground: 0x161513,
                         tlLaneMain: 0x1B1A18,
                         tlLane: 0x181715,
                         tlHeader: 0x191816,
                         tlHeaderChip: 0x242220,
                         tlScrollThumb: 0x393633,
                         tlTick: 0x585450,
                         canvas: 0x0C0B0A,
                         sidebar: 0x100F0E,
                         surface: 0x161513,
                         raised: 0x1F1D1B,
                         vControl: 0x242220,
                         vControlHover: 0x33302D,
                         stroke: 0x33312E,
                         iTrack: 0x484541,
                         iField: 0x0A0908,
                         iDropdown: 0x272523,
                         iTile: 0x393633,
                         iStrip: 0x33302D,
                         iGraph: 0x0A0908,
                         iconDim: 0x6D675F,
                         textPrimary: 0xF0EBE0,
                         textSecondary: 0xBCB5A9,
                         textTertiary: 0x9F988E,
                         ruler: 0x9F988E,
                         emptyText: 0xC8C1B5,
                         iLabel: 0xE1DBCF,
                         iIcon: 0xCDC6BA)
        }
    }
}

/// The palette every chrome token reads (render-time lookups, so a switch only needs a rebuild of the view tree).
nonisolated public enum Chrome {
    nonisolated(unsafe) public static var p: ChromePalette = ChromeOption.warm.palette
}

@MainActor
public final class ValseOptions {
    public static let shared = ValseOptions()

    /// Never in UI tests, screenshots or offscreen windows: they always use the default (stable baselines). Review
    /// stills force a palette with VALSE_OPT_CHROME=warm|soft|graphite|ink|plum|deep.
    static let isTooling: Bool = {
        let a = CommandLine.arguments
        return a.contains("--uitest") || a.contains("--snapshot") || a.contains("--offscreen")
    }()

    public private(set) var chrome: ChromeOption = .warm

    private init() {
        if let v = ProcessInfo.processInfo.environment["VALSE_OPT_CHROME"], let o = ChromeOption(rawValue: v) {
            chrome = o
        } else if !Self.isTooling, let s = AppDefaults.store.string(forKey: "ValseOpt.chrome"), let o = ChromeOption(rawValue: s) {
            chrome = o
        }
        Chrome.p = chrome.palette
    }

    /// Applies a palette live: every window's SwiftUI tree is rebuilt (the same path as a live language switch).
    public func setChrome(_ o: ChromeOption) {
        guard o != chrome else { return }
        chrome = o
        Chrome.p = o.palette
        if !Self.isTooling { AppDefaults.store.set(o.rawValue, forKey: "ValseOpt.chrome") }
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) { w.backgroundColor = RGBA(hex: Chrome.p.window).nsColor }
        NotificationCenter.default.post(name: L10n.didChange, object: nil)
    }

    // MARK: Menu

    /// "Valse options" menu (menu bar): Chrome colours ▸ one entry per palette, a check on the current one.
    static func menuItem() -> NSMenuItem? {
        guard !isTooling else { return nil }
        let root = NSMenuItem(title: tr("valseopt.menu"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr("valseopt.menu"))
        m.autoenablesItems = false
        let item = NSMenuItem(title: tr("valseopt.chrome"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: tr("valseopt.chrome"))
        sub.autoenablesItems = false
        let delegate = ValseOptionsMenuDelegate()
        for o in ChromeOption.allCases {
            let i = PlayerMenuAction.item(tr("valseopt.chrome.\(o.rawValue)")) { MainActor.assumeIsolated { shared.setChrome(o) } }
            sub.addItem(i)
            delegate.refreshers.append { [weak i] in i?.state = shared.chrome == o ? .on : .off }
        }
        sub.delegate = delegate
        objc_setAssociatedObject(sub, &ValseOptionsMenuDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        item.submenu = sub
        m.addItem(item)
        root.submenu = m
        return root
    }
}

/// Refreshes the check marks every time the submenu opens.
@MainActor
final class ValseOptionsMenuDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    var refreshers: [@MainActor () -> Void] = []
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { refreshers.forEach { $0() } }
    }
}
