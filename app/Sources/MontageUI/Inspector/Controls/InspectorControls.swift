import SwiftUI
import AppKit
import MontageCore
import Perception

/// Inspector design tokens not in `Theme` (sampled from CapCut 9.6 screenshots, UX.md §1.2 / §5).
enum IStyle {
    static let label = Color(hex: 0xDCDCDC)
    static let caption = Color(hex: 0x8C8C8C)
    static let track = Color(hex: 0x4A4A4A)
    static let field = Color(hex: 0x121212)
    static let dropdown = Color(hex: 0x2F2F31)
    static let tile = Color(hex: 0x3A3A3A)
    static let strip = Color(hex: 0x353535)
    static let icon = Color(hex: 0xC8C8C8)
    static let iconDim = Color(hex: 0x6A6A6A)
    static let warning = Color(hex: 0xE8B33A)
    static let curve = Color(hex: 0xF2C230)
    static let graph = Color(hex: 0x0F0F0F)
    static let rowHeight: CGFloat = 36
    static let labelWidth: CGFloat = 104
    static let fieldWidth: CGFloat = 56
    static let tripletWidth: CGFloat = 44
}

// MARK: - Slider

/// Maps a value to the slider's 0…1 position. Linear by default; log / piecewise scales for speed and volume.
struct SliderScale {
    var toUnit: (Double) -> Double
    var fromUnit: (Double) -> Double
    static func linear(_ r: ClosedRange<Double>) -> SliderScale {
        let span = max(r.upperBound - r.lowerBound, 1e-12)
        return SliderScale(toUnit: { ($0 - r.lowerBound) / span }, fromUnit: { r.lowerBound + $0 * span })
    }
    /// Piecewise-logarithmic through `stops` placed at equal spacing (CapCut speed slider: 0.1, 1, 2, 5, 10, 100).
    static func piecewiseLog(_ stops: [Double], positions: [Double]) -> SliderScale {
        SliderScale(toUnit: { v in
            let v = min(max(v, stops.first!), stops.last!)
            for i in 0..<(stops.count - 1) where v <= stops[i + 1] {
                let t = (log(v) - log(stops[i])) / (log(stops[i + 1]) - log(stops[i]))
                return positions[i] + t * (positions[i + 1] - positions[i])
            }
            return 1
        }, fromUnit: { u in
            let u = min(max(u, 0), 1)
            for i in 0..<(stops.count - 1) where u <= positions[i + 1] {
                let t = (u - positions[i]) / max(positions[i + 1] - positions[i], 1e-12)
                return exp(log(stops[i]) + t * (log(stops[i + 1]) - log(stops[i])))
            }
            return stops.last!
        })
    }
}

/// CapCut slider: 2 pt track, white fill from the origin to the knob, white 8×14 rounded knob (UX.md §5 "Rows").
/// Bipolar parameters fill from their centre; colour parameters show a gradient track instead of a fill.
/// The whole drag reports begin → change… → end so callers coalesce it into one undo step.
struct InspectorSlider: View {
    let unit: Double
    var originUnit: Double = 0
    var gradient: [Color]? = nil
    var ticks: [Double] = []
    var enabled = true
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var dragging = false
    /// Knob position while dragging: the knob follows the pointer even when the store's value reaches the view
    /// later (the inspector refreshes at most every 100 ms during canvas/timeline gestures, see EditorStore).
    @State private var liveUnit: Double?

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { g in
                WithPerceptionTracking {
                    let knobW: CGFloat = 8
                    let w = max(g.size.width - knobW, 1)
                    let u = CGFloat(min(max(liveUnit ?? unit, 0), 1))
                    let o = CGFloat(min(max(originUnit, 0), 1))
                    ZStack(alignment: .leading) {
                        if let gradient {
                            Capsule().fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                                .frame(height: 2).padding(.horizontal, knobW / 2)
                        } else {
                            Capsule().fill(IStyle.track).frame(height: 2).padding(.horizontal, knobW / 2)
                            Rectangle().fill(Color.white)
                                .frame(width: abs(u - o) * w, height: 2)
                                .offset(x: knobW / 2 + min(u, o) * w)
                        }
                        ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                            WithPerceptionTracking {
                                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1, height: 8)
                                    .offset(x: knobW / 2 + CGFloat(t) * w - 0.5)
                            }
                        }
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.white)
                            .frame(width: knobW, height: 14)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                            .offset(x: u * w)
                    }
                    .frame(height: g.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard enabled else { return }
                            if !dragging { dragging = true; onBegin() }
                            let nu = Double(min(max((v.location.x - knobW / 2) / w, 0), 1))
                            liveUnit = nu
                            onChange(nu)
                        }
                        .onEnded { _ in
                            guard dragging else { return }
                            dragging = false; liveUnit = nil; onEnd()
                        })
                }
            }
            .frame(height: 20)
            .opacity(enabled ? 1 : 0.35)
            .allowsHitTesting(enabled)
        }
    }
}

// MARK: - Numeric field + stepper

/// Dark inset field holding the formatted value (unit inside, e.g. "100%") with an up/down stepper button on its right.
/// Typing + Enter commits; Escape or focus loss reverts. Each stepper click is one undoable step.
struct NumericField: View {
    let display: String
    var prefix: String? = nil
    var prefixSymbol: String? = nil
    var width: CGFloat = IStyle.fieldWidth
    var enabled = true
    let parse: (String) -> Double?
    let commit: (Double) -> Void
    let step: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    /// OB-11: ↑ / ↓ registration while focused (`NumericFieldKeys`).
    @State private var keyToken = UUID()

    /// ↑ / ↓ press: drops any half-typed text (the field then shows the stepped value) and steps the model value.
    private func keyStep(_ d: Int) {
        text = display
        step(d)
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    if let prefix { Text(verbatim: prefix).font(.system(size: 12)).foregroundStyle(IStyle.caption) }
                    if let prefixSymbol { Image(systemName: prefixSymbol).font(.system(size: 10)).foregroundStyle(IStyle.caption) }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(Theme.Fonts.numeric)
                        // Perf (W14 round 2): while unfocused the value is drawn by the overlay `Text` and the AppKit
                        // field's string is left alone — setting it re-measured the NSTextField through Auto Layout and
                        // re-laid out the whole inspector on every slider tick.
                        .foregroundStyle(focused ? Theme.textPrimary : Color.clear)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .overlay {
                            if !focused {
                                Text(verbatim: display).font(Theme.Fonts.numeric).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).allowsHitTesting(false)
                            }
                        }
                        .onSubmit {
                            if let v = parse(text) { commit(v) }
                            text = display
                        }
                        .onExitCommand { text = display; focused = false }
                }
                .padding(.horizontal, 6)
                .frame(width: width, height: 24)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                StepperButton(enabled: enabled, step: step)
            }
            .opacity(enabled ? 1 : 0.35)
            .disabled(!enabled)
            .onAppear { text = display }
            // also while focused when the field still shows the previous value (after ⏎ the commit re-renders `display`)
            .onValueChange(of: display) { old, v in
                if focused && text == old { text = v }
                if focused { NumericFieldKeys.update(keyToken, step: keyStep) }
            }
            .onValueChange(of: focused) { _, f in
                text = display
                if f && enabled { NumericFieldKeys.focus(keyToken, step: keyStep) } else { NumericFieldKeys.blur(keyToken) }
            }
            .onDisappear { NumericFieldKeys.blur(keyToken) }
        }
    }
}

/// The ⇕ button next to numeric fields (two halves). FB-09: each half is a full rectangle hit target (no gap between
/// them, the whole half clicks, not only the chevron glyph); Settings uses the larger `width` / `halfHeight`.
struct StepperButton: View {
    var enabled = true
    var width: CGFloat = 14
    var halfHeight: CGFloat = 12
    /// Test ids `<testID>.up` / `<testID>.down` when set.
    var testID: String?
    let step: (Int) -> Void
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                half(+1, "chevron.up", "up")
                half(-1, "chevron.down", "down")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .background(Theme.stepper, in: RoundedRectangle(cornerRadius: 4))
            .disabled(!enabled)
        }
    }

    @ViewBuilder private func half(_ d: Int, _ symbol: String, _ suffix: String) -> some View {
        let b = Button { step(d) } label: {
            Image(systemName: symbol).font(.system(size: halfHeight > 12 ? 8 : 7, weight: .bold))
                .frame(width: width, height: halfHeight).contentShape(Rectangle())
        }
        if let testID { b.testID("\(testID).\(suffix)") } else { b }
    }
}

enum NumberParse {
    /// Accepts "12", "-3.5", "1,5" (French decimal comma), with or without unit suffix.
    nonisolated static func number(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "\u{2212}", with: "-")
            .filter { "0123456789.-".contains($0) }
        return Double(cleaned)
    }
}

// MARK: - Keyframe triplet

/// ‹ ◇ › — previous keyframe / add-remove keyframe at playhead / next keyframe, over a group of properties.
/// Its own view so that only it re-renders when the playhead moves.
struct KeyframeTriplet: View {
    let ctx: InspectorContext
    let keys: [ParamKey]
    var enabled = true

    /// What the triplet shows. Perf (W14): the outer view re-evaluates on every edit of the clip (cheap); the buttons
    /// (with tooltips) re-render only when this changes. Actions recompute from the store at tap time.
    struct Model: Equatable {
        var active = false, on = false, has = false
        var prev: Time?, next: Time?
    }

    var body: some View {
        WithPerceptionTracking {
            let clip = ctx.clip
            let tol = ctx.keyframeTolerance
            let local = ctx.localTime
            var m = Model()
            m.active = enabled && !keys.isEmpty && clip != nil
            if m.active, let clip {
                m.on = clip.isOnKeyframe(keys, at: local, tolerance: tol)
                m.has = clip.hasKeyframes(keys)
                m.prev = clip.previousKeyframe(keys, before: local, tolerance: tol)
                m.next = clip.nextKeyframe(keys, after: local, tolerance: tol)
            }
            return KeyframeTripletButtons(ctx: ctx, keys: keys, m: m).equatable()
        }
    }
}

struct KeyframeTripletButtons: View, Equatable {
    let ctx: InspectorContext
    let keys: [ParamKey]
    let m: KeyframeTriplet.Model

    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { a.m == b.m && a.keys == b.keys } }

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let ctx = self.ctx
            HStack(spacing: 1) {
                Button { if let prev = m.prev, let clip = ctx.clip { store.seek(to: clip.start + prev) } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .medium)).frame(width: 12, height: 20).contentShape(Rectangle())
                }
                .disabled(m.prev == nil)
                .foregroundStyle(m.prev == nil ? IStyle.iconDim.opacity(0.6) : IStyle.icon)
                .accessibilityLabel(Text(verbatim: tr("ax.keyframe.previous")))   // SE-017
                Button {
                    guard let clip = ctx.clip else { return }
                    let keys = self.keys, local = ctx.localTime, tol = ctx.keyframeTolerance
                    let on = clip.isOnKeyframe(keys, at: local, tolerance: tol)
                    store.perform(UpdateClip(clip.id, nameKey: on ? "cmd.keyframe.remove" : "cmd.keyframe.add") {
                        $0.toggleKeyframes(keys, at: local, tolerance: tol)
                    })
                } label: {
                    Image(systemName: m.on ? "diamond.fill" : "diamond")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(m.on ? Theme.accent : (m.active ? (m.has ? Color.white : IStyle.icon) : IStyle.iconDim.opacity(0.6)))
                        .frame(width: 16, height: 20).contentShape(Rectangle())
                }
                .disabled(!m.active)
                .help(tr(m.on ? "inspector.keyframe.remove" : "inspector.keyframe.add"))
                .accessibilityLabel(Text(verbatim: tr(m.on ? "inspector.keyframe.remove" : "inspector.keyframe.add")))
                .testID("keyframe.toggle." + keys.map(\.raw).joined(separator: "+"))   // UI scripts (C3b)
                Button { if let next = m.next, let clip = ctx.clip { store.seek(to: clip.start + next) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).frame(width: 12, height: 20).contentShape(Rectangle())
                }
                .disabled(m.next == nil)
                .foregroundStyle(m.next == nil ? IStyle.iconDim.opacity(0.6) : IStyle.icon)
                .accessibilityLabel(Text(verbatim: tr("ax.keyframe.next")))
            }
            .buttonStyle(.plain)
            .frame(width: IStyle.tripletWidth)
        }
    }
}

// MARK: - Rows

/// Perf (W14): a slider row re-renders only when what it shows changes. During a drag of one slider every other row of
/// the inspector gets new closures (non-comparable) but the same values; comparing the displayed values lets SwiftUI
/// skip their bodies and layout. `unit` changes with the exact value, so captured values in closures stay current;
/// the keyframe triplet and accessories observe the store themselves and update independently.
extension SliderRowView: Equatable {
    nonisolated static func == (a: SliderRowView, b: SliderRowView) -> Bool {
        MainActor.assumeIsolated {
            a.label == b.label && a.unit == b.unit && a.originUnit == b.originUnit && a.display == b.display && a.enabled == b.enabled
                && a.ticks == b.ticks && a.gradient == b.gradient && a.testID == b.testID
                && (a.triplet == nil) == (b.triplet == nil) && (a.labelAccessory == nil) == (b.labelAccessory == nil)
        }
    }
}

/// `Label` on its own line, then `[──●──] [value][⇕] ‹◇›` (UX.md §5 "Rows").
struct SliderRowView: View {
    let label: String
    let unit: Double
    var originUnit: Double = 0
    var gradient: [Color]? = nil
    var ticks: [Double] = []
    let display: String
    var enabled = true
    var labelAccessory: AnyView? = nil
    let parse: (String) -> Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let commit: (Double) -> Void
    let step: (Int) -> Void
    var triplet: AnyView? = nil
    /// UI test ID of the slider (`slider.<ParamKey>`); the numeric field gets `<id>.field`. Default `slider.<label>`.
    var testID: String? = nil

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    if let labelAccessory { labelAccessory }
                }
                .opacity(enabled ? 1 : 0.4)
                HStack(spacing: 10) {
                    InspectorSlider(unit: unit, originUnit: originUnit, gradient: gradient, ticks: ticks, enabled: enabled,
                                    onBegin: onBegin, onChange: onChange, onEnd: onEnd)
                        .testID(testID ?? "slider.\(label)")
                    HStack(spacing: 2) {
                        NumericField(display: display, enabled: enabled, parse: parse, commit: commit, step: step)
                            .testID((testID ?? "slider.\(label)") + ".field")
                        if let triplet { triplet } else { Color.clear.frame(width: IStyle.tripletWidth, height: 1) }
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }
}

/// `Label ……… controls ……… ‹◇›` on one 36 pt line (Position, Rotate, Size, toggles).
struct InlineRow<Content: View>: View {
    let label: String
    var enabled = true
    var triplet: AnyView? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    .frame(width: IStyle.labelWidth, alignment: .leading)
                    .lineLimit(1)
                content()
                Spacer(minLength: 4)
                if let triplet { triplet }
            }
            .frame(minHeight: IStyle.rowHeight)
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)
        }
    }
}

/// Small grey group caption with a hairline under it ("Color", "Lightness", "Effects" in Adjust ▸ Basic).
struct GroupCaption: View {
    let title: String
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
            .padding(.top, 6)
        }
    }
}

struct HintText: View {
    let text: String
    var color: Color = IStyle.caption
    var body: some View {
        WithPerceptionTracking {
            Text(verbatim: text).font(Theme.Fonts.hint).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Toggle / checkbox

/// 36×20 switch: accent track + white knob when on, `#3D3D3D` when off (UX.md §1.4).
struct CapToggle: View {
    @Binding var isOn: Bool
    var enabled = true
    /// SE-017: what VoiceOver says (section headers pass their title through `SectionHeaderBar`).
    var label = ""

    var body: some View {
        WithPerceptionTracking {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.stepper).frame(width: 36, height: 20)
                Circle().fill(Color.white).frame(width: 14, height: 14).padding(.horizontal, 3)
            }
            .frame(width: 36, height: 20)
            .contentShape(Capsule())
            .onTapGesture { if enabled { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } }
            .opacity(enabled ? 1 : 0.4)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label.isEmpty ? tr("ax.switch") : label))
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(Text(verbatim: isOn ? "1" : "0"))
            .accessibilityAction { if enabled { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } }
        }
    }
}

struct ToggleLine: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var enabled = true
    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    if let detail { Text(verbatim: detail).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption) }
                }
                Spacer()
                CapToggle(isOn: $isOn, enabled: enabled)
            }
            .frame(minHeight: IStyle.rowHeight)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// 16 pt checkbox, radius 3, accent with a white check when on.
struct CapCheckbox: View {
    @Binding var isOn: Bool
    var enabled = true
    /// SE-017: what VoiceOver says (the section / option it switches on).
    var label = ""

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(isOn ? Theme.accent : Theme.stepper)
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { isOn.toggle() } }
            .opacity(enabled ? 1 : 0.4)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label.isEmpty ? tr("ax.checkbox") : label))
            .accessibilityValue(Text(verbatim: tr(isOn ? "ax.on" : "ax.off")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { isOn.toggle() } }
        }
    }
}

// MARK: - Dropdown

/// Full-width dropdown (`#2F2F31`, radius 4, chevron right) — Blend mode, Canvas, Ratio…
struct Dropdown<ID: Hashable>: View {
    let items: [(id: ID, title: String)]
    let selection: ID
    var enabled = true
    let onSelect: (ID) -> Void
    var body: some View {
        WithPerceptionTracking {
            // The visible field is drawn by us (borderless menus centre their label and put the chevron first);
            // a transparent Menu on top provides the native pop-up.
            HStack {
                Text(verbatim: items.first { $0.id == selection }?.title ?? "")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(IStyle.dropdown, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                Menu {
                    ForEach(items, id: \.id) { item in
                        WithPerceptionTracking {
                            Button {
                                onSelect(item.id)
                            } label: {
                                if item.id == selection { Label(item.title, systemImage: "checkmark") } else { Text(verbatim: item.title) }
                            }
                        }
                    }
                } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .opacity(0.011)
                .accessibilityLabel(Text(verbatim: items.first { $0.id == selection }?.title ?? tr("ax.menu")))   // SE-017
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

// MARK: - Tiles

/// 62×62 tile with a caption under it; selected = 2 pt accent border (shape grids, presets, animations).
struct Tile<Content: View>: View {
    let title: String
    var selected = false
    var enabled = true
    var size: CGFloat = 62
    var testID: String? = nil
    /// Caption lines (animation tiles use 2 so long — e.g. French — names stay readable, UX_GAPS W5-3).
    var titleLines = 1
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        WithPerceptionTracking {
            Button { if enabled { action() } } label: { label }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .onHover { hover = $0 }
                .opacity(enabled ? 1 : 0.4)
                .accessibilityLabel(Text(verbatim: title))
                .testID(testID ?? "tile.\(title)")
        }
    }

    private var label: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(IStyle.tile)
                content()
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : (hover ? Color.white.opacity(0.25) : .clear),
                                                                   lineWidth: selected ? 2 : 1))
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(titleLines).truncationMode(.middle).multilineTextAlignment(.center)
                .frame(width: size + 10, height: titleLines > 1 ? 28 : nil, alignment: .top)
        }
        .contentShape(Rectangle())
    }
}

/// Wrapping grid of tiles (6 per row at the default inspector width).
struct TileGrid<Content: View>: View {
    var tileSize: CGFloat = 62
    @ViewBuilder let content: () -> Content
    var body: some View {
        WithPerceptionTracking {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize + 10, maximum: tileSize + 22), spacing: 6, alignment: .top)],
                      alignment: .leading, spacing: 10, content: content)
        }
    }
}

// MARK: - Rotation dial

/// Small circular knob (22 pt): the white tick points at the angle (0° = 3 o'clock, clockwise). Drag to rotate freely.
struct RotationDial: View {
    let degrees: Double
    var enabled = true
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var dragging = false
    @State private var lastAngle = 0.0
    @State private var accumulated = 0.0

    var body: some View {
        WithPerceptionTracking {
            let r = degrees * .pi / 180
            ZStack {
                Circle().stroke(Color(hex: 0x9A9A9A), lineWidth: 1.5)
                Path { p in
                    p.move(to: CGPoint(x: 11 + cos(r) * 2, y: 11 + sin(r) * 2))
                    p.addLine(to: CGPoint(x: 11 + cos(r) * 6.5, y: 11 + sin(r) * 6.5))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: 11 + cos(r) * 10, y: 11 + sin(r) * 10))
                    p.addLine(to: CGPoint(x: 11 + cos(r) * 12, y: 11 + sin(r) * 12))
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle().inset(by: -6))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard enabled else { return }
                    let a = atan2(v.location.y - 11, v.location.x - 11) * 180 / .pi
                    if !dragging { dragging = true; lastAngle = a; accumulated = degrees; onBegin() }
                    var d = a - lastAngle
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                    lastAngle = a; accumulated += d
                    onChange(min(max(accumulated, -360), 360))
                }
                .onEnded { _ in if dragging { dragging = false; onEnd() } })
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

// MARK: - Icon button

struct SmallIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var enabled = true
    var size: CGFloat = 12
    let action: () -> Void
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: size))
                    .foregroundStyle(active ? Theme.accent : (enabled ? IStyle.icon : IStyle.iconDim.opacity(0.6)))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(Text(verbatim: help))   // SE-017
        }
    }
}

/// Pill button ("+ Add mask", "Apply to all"…).
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var accent = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                    Text(verbatim: title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 26)
                .background(accent ? Theme.accent : Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

/// Colour swatch that opens the system colour panel (no SwiftUI ColorPicker chrome). With `eyedropper`, an eyedropper
/// button before the swatch picks the colour from the video with the canvas loupe (CL-024).
struct ColorSwatchButton: View {
    let color: RGBA
    var size: CGFloat = 22
    var eyedropper: EditorStore? = nil
    var testID: String = "color"
    let onChange: (RGBA) -> Void
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                if let store = eyedropper {
                    SmallIconButton(symbol: "eyedropper", help: tr("color.eyedropper.help"), active: store.canvasEyedropper != nil, size: 12) {
                        if store.canvasEyedropper != nil { store.endCanvasColorPick(); return }
                        let keepAlpha = color.a
                        store.pickCanvasColor { c in var c = c; c.a = keepAlpha; onChange(c) }
                    }
                    .testID("\(testID).eyedropper")
                }
                ColorPicker(tr("ax.color"), selection: Binding.perceived(get: { Color(color) }, set: { c in
                    if let ns = NSColor(c).usingColorSpace(.sRGB) {
                        onChange(RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent)))
                    }
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: size + 18, height: size)
            }
        }
    }
}
