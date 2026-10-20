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
                    .tint(.white)
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
                        .foregroundStyle(state.isOnKeyframe ? Theme.accent : Theme.textSecondary)
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
                            .font(.system(size: 12, weight: selection == item.id ? .medium : .regular))
                            .foregroundStyle(selection == item.id ? Theme.textPrimary : Theme.textTertiary)
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

public struct AccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
    }
}

public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Theme.buttonSecondary.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
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
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(active ? Theme.accent : Theme.textPrimary.opacity(enabled ? 0.85 : 0.3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(Text(verbatim: help))   // SE-017: icon-only buttons speak their tooltip
            .accessibilityAddTraits(active ? .isSelected : [])
        }
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
