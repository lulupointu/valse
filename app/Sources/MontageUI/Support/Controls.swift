import SwiftUI
import MontageCore
import Perception

/// Panel container: 42 pt header strip (#303030) over a #1B1B1C body, radius 6 (UX.md §1.1).
public struct Panel<Header: View, Content: View>: View {
    let header: Header
    let content: Content
    public init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header(); self.content = content()
    }
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                header
                    .frame(height: Theme.Metrics.panelHeader)
                    .frame(maxWidth: .infinity)
                    .background(Theme.panelHeader)
                Rectangle().fill(Theme.headerSeparator).frame(height: 0.5)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius))
        }
    }
}

/// Section header: Title ▾ … [↺] [◇] (UX.md §5).
public struct SectionHeader: View {
    let title: String
    var onReset: (() -> Void)?
    @Binding var expanded: Bool
    public init(_ title: String, expanded: Binding<Bool>, onReset: (() -> Void)? = nil) {
        self.title = title; self._expanded = expanded; self.onReset = onReset
    }
    public var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Text(verbatim: title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let onReset {
                    Button(action: onReset) { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("inspector.reset"))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
        }
    }
}

/// Inspector slider row: label above, slider + numeric field + keyframe diamond (UX.md §5 "Rows").
/// Dragging updates the player live; the whole drag is one undo step.
public struct SliderRow: View {
    let label: String
    let range: ClosedRange<Double>
    let display: (Double) -> String
    let parse: (String) -> Double?
    let get: () -> Double
    let set: (Double) -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    var keyframe: KeyframeButton.State?
    /// UI test identifier (`slider.<param>`; the numeric field gets `<id>.field`). Defaults to `slider.<label>`.
    var testID: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    public init(_ label: String, range: ClosedRange<Double>, display: @escaping (Double) -> String,
                parse: @escaping (String) -> Double? = { Double($0.filter { "0123456789.-".contains($0) }) },
                keyframe: KeyframeButton.State? = nil, testID: String? = nil,
                get: @escaping () -> Double, set: @escaping (Double) -> Void,
                onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.label = label; self.range = range; self.display = display; self.parse = parse; self.keyframe = keyframe
        self.testID = testID
        self.get = get; self.set = set; self.onBegin = onBegin; self.onEnd = onEnd
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Slider(value: Binding.perceived(get: { min(max(get(), range.lowerBound), range.upperBound) }, set: { set($0) }), in: range) { editing in
                        editing ? onBegin() : onEnd()
                    }
                    .controlSize(.small)
                    .valseSliderTint()
                    .testID(testID ?? "slider.\(label)")
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(Theme.Fonts.numeric)
                        .multilineTextAlignment(.center)
                        .frame(width: 58, height: 24)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                        .focused($focused)
                        .testID((testID ?? "slider.\(label)") + ".field")
                        .onSubmit {
                            if let v = parse(text) { onBegin(); set(min(max(v, range.lowerBound), range.upperBound)); onEnd() }
                            text = display(get())
                        }
                    if let keyframe { KeyframeButton(state: keyframe) }
                }
            }
            .onAppear { text = display(get()) }
            .onValueChange(of: get()) { _, v in if !focused { text = display(v) } }
        }
    }
}

/// ‹ ◇ › keyframe triplet (diamond filled when the playhead is on a keyframe).
public struct KeyframeButton: View {
    public struct State {
        public var isOnKeyframe: Bool
        public var hasKeyframes: Bool
        public var toggle: () -> Void
        public var previous: (() -> Void)?
        public var next: (() -> Void)?
    }
    let state: State
    public var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 2) {
                Button { state.previous?() } label: { Image(systemName: "chevron.left").font(.system(size: 8)) }
                    .buttonStyle(.plain).opacity(state.previous == nil ? 0.3 : 0.8).disabled(state.previous == nil)
                Button(action: state.toggle) {
                    Image(systemName: state.isOnKeyframe ? "diamond.fill" : "diamond")
                        .font(.system(size: 10))
                        .foregroundStyle(state.isOnKeyframe ? Theme.toolActive : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("inspector.keyframe"))
                Button { state.next?() } label: { Image(systemName: "chevron.right").font(.system(size: 8)) }
                    .buttonStyle(.plain).opacity(state.next == nil ? 0.3 : 0.8).disabled(state.next == nil)
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Inset segmented control (track #121212, selected pill #3A3A3A).
public struct SegmentedTabs: View {
    let items: [(id: String, title: String)]
    @Binding var selection: String
    public init(_ items: [(id: String, title: String)], selection: Binding<String>) { self.items = items; self._selection = selection }
    public var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 2) {
                ForEach(items, id: \.id) { item in
                    WithPerceptionTracking {
                        Text(verbatim: item.title)
                            .font(.system(size: 12, weight: selection == item.id ? .semibold : .regular))
                            .foregroundStyle(selection == item.id ? Theme.accentText : Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(selection == item.id ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = item.id }
                    }
                }
            }
            .padding(2)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Primary action in the editor: teal fill with ink text (6.2:1; white on teal was 2.4:1), the hero "Custom" press
/// (springy 95 % squash, fill dimmed while held). Valse design/ui/STYLE_GUIDE.md §3–4.
public struct AccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ValseEditorButton(label: configuration.label, pressed: configuration.isPressed, kind: .primary)
    }
}

/// Secondary action: warm control fill, primary text; brighter on hover, same press as `AccentButtonStyle`.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ValseEditorButton(label: configuration.label, pressed: configuration.isPressed, kind: .secondary)
    }
}

/// The editor's Export button (title bar): the one brand call to action of the editor, mustard with ink (owner pick,
/// round 10), like Home's New project.
struct ValseExportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ValseEditorButton(label: configuration.label, pressed: configuration.isPressed, kind: .brand)
    }
}

/// Inline text action ("Use an existing file…", "Keep", "Change"): mint label, underlined while hovered, dimmed while
/// pressed. Replaces `.buttonStyle(.link)`, which draws in the system link blue and ignores the Valse tint.
struct ValseLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ValseLink(label: configuration.label, pressed: configuration.isPressed) }
}

private struct ValseLink<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        label
            .foregroundStyle(enabled ? Theme.accentText.opacity(pressed ? 0.6 : 1) : Theme.textTertiary)
            .underline(hover && enabled)
            .contentShape(Rectangle())
            .valseHover($hover)
    }
}

/// Full-width 32 pt dialog button (DialogFooter: Cancel / Save sharing the width).
struct ValseWideButtonStyle: ButtonStyle {
    let kind: ValseButtonKind
    func makeBody(configuration: Configuration) -> some View {
        ValseEditorButton(label: configuration.label, pressed: configuration.isPressed, kind: kind, height: 32, fontSize: 13,
                          expand: true)
    }
}

/// Editor-sized button body shared by the styles above. Press = `ValsePress` (Custom's spring 0.25 / 0.55, 95 %
/// squash, fill to 75 % / 85 %); hover = `.valseHover` (never sticks). Reduce Motion: no squash.
enum ValseButtonKind { case primary, secondary, brand, quiet }

struct ValseEditorButton<Label: View>: View {
    typealias Kind = ValseButtonKind
    let label: Label
    let pressed: Bool
    let kind: Kind
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    var minWidth: CGFloat? = nil
    var expand = false
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let hot = hover && enabled
        let fill: Color = switch kind {
        case .primary: Theme.accent.opacity(pressed ? 0.85 : 1)
        case .brand: Theme.Valse.mustard.opacity(pressed ? 0.85 : 1)
        case .secondary: (hot ? Theme.control : Theme.buttonSecondary).opacity(pressed ? ValsePress.fillOpacity : 1)
        case .quiet: (hot ? Theme.control : Theme.menu).opacity(pressed ? ValsePress.fillOpacity : 1)
        }
        let text: Color = switch kind {
        case .primary, .brand: Theme.onAccent
        case .secondary: Theme.textPrimary
        case .quiet: Theme.accentText
        }
        label
            .font(.system(size: fontSize, weight: kind == .secondary ? .regular : .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 12).frame(minWidth: minWidth, maxWidth: expand ? .infinity : nil).frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius)
                .strokeBorder(kind == .quiet ? Theme.separator : .clear))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? ValsePress.keyScale : 1)
            .animation(reduceMotion ? nil : .spring(response: ValsePress.response, dampingFraction: ValsePress.damping), value: pressed)
            .valseHover($hover)
    }
}

/// Monoline icon button with tooltip (timeline toolbar, player bar).
public struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var enabled = true
    let action: () -> Void
    public init(_ symbol: String, help: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.active = active; self.enabled = enabled; self.action = action
    }
    public var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: active ? .medium : .regular))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ValseIconButtonStyle(active: active))
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(Text(verbatim: help))   // SE-017: icon-only buttons speak their tooltip
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }
}

/// A tab's label (asset panel icon tabs, inspector tabs, Settings tabs). Selected = the Home sidebar's sticker
/// (owner pick, round 10): the same `.valseSticker` (spring 0.34 / 0.55, the sticker lifts 1 pt off a hard 3 pt teal
/// block), in the deeper editor mint with an ink label. Layout never changes with the state: same padding, same
/// weight, the sticker and its block are drawn as backgrounds (callers leave ≥ 3 pt around the label so nothing is
/// clipped), so selecting a tab never moves its neighbours. Hover brightens an idle label (no motion).
struct ValseTabLabel<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .foregroundStyle(active ? Theme.onAccent : (hover ? Theme.textPrimary : Theme.textPrimary.opacity(0.78)))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .valseSticker(active, radius: 6, fill: Theme.Valse.mintDeep)
            .valseHover($hover)
    }
}

/// Dense tool icons (timeline toolbar, player bar, title bar): the quiet key (owner pick, round 10; STYLE_GUIDE §4),
/// never a spring on these editing tools. Hover: a soft warm key fill fades in behind the glyph (120 ms) and the glyph
/// brightens; press: the fill deepens at once (no squash). Active / on = the one active token, mint (`Theme.toolActive`).
/// `VALSE_DEBUG_HOVER=tools` shows every tool icon hovered (review stills).
struct ValseIconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        ValseIconKey(label: configuration.label, pressed: configuration.isPressed, active: active)
    }
}

private struct ValseIconKey<Label: View>: View {
    let label: Label
    let pressed: Bool
    let active: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let hot = ValseDebugHover.merge(hover, "tools") && enabled
        let glyph: Color = !enabled ? Theme.textPrimary.opacity(0.3)
            : active ? Theme.toolActive
            : (hot ? Theme.textPrimary : Theme.textPrimary.opacity(0.82))
        label
            .foregroundStyle(glyph.opacity(pressed ? 0.75 : 1))
            .background(pressed && enabled ? Theme.control : (hot ? Theme.buttonSecondary : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
            .animation(ValseMotion.live(reduceMotion) ? .easeOut(duration: 0.12) : nil, value: hot)
            .valseHover($hover)
    }
}

/// Toggle row (36×20 accent switch).
public struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    public init(_ label: String, isOn: Binding<Bool>) { self.label = label; self._isOn = isOn }
    public var body: some View {
        WithPerceptionTracking {
            HStack {
                Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).tint(Theme.accent).labelsHidden()
            }
        }
    }
}

/// Labelled value row (Details).
public struct InfoRow: View {
    let label: String
    let value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    public var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                Text(verbatim: value).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }
}
