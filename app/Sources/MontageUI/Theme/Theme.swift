import SwiftUI
import AppKit
import MontageCore

/// Design tokens. Use these, never literal colours. VALSE-APP: the CapCut greys and cyan of docs/UX.md §1.2–1.4 are
/// remapped to the Valse warm charcoal + teal (direction.md "editor remap", Valse design/ui/STYLE_GUIDE.md §2). Warm
/// neutrals keep their chroma low so they never bias footage; the viewer itself stays pure neutral black.
public enum Theme {
    // Backgrounds
    public static let window = Color(hex: 0x131210)
    public static let home = Color(hex: 0x121110)
    public static let panel = Color(hex: 0x1C1A17)
    public static let panelHeader = Color(hex: 0x2C2925)
    public static let inset = Color(hex: 0x131210)
    public static let control = Color(hex: 0x34302B)
    public static let buttonSecondary = Color(hex: 0x3D3934)
    public static let stepper = Color(hex: 0x34302B)
    public static let segmentSelected = Color(hex: 0x3A3631)
    public static let trackMain = Color(hex: 0x22201D)
    public static let menu = Color(hex: 0x2A2723)
    public static let separator = Color(hex: 0x2E2A25)
    public static let headerSeparator = Color(hex: 0x080706)
    // Accent (Valse teal; anything drawn on an accent fill is `onAccent` ink, never white: 6.2:1 vs 2.4:1)
    public static let accent = Color(hex: 0x2BAF90)
    public static let accentDim = Color(hex: 0x1E5E4F)
    public static let onAccent = Color(hex: 0x14110C)
    /// Accent as text / glyph on dark surfaces (mint, 11:1): active tab labels, selected glyphs.
    public static let accentText = Color(hex: 0xA1D4B1)
    // Text
    public static let textPrimary = Color(hex: 0xF1EBDD)
    public static let textSecondary = Color(hex: 0xBDB5A6)
    public static let textTertiary = Color(hex: 0x958D80)
    public static let ruler = Color(hex: 0x8F877A)

    /// TEMPORARY (VALSE-APP round 9) mirror of `ValseOptions.clipColors == .b`, read by the Metal timeline drawing.
    nonisolated(unsafe) public static var valseClipPalette = false

    // Timeline clip colours (as rendered)
    public static func clipColor(_ kind: TrackKind) -> RGBA {
        if valseClipPalette {
            // Option B: the same roles in the Valse palette, desaturated and darkened for long viewing (thumbnails sit
            // on video; labels stay white): teal, burgundy, orange, mustard, plum, sea green, olive.
            switch kind {
            case .video: return RGBA(hex: 0x1D5247)
            case .audio: return RGBA(hex: 0x4E2231)
            case .text: return RGBA(hex: 0xA2502C)
            case .sticker: return RGBA(hex: 0xB0852F)
            case .effect: return RGBA(hex: 0x7A3451)
            case .filter: return RGBA(hex: 0x3D6A5D)
            case .adjustment: return RGBA(hex: 0x86723A)
            }
        }
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
    public static var waveform: RGBA { valseClipPalette ? RGBA(hex: 0xD9846A) : RGBA(hex: 0x3A7FAF) }
    public static var waveformOnVideo: RGBA { valseClipPalette ? RGBA(hex: 0x2E7464) : RGBA(hex: 0x2F5E63) }

    /// Timeline chrome drawn by the Metal canvas (RGBA, same values as the SwiftUI tokens above). Clip colours and
    /// waveforms are functional coding (above / `ValseOptions.clipColors`); white overlays on clips stay neutral.
    public enum TL {
        public static let background = RGBA(hex: 0x1C1A17)     // panel
        public static let laneMain = RGBA(hex: 0x22201D)       // trackMain
        public static let lane = RGBA(hex: 0x1E1C19)
        public static let header = RGBA(hex: 0x201E1B)
        public static let headerChip = RGBA(hex: 0x2A2723)
        public static let headerText = RGBA(hex: 0xF1EBDD)
        public static let scrollThumb = RGBA(hex: 0x3A3631)
        public static let tick = RGBA(hex: 0x5A544C)
        public static let rulerText = RGBA(hex: 0x8F877A)
        public static let emptyText = RGBA(hex: 0xC9C1B2)
        public static let accent = RGBA(hex: 0x2BAF90)         // teal: drop targets, snap, in / out, selection marks
        public static func accent(_ alpha: Double) -> RGBA { RGBA(hex: 0x2BAF90, alpha: alpha) }
        /// Playhead and selected-clip frame: warm cream instead of pure white (reads on every clip colour).
        public static let playhead = RGBA(hex: 0xF3E9C8)
        public static let selection = RGBA(hex: 0xF3E9C8)
    }

    // Metrics (pt)
    public enum Metrics {
        public static let titleBarHeight: CGFloat = 36
        public static let outerGutter: CGFloat = 8
        public static let gutter: CGFloat = 6
        public static let panelHeader: CGFloat = 42
        public static let panelRadius: CGFloat = 8
        public static let buttonRadius: CGFloat = 6
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

    /// Valse brand tokens (rename preview, VALSE-HOME). Used on the Home screen only for now; the editor keeps the tokens
    /// above until the owner validates the direction (mapping in the VALSE-HOME report). Neutrals are warm charcoal (never
    /// navy, never tinted enough to bias footage); the 80s palette comes from the logo and is used as accent + stripe motif.
    public enum Valse {
        // Brand palette (logo)
        public static let teal = Color(hex: 0x2BAF90)       // functional accent: selection, focus, active (6.9:1 on canvas)
        public static let mint = Color(hex: 0xA1D4B1)       // accent text on dark / hover highlight of teal
        public static let mustard = Color(hex: 0xF1A512)    // brand highlight: primary call to action
        public static let orange = Color(hex: 0xDD4111)     // stripe motif only (4.3:1, not for small text)
        public static let burgundy = Color(hex: 0x8C0027)   // film edges of the stripe motif only
        public static let cream = Color(hex: 0xF3E9C8)      // wordmark
        public static let ink = Color(hex: 0x14110C)        // text on teal / mustard fills (6.2:1 / 8.9:1)
        // Warm neutrals (dark → light)
        public static let canvas = Color(hex: 0x121110)     // window / Home background
        public static let sidebar = Color(hex: 0x161513)
        public static let surface = Color(hex: 0x1C1A17)    // cards, hero
        public static let raised = Color(hex: 0x24211D)     // hover / selected surface
        public static let control = Color(hex: 0x2A2723)    // fields, segmented controls, secondary buttons
        public static let controlHover = Color(hex: 0x34302B)
        public static let stroke = Color(hex: 0x2E2A25)     // hairlines, card borders
        // Text (contrast on canvas / control)
        public static let text = Color(hex: 0xF1EBDD)       // 15.9 / 12.5
        public static let text2 = Color(hex: 0xBDB5A6)      // 9.3 / 7.3
        public static let text3 = Color(hex: 0x958D80)      // 5.8 / 4.5
        // Selection
        public static let selectedFill = Color(hex: 0x2BAF90, alpha: 0.14)
        /// Stripe order of the ribbon, outside → centre (mirrored on the other side).
        public static let bands: [Color] = [burgundy, mustard, orange, teal]

        public enum Radius {
            public static let control: CGFloat = 7
            public static let card: CGFloat = 10
            public static let hero: CGFloat = 14
        }

        /// Display = SF Rounded (echoes the ribbon's round turns), body = SF Pro.
        public enum Fonts {
            public static let wordmark = Font.system(size: 19, weight: .bold, design: .rounded)
            public static let pageTitle = Font.system(size: 20, weight: .bold, design: .rounded)
            public static let heroTitle = Font.system(size: 22, weight: .bold, design: .rounded)
            public static let cardTitle = Font.system(size: 14, weight: .semibold)
            public static let body = Font.system(size: 13)
            public static let caption = Font.system(size: 11.5)
            public static let overline = Font.system(size: 10.5, weight: .semibold)
        }
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
