import SwiftUI
import AppKit
import MontageCore

/// Design tokens from docs/UX.md §1.2–1.4 (CapCut dark theme). Use these, never literal colours.
public enum Theme {
    // Backgrounds
    public static let window = Color(hex: 0x141414)
    public static let home = Color(hex: 0x0D0D0D)
    public static let panel = Color(hex: 0x1B1B1C)
    public static let panelHeader = Color(hex: 0x303030)
    public static let inset = Color(hex: 0x121212)
    public static let control = Color(hex: 0x3B3B3B)
    public static let buttonSecondary = Color(hex: 0x4F4F4F)
    public static let stepper = Color(hex: 0x3D3D3D)
    public static let segmentSelected = Color(hex: 0x3A3A3A)
    public static let trackMain = Color(hex: 0x242425)
    public static let menu = Color(hex: 0x2E2E2E)
    public static let separator = Color(hex: 0x2A2A2A)
    public static let headerSeparator = Color(hex: 0x070709)
    // Accent
    public static let accent = Color(hex: 0x57BECB)
    public static let accentDim = Color(hex: 0x387379)
    // Text
    public static let textPrimary = Color(hex: 0xE6E6E6)
    public static let textSecondary = Color(hex: 0xB3B3B3)
    public static let textTertiary = Color(hex: 0x7A7A7A)
    public static let ruler = Color(hex: 0x8A8A8A)

    // Timeline clip colours (as rendered)
    public static func clipColor(_ kind: TrackKind) -> RGBA {
        switch kind {
        case .video: return RGBA(hex: 0x1D4950)
        case .audio: return RGBA(hex: 0x182F55)
        case .text: return RGBA(hex: 0x9C604F)
        case .sticker: return RGBA(hex: 0xCC9641)
        case .effect: return RGBA(hex: 0x7C5E8C)
        case .filter: return RGBA(hex: 0x595493)
        case .adjustment: return RGBA(hex: 0xA58744)
        }
    }
    public static let waveform = RGBA(hex: 0x3A7FAF)
    public static let waveformOnVideo = RGBA(hex: 0x2F5E63)

    // Metrics (pt)
    public enum Metrics {
        public static let titleBarHeight: CGFloat = 36
        public static let outerGutter: CGFloat = 8
        public static let gutter: CGFloat = 6
        public static let panelHeader: CGFloat = 42
        public static let panelRadius: CGFloat = 6
        public static let buttonRadius: CGFloat = 4
        public static let inspectorPadding: CGFloat = 12
        public static let rowSpacing: CGFloat = 10
        public static let minAssetWidth: CGFloat = 340
        public static let minPlayerWidth: CGFloat = 320
        public static let minInspectorWidth: CGFloat = 300
    }

    // Typography
    public enum Fonts {
        public static let tabLabel = Font.system(size: 11)
        public static let panelTitle = Font.system(size: 13, weight: .medium)
        public static let sectionTitle = Font.system(size: 13, weight: .semibold)
        public static let row = Font.system(size: 12)
        public static let numeric = Font.system(size: 12).monospacedDigit()
        public static let hint = Font.system(size: 11)
        public static let clipLabel = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        public static let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    }
}

extension Color {
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    public init(_ c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

extension RGBA {
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
}
