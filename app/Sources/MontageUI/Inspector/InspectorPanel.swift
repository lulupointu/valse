import SwiftUI
import Perception
import MontageCore
import MontageEffects
import MontageEngine

/// Inspector UI state that must survive re-renders and selection changes: active sub-tab per tab, collapsed sections.
@Perceptible
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
    /// Mask being edited per clip (MK-005: 1…4, Video ▸ Mask chips).
    var maskIndex: [ClipID: Int] = [:]
    func isExpanded(_ id: String, default d: Bool) -> Bool { expanded[id] ?? d }
}

/// Top-right inspector (UX.md §5): header tabs for the selection (or "Details"), optional sub-tab segmented control,
/// the registered sections of the active (sub-)tab, and an optional sticky footer.
public struct InspectorPanel: View {
    @Perception.Bindable var store: EditorStore
    private let ui = InspectorUIState.shared
    public init(store: EditorStore) { self.store = store }

    /// What the panel shows (tabs, active tab's sub-tabs, sections, footer) for the current selection.
    struct Structure {
        let ctx: InspectorContext
        let tabs: [InspectorTab]
        let active: InspectorTab?
        let subs: [InspectorSubTab]
        let sub: InspectorSubTab?
        let sections: [InspectorSection]
        let footer: AnyView?
        var key: Int {
            var h = Hasher()
            for t in tabs { h.combine(t.id) }
            h.combine(active?.id); h.combine(sub?.id)
            for t in subs { h.combine(t.id) }
            for x in sections { h.combine(x.id) }
            h.combine(footer != nil)
            return h.finalize()
        }
    }

    static func structure(_ store: EditorStore) -> Structure {
        let ui = InspectorUIState.shared
        let ctx = InspectorContext(store: store)
        let tabs = InspectorRegistry.tabs(for: ctx)
        let active = tabs.first { $0.id == store.inspectorTab } ?? tabs.first
        let subs = active.map { InspectorRegistry.subTabs(of: $0, ctx: ctx) } ?? []
        let sub: InspectorSubTab? = subs.isEmpty ? nil : (subs.first { $0.id == ui.subTab[active!.id] } ?? subs.first)
        let sections = active.map { InspectorRegistry.sections(tab: $0, subTab: subs.count >= 2 ? sub?.id : nil, ctx: ctx) } ?? []
        let footer = active.flatMap { $0.footer?(ctx, sub?.id) }
        return Structure(ctx: ctx, tabs: tabs, active: active, subs: subs, sub: sub, sections: sections, footer: footer)
    }

    /// Perf (W14): the panel's structure is computed without observing the project (every slider tick replaces it); the
    /// panel depends on `store.inspectorStructureKey` instead, which changes only when tabs / sections / footer change.
    /// Sections still observe the project themselves, so their values stay live.
    public var body: some View {
        WithPerceptionTracking {
            let _ = (store.inspectorStructureKey, store.inspectorTab, ui.subTab)
            let st = EditorStore.untracked { Self.structure(store) }
            let ctx = st.ctx, tabs = st.tabs, active = st.active, subs = st.subs, sub = st.sub
            Panel {
                HStack(spacing: 22) {
                    ForEach(tabs) { tab in
                        WithPerceptionTracking {
                            // a Button (not onTapGesture) so the UI test driver's synthetic clicks reach it
                            Button { store.inspectorTab = tab.id } label: {
                                Text(loc: tab.titleKey)
                                    .font(Theme.Fonts.panelTitle)
                                    .foregroundStyle(tab.id == active?.id ? Theme.accent : Theme.textPrimary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .testID("inspector.tab.\(tab.id)")
                        }
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
                                ForEach(st.sections) { section in
                                    WithPerceptionTracking {
                                        InspectorSectionView(section: section, ctx: ctx, ui: ui).testID("inspector.section.\(section.id)")
                                    }
                                }
                            }
                            .padding(.bottom, 16)
                        }
                        .id("\(store.selection.hashValue)-\(store.selectedTransition?.description ?? "")-\(active.id)-\(sub?.id ?? "")")
                        if let footer = st.footer {
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
}

/// Segmented sub-tab control (28 pt, inset track `#121212`, raised `#3A3A3A` pill).
struct SubTabBar: View {
    let items: [(id: String, title: String)]
    let selection: String
    let onSelect: (String) -> Void
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    WithPerceptionTracking {
                        Button { onSelect(item.id) } label: {
                            Text(verbatim: item.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(selection == item.id ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(selection == item.id ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .testID("inspector.sub.\(item.id)")
                    }
                }
            }
            .padding(1)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct InspectorSectionView: View {
    let section: InspectorSection
    let ctx: InspectorContext
    @Perception.Bindable var ui: InspectorUIState

    /// Perf (W14 round 2): the chrome / content builders run untracked — many read `store.project`, which would
    /// re-render every section on every edit tick. The section depends on the selection slices instead (its clip,
    /// track kind, media, settings); child views (rows, toggles) still observe what they read themselves.
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let _ = (store.selectedClipSlice, store.selectedTrackKindSlice, store.mediaBin, store.projectSettings, store.canUndo, store.canRedo)
            return EditorStore.untracked { content }
        }
    }

    @ViewBuilder private var content: some View {
        let chrome = section.chrome?(ctx)
        let isOn = chrome?.isEnabled?.wrappedValue ?? true
        // C2: ▼ always expands, also while the option is off (CapCut shows its settings; ticking applies it). An
        // unticked option starts collapsed; ticking it expands it unless the user collapsed it.
        let expanded = ui.isExpanded(section.id, default: isOn && !(chrome?.startsCollapsed ?? false))
        let disabled = chrome?.disabledReason != nil
        let id = section.id, ui = self.ui
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.titleKey {
                SectionHeaderBar(title: tr(title), chrome: chrome, expanded: expanded, ctx: ctx, checkID: "inspector.check.\(section.id)",
                                 toggle: { withAnimation(.easeOut(duration: 0.15)) { ui.expanded[id] = !expanded } },
                                 onCheck: { on in if on, ui.expanded[id] == false { ui.expanded[id] = true } })
            }
            if let reason = chrome?.disabledReason { HintText(text: reason) }
            if section.titleKey == nil || expanded {
                section.content(ctx)
                    .disabled(disabled)
                    .opacity(disabled ? 0.45 : 1)
                    .testID("inspector.section.\(id).body")
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
    /// Test ID of the enable checkbox (F3: UI scripts tick optional sections directly).
    var checkID: String? = nil
    let toggle: () -> Void
    /// Called after the checkbox changes (the panel re-expands a section the user collapsed when it gets ticked).
    var onCheck: ((Bool) -> Void)? = nil

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                if let b = chrome?.isEnabled {
                    CapCheckbox(isOn: Binding.perceived(get: { b.wrappedValue }, set: { v in
                        b.wrappedValue = v
                        onCheck?(v)
                    }), enabled: chrome?.disabledReason == nil, label: title)
                    .testID(checkID ?? "inspector.check")
                }
                HStack(spacing: 6) {
                    Text(verbatim: title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let s = chrome?.subtitle { Text(verbatim: s).font(.system(size: 12)).foregroundStyle(IStyle.caption).lineLimit(1) }
                    Image(systemName: expanded ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7)).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                // SE-017: the title expands / collapses the section with VoiceOver too
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(Text(verbatim: tr(expanded ? "ax.expanded" : "ax.collapsed")))
                .accessibilityAction { toggle() }
                Spacer(minLength: 4)
                if let a = chrome?.accessory { a.accessibilityLabel(Text(verbatim: title)) }   // SE-017: header switch speaks the section
                if let reset = chrome?.reset {
                    SmallIconButton(symbol: "arrow.counterclockwise", help: tr("inspector.reset"), enabled: chrome?.disabledReason == nil,
                                    size: 13, action: reset)
                }
                if let keys = chrome?.keyframeKeys { KeyframeTriplet(ctx: ctx, keys: keys, enabled: chrome?.disabledReason == nil) }
            }
            .frame(minHeight: 26)
        }
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
    var testID: String? = nil
    /// Value shown while this row's slider is dragged: the inspector's clip slice is frozen during the drag
    /// (`EditorStore.beginInspectorGesture`), so only this row re-renders per tick.
    @State private var live: Double?

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let clip = ctx.clip
            let local = clip.map { dependsOnTime($0) ? ctx.localTime : .zero } ?? .zero
            let value = live ?? (clip.map { get($0, local) } ?? spec.range.lowerBound)
            // C2: several clips edited together → "-" when they disagree
            let mixed = live == nil && ctx.isMulti
                && InspectorMultiEdit.isMixed(ctx.clips.map { get($0, dependsOnTime($0) ? Bind.local(store, $0) : .zero) })
            let liveBox = $live
            let scale = spec.sliderScale
            let id = clip?.id
            let spec = self.spec, set = self.set, name = gestureName
            @MainActor func write(_ v: Double) {
                guard let id else { return }
                Bind.apply(store, id, name) { c in set(&c, v, Bind.local(store, c)) }
            }
            return SliderRowView(
                label: label, unit: scale.toUnit(spec.clampSlider(value)),
                originUnit: spec.origin.map { scale.toUnit($0) } ?? 0, gradient: spec.gradient, ticks: spec.ticks,
                display: mixed ? InspectorMultiEdit.mixedText : spec.format(value), enabled: enabled && clip != nil,
                labelAccessory: labelAccessory, parse: spec.parse,
                onBegin: { store.beginInspectorGesture(name) },
                onChange: { u in let v = spec.clampSlider(scale.fromUnit(u)); liveBox.wrappedValue = v; write(v) },
                onEnd: { liveBox.wrappedValue = nil; store.endGesture() },
                commit: { v in write(spec.clampField(v)) },
                step: { d in write(spec.clampField(value + Double(d) * spec.step)) },
                triplet: keyframeKeys.map { AnyView(KeyframeTriplet(ctx: ctx, keys: $0, enabled: !$0.isEmpty)) }, testID: testID)
                .equatable()
        }
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
        WithPerceptionTracking {
            let store = ctx.store
            let clip = ctx.clip
            let local = clip.map { dependsOnTime($0) ? ctx.localTime : .zero } ?? .zero
            let value = clip.map { get($0, local) } ?? 0
            let spec = self.spec, set = self.set, name = gestureName
            let mixed = ctx.isMulti
                && InspectorMultiEdit.isMixed(ctx.clips.map { get($0, dependsOnTime($0) ? Bind.local(store, $0) : .zero) })
            @MainActor func write(_ v: Double) {
                guard let id = clip?.id else { return }
                Bind.apply(store, id, name) { c in set(&c, v, Bind.local(store, c)) }
            }
            return NumericField(display: mixed ? InspectorMultiEdit.mixedText : spec.format(value), prefix: prefix, prefixSymbol: prefixSymbol, width: width,
                                enabled: clip != nil, parse: spec.parse,
                                commit: { write(spec.clampField($0)) }, step: { write(spec.clampField(value + Double($0) * spec.step)) })
        }
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
                     keyframeKeys: keyframes ? [key] : nil, gestureName: gestureName, enabled: enabled,
                     testID: "slider.\(key.raw)" + (component == 0 ? "" : ".\(component)"))
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

    /// Applies an edit to one clip: inside a gesture it updates live, otherwise it is one undoable command. With a
    /// same-kind multi-selection it applies to every selected clip (C2, `InspectorMultiEdit`).
    static func apply(_ store: EditorStore, _ id: ClipID, _ name: String, _ body: @escaping (inout Clip) -> Void) {
        let box = UncheckedSendable(body)  // runs synchronously on the main actor inside perform/updateGesture
        if store.session.isInGesture {
            let ids = store.inspectorTargets(id)
            store.updateGesture { p in for id in ids { if var c = p.timeline.clip(id) { box.value(&c); p.timeline[clip: id] = c } } }
        } else {
            store.performInspector(UpdateClip(id, nameKey: name) { box.value(&$0) })
        }
    }

    /// Binding on a clip value for toggles / pickers (each change = one undo step).
    static func binding<V>(_ ctx: InspectorContext, _ name: String, get: @escaping (Clip) -> V, set: @escaping (inout Clip, V) -> Void,
                           default d: V) -> Binding<V> {
        let store = ctx.store
        let id = ctx.clip?.id
        return Binding.perceived(get: {
            // the selected clip comes from its slice (no observation of every project edit)
            if let s = store.selectedClipSlice, s.id == id { return get(s) }
            return id.flatMap { store.project.timeline.clip($0) }.map(get) ?? d
        },
                       set: { v in if let id { apply(store, id, name) { set(&$0, v) } } })
    }
}

/// Inspector number formats in the UI language (W3-3): "0,00°", "1,00×", "5,0 s", "−6,0 dB" in French;
/// "0.00°", "1.00×", "5.0s", "−6.0dB" in English (CapCut's English spacing). Typed values are parsed by `NumberParse`.
enum Fmt {
    static var isFrench: Bool { L10n.shared.language.hasPrefix("fr") }
    /// Fixed-decimals number in the UI locale (no grouping), true minus sign, no "−0".
    static func num(_ v: Double, _ places: Int) -> String {
        let s = String(format: "%.\(places)f", locale: L10n.shared.locale, v)
        let isZero = !s.contains { "123456789".contains($0) }
        return isZero ? s.replacingOccurrences(of: "-", with: "") : s.replacingOccurrences(of: "-", with: "\u{2212}")
    }
    /// Value + unit: a narrow no-break space before the unit in French, none in English.
    static func unit(_ n: String, _ u: String) -> String { isFrench ? n + "\u{202F}" + u : n + u }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func percentValue(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func degrees(_ v: Double) -> String { num(v, 2) + "°" }
    static func degrees1(_ v: Double) -> String { num(v, 1) + "°" }
    static func seconds(_ v: Double) -> String { unit(num(v, 1), "s") }
    static func speed(_ v: Double) -> String { num(v, 2) + "×" }
    static func decibels(_ d: Double, places: Int = 1) -> String { unit(d.isFinite ? num(d, places) : "\u{2212}∞", "dB") }
    static func db(_ gain: Double) -> String { decibels(AudioProps.decibels(gain)) }
    static func int(_ v: Double) -> String { num(v.rounded(), 0) }
    /// "01:00" / "41s" style used by the speed panels.
    static func clock(_ seconds: Double) -> String {
        if seconds < 60 { return Fmt.seconds(seconds) }
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
