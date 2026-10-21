import SwiftUI
import Perception
import MontageCore

/// Editor layouts (SE-005, CapCut menu ▸ Layout): presets that set the panel proportions (and, for Vertical, a
/// full-height player column for 9:16 work), three custom slots that remember the current proportions, and "Reset
/// current layout". The splitters edit the current layout; everything persists in UserDefaults (not in UI tests).
public enum EditorLayoutPreset: String, CaseIterable, Codable, Sendable {
    case standard, media, player, timeline, attributes, vertical
    public var nameKey: String { "layout.\(rawValue)" }

    /// Default proportions: (top row height, asset panel width, inspector width) as window fractions.
    var defaults: EditorLayout.Fractions {
        switch self {
        case .standard: return .init(top: 0.54, left: 0.34, right: 0.31)
        case .media: return .init(top: 0.6, left: 0.45, right: 0.25)
        case .player: return .init(top: 0.64, left: 0.22, right: 0.22)
        case .timeline: return .init(top: 0.38, left: 0.3, right: 0.28)
        case .attributes: return .init(top: 0.58, left: 0.26, right: 0.42)
        case .vertical: return .init(top: 0.5, left: 0.5, right: 0.34)   // right = player column width
        }
    }
}

@MainActor @Perceptible
public final class EditorLayout {
    public static let shared = EditorLayout()
    static let defaultsKey = "montage.editor.layout"

    public struct Fractions: Codable, Equatable, Sendable {
        public var top: Double, left: Double, right: Double
    }
    struct Stored: Codable { var preset: EditorLayoutPreset; var fractions: Fractions; var custom: [Int: Stored.Slot]
        struct Slot: Codable { var preset: EditorLayoutPreset; var fractions: Fractions }
    }

    public private(set) var preset: EditorLayoutPreset = .standard
    public var fractions = EditorLayoutPreset.standard.defaults { didSet { save() } }
    /// Custom layouts 1–3 (nil = empty slot).
    private(set) var custom: [Int: Stored.Slot] = [:]
    /// Panels in their own window (SE-006); the player's flag mirrors `PlayerUIState.isDetached`. Session only.
    public var detached: Set<DetachablePanel> = []
    /// Index of the custom slot last applied (checkmark in the menu).
    public private(set) var activeCustom: Int?

    init() {
        guard !HomeSandbox.isActive, let d = AppDefaults.store.data(forKey: Self.defaultsKey),
              let s = try? JSONDecoder().decode(Stored.self, from: d) else { return }
        preset = s.preset; custom = s.custom; fractions = s.fractions
    }

    public func apply(_ p: EditorLayoutPreset) {
        preset = p; activeCustom = nil
        fractions = p.defaults
    }

    /// "Reset current layout": back to the preset's proportions.
    public func reset() { fractions = preset.defaults }

    public func saveCustom(_ i: Int) {
        custom[i] = Stored.Slot(preset: preset, fractions: fractions); activeCustom = i; save()
    }

    public func applyCustom(_ i: Int) {
        guard let s = custom[i] else { return }
        preset = s.preset; fractions = s.fractions; activeCustom = i
    }

    private func save() {
        guard !HomeSandbox.isActive else { return }
        if let d = try? JSONEncoder().encode(Stored(preset: preset, fractions: fractions, custom: custom)) {
            AppDefaults.store.set(d, forKey: Self.defaultsKey)
        }
    }

    /// Test/state dump.
    var dump: [String: Any] {
        ["preset": preset.rawValue, "top": fractions.top, "left": fractions.left, "right": fractions.right,
         "custom": custom.keys.sorted(), "activeCustom": activeCustom as Any,
         "detached": detached.map(\.rawValue).sorted()]
    }
}

/// Title-bar layout button (UX.md §1.1: icon + chevron) with the same entries as View ▸ Layout.
struct LayoutMenuButton: View {
    @Perception.Bindable var layout = EditorLayout.shared
    var body: some View {
        WithPerceptionTracking {
            Menu {
                ForEach(EditorLayoutPreset.allCases, id: \.self) { p in
                    WithPerceptionTracking {
                        Button { layout.apply(p) } label: {
                            if layout.preset == p && layout.activeCustom == nil { Label(tr(p.nameKey), systemImage: "checkmark") } else { Text(verbatim: tr(p.nameKey)) }
                        }
                    }
                }
                Divider()
                ForEach(1...3, id: \.self) { i in
                    WithPerceptionTracking {
                        if layout.custom[i] != nil {
                            Button(tr("layout.custom", i)) { layout.applyCustom(i) }
                        }
                    }
                }
                Menu(tr("layout.saveCustom")) {
                    ForEach(1...3, id: \.self) { i in WithPerceptionTracking { Button(tr("layout.custom", i)) { layout.saveCustom(i) } } }
                }
                Button(tr("layout.reset")) { layout.reset() }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: layout.preset == .vertical ? "rectangle.split.2x1" : "rectangle.split.3x1")
                        .font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .foregroundStyle(Theme.textSecondary)
            .help(tr("layout.title"))
            .testID("titlebar.layout")
        }
    }
}
