import SwiftUI
import Observation
import MontageCore
import MontageEffects
import MontageEngine

/// Inspector UI state that must survive re-renders and selection changes: active sub-tab per tab, collapsed sections.
@Observable
final class InspectorUIState {
    static let shared = InspectorUIState()
    var subTab: [String: String] = [:]
    var expanded: [String: Bool] = [:]
    /// Clips whose "Uniform scale" toggle the user turned off.
    var nonUniform: Set<ClipID> = []
    /// Optional sections the user unchecked (CapCut keeps the checkbox state per clip).
    var blendOff: Set<ClipID> = []
    var canvasOff: Set<ClipID> = []
    /// Last crop ratio picked per clip (display only).
    var cropRatio: [ClipID: String] = [:]
    /// Selected beat in the speed-curve editor.
    var curvePoint: [ClipID: Int] = [:]
    /// Animation tab search text.
    var animationSearch = ""
    /// Mask size aspect-lock chain.
    var maskLock = false
    func isExpanded(_ id: String, default d: Bool) -> Bool { expanded[id] ?? d }
}

/// Top-right inspector (UX.md §5): header tabs for the selection (or "Details"), optional sub-tab segmented control,
/// the registered sections of the active (sub-)tab, and an optional sticky footer.
public struct InspectorPanel: View {
    @Bindable var store: EditorStore
    private let ui = InspectorUIState.shared
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        let ctx = InspectorContext(store: store)
        let tabs = InspectorRegistry.tabs(for: ctx)
        let active = tabs.first { $0.id == store.inspectorTab } ?? tabs.first
        let subs = active.map { InspectorRegistry.subTabs(of: $0, ctx: ctx) } ?? []
        let sub: InspectorSubTab? = subs.isEmpty ? nil : (subs.first { $0.id == ui.subTab[active!.id] } ?? subs.first)
        Panel {
            HStack(spacing: 22) {
                ForEach(tabs) { tab in
                    Text(loc: tab.titleKey)
                        .font(Theme.Fonts.panelTitle)
                        .foregroundStyle(tab.id == active?.id ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .contentShape(Rectangle())
                        .onTapGesture { store.inspectorTab = tab.id }
                        .accessibilityAddTraits(.isButton)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        } content: {
            VStack(spacing: 0) {
                if let active {
                    if subs.count >= 2, let sub {
                        SubTabBar(items: subs.map { ($0.id, tr($0.titleKey)) }, selection: sub.id) { ui.subTab[active.id] = $0 }
                            .padding(.horizontal, Theme.Metrics.inspectorPadding)
                            .padding(.top, 12).padding(.bottom, 10)
                        Rectangle().fill(Theme.separator).frame(height: 2).padding(.horizontal, Theme.Metrics.inspectorPadding)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(InspectorRegistry.sections(tab: active, subTab: subs.count >= 2 ? sub?.id : nil, ctx: ctx)) { section in
                                InspectorSectionView(section: section, ctx: ctx, ui: ui)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .id("\(store.selection.hashValue)-\(store.selectedTransition?.description ?? "")-\(active.id)-\(sub?.id ?? "")")
                    if let footer = active.footer?(ctx, sub?.id) {
                        HStack(spacing: 8) { Spacer(); footer }
                            .padding(.horizontal, Theme.Metrics.inspectorPadding)
                            .frame(height: 46)
                            .frame(maxWidth: .infinity)
                            .background(Theme.panelHeader)
                    }
                }
            }
        }
    }
}

/// Segmented sub-tab control (28 pt, inset track `#121212`, raised `#3A3A3A` pill).
struct SubTabBar: View {
    let items: [(id: String, title: String)]
    let selection: String
    let onSelect: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.id) { item in
                Text(verbatim: item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selection == item.id ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(selection == item.id ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(item.id) }
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(1)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct InspectorSectionView: View {
    let section: InspectorSection
    let ctx: InspectorContext
    @Bindable var ui: InspectorUIState

    var body: some View {
        let chrome = section.chrome?(ctx)
        let isOn = chrome?.isEnabled?.wrappedValue ?? true
        let expanded = ui.isExpanded(section.id, default: !(chrome?.startsCollapsed ?? false))
        let disabled = chrome?.disabledReason != nil
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.titleKey {
                SectionHeaderBar(title: tr(title), chrome: chrome, expanded: expanded && isOn, ctx: ctx) {
                    withAnimation(.easeOut(duration: 0.15)) { ui.expanded[section.id] = !expanded }
                }
            }
            if let reason = chrome?.disabledReason { HintText(text: reason) }
            if section.titleKey == nil || (expanded && isOn) {
                section.content(ctx)
                    .disabled(disabled)
                    .opacity(disabled ? 0.45 : 1)
            }
        }
        .padding(.horizontal, Theme.Metrics.inspectorPadding)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, Theme.Metrics.inspectorPadding)
        }
    }
}

/// `[☐] Title ▾ (subtitle) … [accessory] [↺] ‹◇›`
struct SectionHeaderBar: View {
    let title: String
    let chrome: InspectorSectionChrome?
    let expanded: Bool
    let ctx: InspectorContext
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let b = chrome?.isEnabled {
                CapCheckbox(isOn: Binding(get: { b.wrappedValue }, set: { v in
                    b.wrappedValue = v
                }), enabled: chrome?.disabledReason == nil)
            }
            HStack(spacing: 6) {
                Text(verbatim: title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let s = chrome?.subtitle { Text(verbatim: s).font(.system(size: 12)).foregroundStyle(IStyle.caption).lineLimit(1) }
                Image(systemName: expanded ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 7)).foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            Spacer(minLength: 4)
            if let a = chrome?.accessory { a }
            if let reset = chrome?.reset {
                SmallIconButton(symbol: "arrow.counterclockwise", help: tr("inspector.reset"), enabled: chrome?.disabledReason == nil,
                                size: 13, action: reset)
            }
            if let keys = chrome?.keyframeKeys { KeyframeTriplet(ctx: ctx, keys: keys, enabled: chrome?.disabledReason == nil) }
        }
        .frame(minHeight: 26)
    }
}

// MARK: - Binding helpers

/// How a numeric row maps, formats and parses its value (UI units).
struct RowSpec {
    var range: ClosedRange<Double>
    var scale: SliderScale? = nil
    /// Bipolar origin (the fill starts here), e.g. 0 for −50…50.
    var origin: Double? = nil
    var gradient: [Color]? = nil
    var ticks: [Double] = []
    var step: Double = 1
    /// Typing may exceed the slider range (e.g. scale up to 1000 %).
    var fieldRange: ClosedRange<Double>? = nil
    var format: (Double) -> String
    var parse: (String) -> Double? = NumberParse.number

    var sliderScale: SliderScale { scale ?? .linear(range) }
    func clampField(_ v: Double) -> Double { let r = fieldRange ?? range; return min(max(v, r.lowerBound), r.upperBound) }
    func clampSlider(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

/// Numeric row bound to the selected clip. Evaluates in its own body, so only this row re-renders when its value
/// (or, for keyframed properties, the playhead) changes. Slider drags are one coalesced undo step with live preview;
/// field commits and stepper clicks are single steps.
struct ClipParamRow: View {
    let ctx: InspectorContext
    let label: String
    let spec: RowSpec
    /// UI value at clip-local time.
    let get: (Clip, Time) -> Double
    let set: (inout Clip, Double, Time) -> Void
    /// Whether the value depends on the playhead (keyframed) — avoids observing the playhead otherwise.
    var dependsOnTime: (Clip) -> Bool = { _ in false }
    /// Keys of the row's ‹◇› (nil = none, [] = greyed placeholder like CapCut's fade rows).
    var keyframeKeys: [ParamKey]? = nil
    var gestureName = "cmd.editClip"
    var enabled = true
    var labelAccessory: AnyView? = nil

    var body: some View {
        let store = ctx.store
        let clip = ctx.clip
        let local = clip.map { dependsOnTime($0) ? ctx.localTime : .zero } ?? .zero
        let value = clip.map { get($0, local) } ?? spec.range.lowerBound
        let scale = spec.sliderScale
        let id = clip?.id
        let spec = self.spec, set = self.set, name = gestureName
        func write(_ v: Double) {
            guard let id else { return }
            Bind.apply(store, id, name) { c in set(&c, v, Bind.local(store, c)) }
        }
        return SliderRowView(
            label: label, unit: scale.toUnit(spec.clampSlider(value)),
            originUnit: spec.origin.map { scale.toUnit($0) } ?? 0, gradient: spec.gradient, ticks: spec.ticks,
            display: spec.format(value), enabled: enabled && clip != nil, labelAccessory: labelAccessory, parse: spec.parse,
            onBegin: { store.beginGesture(name) },
            onChange: { u in write(spec.clampSlider(scale.fromUnit(u))) },
            onEnd: { store.endGesture() },
            commit: { v in write(spec.clampField(v)) },
            step: { d in write(spec.clampField(value + Double(d) * spec.step)) },
            triplet: keyframeKeys.map { AnyView(KeyframeTriplet(ctx: ctx, keys: $0, enabled: !$0.isEmpty)) })
    }
}

/// Inline numeric field (+ stepper) bound to the selected clip — Position X/Y, Rotate, mask Size.
struct ClipNumberField: View {
    let ctx: InspectorContext
    var prefix: String? = nil
    var prefixSymbol: String? = nil
    var width: CGFloat = IStyle.fieldWidth
    let spec: RowSpec
    let get: (Clip, Time) -> Double
    let set: (inout Clip, Double, Time) -> Void
    var dependsOnTime: (Clip) -> Bool = { _ in false }
    var gestureName = "cmd.editClip"
    var body: some View {
        let store = ctx.store
        let clip = ctx.clip
        let local = clip.map { dependsOnTime($0) ? ctx.localTime : .zero } ?? .zero
        let value = clip.map { get($0, local) } ?? 0
        let spec = self.spec, set = self.set, name = gestureName
        func write(_ v: Double) {
            guard let id = clip?.id else { return }
            Bind.apply(store, id, name) { c in set(&c, v, Bind.local(store, c)) }
        }
        return NumericField(display: spec.format(value), prefix: prefix, prefixSymbol: prefixSymbol, width: width,
                            enabled: clip != nil, parse: spec.parse,
                            commit: { write(spec.clampField($0)) }, step: { write(spec.clampField(value + Double($0) * spec.step)) })
    }
}

/// Helpers to bind inspector controls to clip properties with gesture coalescing and CapCut keyframe semantics.
@MainActor
enum Bind {
    /// Clip-local playhead.
    static func local(_ store: EditorStore, _ c: Clip) -> Time { (store.transport.playhead - c.start).clamped(.zero, c.duration) }

    /// Row on component `component` of an animatable property (CapCut semantics: keyframed → keyframe at playhead).
    static func row(_ ctx: InspectorContext, _ label: String, key: ParamKey, component: Int = 0, spec: RowSpec,
                    toUI: @escaping (Double) -> Double = { $0 }, fromUI: @escaping (Double) -> Double = { $0 },
                    keyframes: Bool = true, gestureName: String = "cmd.editClip", enabled: Bool = true) -> ClipParamRow {
        ClipParamRow(ctx: ctx, label: label, spec: spec,
                     get: { c, t in toUI(c.value(key, at: t)?.component(component) ?? 0) },
                     set: { c, v, t in c.modifyValue(key, at: t) { $0 = $0.with(component: component, fromUI(v)) } },
                     dependsOnTime: { $0.hasKeyframes(key) },
                     keyframeKeys: keyframes ? [key] : nil, gestureName: gestureName, enabled: enabled)
    }

    /// Inline field on one component of an animatable property.
    static func field(_ ctx: InspectorContext, key: ParamKey, component: Int = 0, prefix: String? = nil, prefixSymbol: String? = nil,
                      spec: RowSpec, toUI: @escaping (Double) -> Double = { $0 }, fromUI: @escaping (Double) -> Double = { $0 },
                      gestureName: String = "cmd.editClip") -> ClipNumberField {
        ClipNumberField(ctx: ctx, prefix: prefix, prefixSymbol: prefixSymbol, spec: spec,
                        get: { c, t in toUI(c.value(key, at: t)?.component(component) ?? 0) },
                        set: { c, v, t in c.modifyValue(key, at: t) { $0 = $0.with(component: component, fromUI(v)) } },
                        dependsOnTime: { $0.hasKeyframes(key) }, gestureName: gestureName)
    }

    static func triplet(_ ctx: InspectorContext, _ keys: [ParamKey]) -> AnyView { AnyView(KeyframeTriplet(ctx: ctx, keys: keys)) }

    /// Applies an edit to one clip: inside a gesture it updates live, otherwise it is one undoable command.
    static func apply(_ store: EditorStore, _ id: ClipID, _ name: String, _ body: @escaping (inout Clip) -> Void) {
        let box = UncheckedSendable(body)  // runs synchronously on the main actor inside perform/updateGesture
        if store.session.isInGesture {
            store.updateGesture { p in if var c = p.timeline.clip(id) { box.value(&c); p.timeline[clip: id] = c } }
        } else {
            store.perform(UpdateClip(id, nameKey: name) { box.value(&$0) })
        }
    }

    /// Binding on a clip value for toggles / pickers (each change = one undo step).
    static func binding<V>(_ ctx: InspectorContext, _ name: String, get: @escaping (Clip) -> V, set: @escaping (inout Clip, V) -> Void,
                           default d: V) -> Binding<V> {
        let store = ctx.store
        let id = ctx.clip?.id
        return Binding(get: { id.flatMap { store.project.timeline.clip($0) }.map(get) ?? d },
                       set: { v in if let id { apply(store, id, name) { set(&$0, v) } } })
    }
}

enum Fmt {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func percentValue(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func degrees(_ v: Double) -> String { String(format: "%.2f°", v) }
    static func degrees1(_ v: Double) -> String { String(format: "%.1f°", v) }
    static func seconds(_ v: Double) -> String { String(format: "%.1fs", v) }
    static func speed(_ v: Double) -> String { String(format: "%.2fx", v) }
    static func db(_ gain: Double) -> String {
        let d = AudioProps.decibels(gain)
        return d.isFinite ? String(format: "%.1fdB", d) : "-∞dB"
    }
    static func int(_ v: Double) -> String { "\(Int(v.rounded()))" }
    /// "01:00" / "41s" style used by the speed panels.
    static func clock(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
