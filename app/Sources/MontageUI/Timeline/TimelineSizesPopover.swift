import SwiftUI
import Perception
import MontageCore

// TL-SIZE-TUNER: timeline toolbar "Sizes" button + in-window popover with live sliders for the lane sizes
// (`TimelineSizing`): video lane height, audio share of a video clip, audio lane height. App-wide preference, not in
// the project, not undoable.

/// Toolbar button: records its frame (the popover hangs from it) and shows the open state.
struct TimelineSizesButton: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            IconButton("arrow.up.and.down.square", help: tr("sizes.tooltip"), active: store.timelineUI.sizesOpen) {
                store.timelineUI.sizesOpen.toggle()
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { store.timelineUI.sizesButtonFrame = $0 }
            .testID("toolbar.sizes")
        }
    }
}

/// Hosts the popover in the editor window (EditorView overlay), above the button like Quick cut: a real NSPopover is a
/// separate window the offscreen UI tests can neither click nor snapshot. It stays open while the owner tunes (the
/// timeline under it stays usable); the button, its ✕ or Esc close it.
struct TimelineSizesOverlay: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            if store.timelineUI.sizesOpen {
                GeometryReader { g in
                    WithPerceptionTracking {
                        let o = g.frame(in: .global).origin
                        let b = store.timelineUI.sizesButtonFrame.offsetBy(dx: -o.x, dy: -o.y)
                        let w = TimelineSizesPopover.width
                        let x = min(max(8, (b.midX - w / 2).rounded(.down)), max(8, g.size.width - w - 8))
                        TimelineSizesPopover(prefs: TimelineSizingPrefs.shared) { store.timelineUI.sizesOpen = false }
                            .fixedSize()
                            .padding(.leading, x)
                            .frame(width: g.size.width, height: max(0, (b.minY - 4).rounded(.down)), alignment: .bottomLeading)
                    }
                }
            }
        }
    }
}

struct TimelineSizesPopover: View {
    @Perception.Bindable var prefs: TimelineSizingPrefs
    let close: () -> Void
    static let width: CGFloat = 300

    private func row(_ titleKey: String, value: String, unit: Double, id: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(loc: titleKey).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(verbatim: value).font(Theme.Fonts.row.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .testID(id + ".value")
            }
            InspectorSlider(unit: unit, onBegin: {}, onChange: set, onEnd: {})
                .accessibilityLabel(Text(loc: titleKey))
                .testID(id)
        }
    }

    private static func unit(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> Double { Double((v - r.lowerBound) / (r.upperBound - r.lowerBound)) }
    private static func value(_ u: Double, _ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + CGFloat(u) * (r.upperBound - r.lowerBound) }

    var body: some View {
        WithPerceptionTracking {
            let s = prefs.sizing
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(loc: "sizes.title").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(tr("sizes.close")).accessibilityLabel(Text(loc: "sizes.close"))
                    .testID("sizes.close")
                }
                row("sizes.video", value: tr("sizes.pt", Int(s.videoLaneHeight)),
                    unit: Self.unit(s.videoLaneHeight, TimelineSizing.videoRange), id: "sizes.video") { u in
                    var n = prefs.sizing; n.videoLaneHeight = Self.value(u, TimelineSizing.videoRange); prefs.set(n)
                }
                row("sizes.audioShare", value: tr("sizes.percent", Int((s.audioStripFraction * 100).rounded())),
                    unit: Self.unit(s.audioStripFraction, TimelineSizing.audioShareRange), id: "sizes.audioShare") { u in
                    var n = prefs.sizing; n.audioStripFraction = Self.value(u, TimelineSizing.audioShareRange); prefs.set(n)
                }
                row("sizes.audioLane", value: tr("sizes.pt", Int(s.audioLaneHeight)),
                    unit: Self.unit(s.audioLaneHeight, TimelineSizing.audioLaneRange), id: "sizes.audioLane") { u in
                    var n = prefs.sizing; n.audioLaneHeight = Self.value(u, TimelineSizing.audioLaneRange); prefs.set(n)
                }
                Text(verbatim: s.summary).font(Theme.Fonts.hint.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .testID("sizes.summary")
                Text(loc: "sizes.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(tr("sizes.reset")) { prefs.reset() }
                        .buttonStyle(.plain).font(Theme.Fonts.row).foregroundStyle(Theme.accent)
                        .opacity(s == .defaults ? 0.4 : 1).disabled(s == .defaults)
                        .testID("sizes.reset")
                }
            }
            .padding(14)
            .frame(width: Self.width, alignment: .leading)
            .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            .onExitCommand(perform: close)
            .testID("sizes.popover")
        }
    }
}
