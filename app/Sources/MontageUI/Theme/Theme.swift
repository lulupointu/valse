import SwiftUI
import AppKit
import MontageCore

/// Design tokens. Use these, never literal colours. Neutrals read the active `Chrome.p` palette (round 13,
/// temporary live switch in ValseOptions.swift); accents are constants. VALSE-APP: the CapCut greys and cyan of docs/UX.md §1.2–1.4 are
/// remapped to the Valse warm charcoal + teal (direction.md "editor remap", Valse design/ui/STYLE_GUIDE.md §2). Warm
/// neutrals keep their chroma low so they never bias footage; the viewer itself stays pure neutral black.
public enum Theme {
    // Backgrounds
    public static var window: Color { Color(hex: Chrome.p.window) }
    public static var home: Color { Color(hex: Chrome.p.home) }
    public static var panel: Color { Color(hex: Chrome.p.panel) }
    public static var panelHeader: Color { Color(hex: Chrome.p.panelHeader) }
    public static var inset: Color { Color(hex: Chrome.p.inset) }
    public static var control: Color { Color(hex: Chrome.p.control) }
    public static var buttonSecondary: Color { Color(hex: Chrome.p.buttonSecondary) }
    public static var stepper: Color { Color(hex: Chrome.p.stepper) }
    public static var segmentSelected: Color { Color(hex: Chrome.p.segmentSelected) }
    public static var trackMain: Color { Color(hex: Chrome.p.trackMain) }
    public static var menu: Color { Color(hex: Chrome.p.menu) }
    public static var separator: Color { Color(hex: Chrome.p.separator) }
    public static var headerSeparator: Color { Color(hex: Chrome.p.headerSeparator) }
    // Accent (Valse teal; anything drawn on an accent fill is `onAccent` ink, never white: 6.2:1 vs 2.4:1)
    public static let accent = Color(hex: 0x2BAF90)
    public static let accentDim = Color(hex: 0x1E5E4F)
    public static let onAccent = Color(hex: 0x14110C)
    /// Accent as text / glyph on dark surfaces (mint, 11:1): active tab labels, selected glyphs.
    public static let accentText = Color(hex: 0xA1D4B1)
    /// THE colour of every active / on tool or toggle icon in the app (magnet, linkage, preview axis, active tool,
    /// keyframe on…): mint. One token so toggles never disagree (owner, round 10).
    public static let toolActive = Color(hex: 0xA1D4B1)
    public static let toolActiveRGBA = RGBA(hex: 0xA1D4B1)
    // Semantic (Valse palette): hover ring on tiles (quiet, never coloured), favourites, warnings, errors, success
    public static let hoverRing = Color(hex: 0xF3E9C8, alpha: 0.45)
    public static let favorite = Color(hex: 0xF1A512)     // mustard
    public static let warning = Color(hex: 0xF1A512)      // mustard (text-safe: 8.9:1 as a fill under ink, 9:1 as text)
    public static let danger = Color(hex: 0xDD4111)       // orange: glyphs / borders; text uses `dangerText`
    public static let dangerText = Color(hex: 0xF0805A)   // light orange, 6.4:1 on panel
    public static let success = Color(hex: 0xA1D4B1)      // mint
    // Text
    public static var textPrimary: Color { Color(hex: Chrome.p.textPrimary) }
    public static var textSecondary: Color { Color(hex: Chrome.p.textSecondary) }
    public static var textTertiary: Color { Color(hex: Chrome.p.textTertiary) }
    public static var ruler: Color { Color(hex: Chrome.p.ruler) }

    // Timeline clip colours (as rendered). Owner pick (round 10): the Valse palette, toned down so clips sit calm
    // under the footage: deep teal, burgundy, terracotta, ochre, plum, sea green, olive (lightness × 0.84,
    // saturation × 0.74 of the round 9 option B). White clip labels stay ≥ 5:1 on every colour.
    public static func clipColor(_ kind: TrackKind) -> RGBA {
        switch kind {
        case .video: return RGBA(hex: 0x1E3F38)
        case .audio: return RGBA(hex: 0x3D212B)
        case .text: return RGBA(hex: 0x7B4832)
        case .sticker: return RGBA(hex: 0x866B36)
        case .effect: return RGBA(hex: 0x5F3345)
        case .filter: return RGBA(hex: 0x38544C)
        case .adjustment: return RGBA(hex: 0x685C39)
        }
    }
    public static let waveform = RGBA(hex: 0xBE745E)
    public static let waveformOnVideo = RGBA(hex: 0x2E5A50)

    /// Timeline chrome drawn by the Metal canvas (RGBA, same values as the SwiftUI tokens above). Clip colours and
    /// waveforms are functional coding (above); white overlays on clips stay neutral.
    public enum TL {
        public static var background: RGBA { RGBA(hex: Chrome.p.tlBackground) }     // panel
        public static var laneMain: RGBA { RGBA(hex: Chrome.p.tlLaneMain) }       // trackMain
        public static var lane: RGBA { RGBA(hex: Chrome.p.tlLane) }
        public static var header: RGBA { RGBA(hex: Chrome.p.tlHeader) }
        public static var headerChip: RGBA { RGBA(hex: Chrome.p.tlHeaderChip) }
        public static var headerText: RGBA { RGBA(hex: Chrome.p.textPrimary) }
        public static var scrollThumb: RGBA { RGBA(hex: Chrome.p.tlScrollThumb) }
        public static var tick: RGBA { RGBA(hex: Chrome.p.tlTick) }
        public static var rulerText: RGBA { RGBA(hex: Chrome.p.ruler) }
        public static var emptyText: RGBA { RGBA(hex: Chrome.p.emptyText) }
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
        /// Deeper mint for the editor's selection stickers (tabs): calmer than Home's mint, ink on it 7.9:1.
        public static let mintDeep = Color(hex: 0x7FB394)
        public static let mustard = Color(hex: 0xF1A512)    // brand highlight: primary call to action
        public static let orange = Color(hex: 0xDD4111)     // stripe motif only (4.3:1, not for small text)
        public static let burgundy = Color(hex: 0x8C0027)   // film edges of the stripe motif only
        public static let cream = Color(hex: 0xF3E9C8)      // wordmark
        public static let ink = Color(hex: 0x14110C)        // text on teal / mustard fills (6.2:1 / 8.9:1)
        // Warm neutrals (dark → light)
        public static var canvas: Color { Color(hex: Chrome.p.canvas) }     // window / Home background
        public static var sidebar: Color { Color(hex: Chrome.p.sidebar) }
        public static var surface: Color { Color(hex: Chrome.p.surface) }    // cards, hero
        public static var raised: Color { Color(hex: Chrome.p.raised) }     // hover / selected surface
        public static var control: Color { Color(hex: Chrome.p.vControl) }    // fields, segmented controls, secondary buttons
        public static var controlHover: Color { Color(hex: Chrome.p.vControlHover) }
        public static var stroke: Color { Color(hex: Chrome.p.stroke) }     // hairlines, card borders
        // Text (contrast on canvas / control)
        public static var text: Color { Color(hex: Chrome.p.textPrimary) }       // 15.9 / 12.5
        public static var text2: Color { Color(hex: Chrome.p.textSecondary) }      // 9.3 / 7.3
        public static var text3: Color { Color(hex: Chrome.p.textTertiary) }      // 5.8 / 4.5
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

extension View {
    /// Round 13: a SwiftUI popover's own surface (NSPopover's material, a cool neutral grey around #373738 that no
    /// token controls: the "too bright" grey the owner spotted) is painted with the chrome's menu fill, arrow included
    /// (the negative padding reaches under the arrow; the popover clips it to its shape).
    public func valsePopoverSurface() -> some View {
        background(Theme.menu.padding(-80))
    }
}

/// Round 13: the Valse text field (inset fill, hairline, radius 6) instead of the system rounded-border field, whose
/// bezel is a neutral grey no chrome palette reaches.
public struct ValseFieldStyle: TextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 6).frame(minHeight: 22)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator, lineWidth: 1))
    }
}
