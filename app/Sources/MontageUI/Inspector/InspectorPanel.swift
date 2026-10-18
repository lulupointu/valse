import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine

/// Top-right inspector: header tabs for the selection (or "Details"), then the registered sections of the active tab.
public struct InspectorPanel: View {
    @Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        let ctx = InspectorContext(store: store)
        let tabs = InspectorRegistry.tabs(for: ctx)
        let active = tabs.first { $0.id == store.inspectorTab } ?? tabs.first
        Panel {
            HStack(spacing: 18) {
                ForEach(tabs) { tab in
                    Text(loc: tab.titleKey)
                        .font(Theme.Fonts.panelTitle)
                        .foregroundStyle(tab.id == active?.id ? Theme.accent : Theme.textSecondary)
                        .onTapGesture { store.inspectorTab = tab.id }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let active {
                        ForEach(InspectorRegistry.sections(tab: active.id, ctx: ctx)) { section in
                            InspectorSectionView(section: section, ctx: ctx)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            // Re-evaluate keyframe diamonds as the playhead moves.
            .id(store.selection.hashValue)
        }
    }
}

struct InspectorSectionView: View {
    let section: InspectorSection
    let ctx: InspectorContext
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            if let title = section.titleKey {
                SectionHeader(tr(title), expanded: $expanded)
            }
            if expanded || section.titleKey == nil {
                section.content(ctx)
            }
        }
        .padding(.horizontal, Theme.Metrics.inspectorPadding)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

/// Helpers to bind inspector controls to clip properties with gesture coalescing and CapCut keyframe semantics.
@MainActor
enum Bind {
    /// Slider on a scalar animatable property of the selected clip.
    static func slider(_ ctx: InspectorContext, _ label: String, key: ParamKey, range: ClosedRange<Double>,
                       display: @escaping (Double) -> String, toUI: @escaping (Double) -> Double = { $0 },
                       fromUI: @escaping (Double) -> Double = { $0 }, gestureName: String = "cmd.editClip",
                       keyframes: Bool = true) -> SliderRow {
        let store = ctx.store
        let id = ctx.clip?.id
        return SliderRow(label, range: range, display: display, keyframe: keyframes ? keyframeState(ctx, key) : nil,
                         get: {
                             guard let id, let c = store.project.timeline.clip(id) else { return range.lowerBound }
                             let local = (store.transport.playhead - c.start).clamped(.zero, c.duration)
                             return toUI(c.value(key, at: local)?.scalar ?? 0)
                         },
                         set: { v in
                             guard let id else { return }
                             apply(store, id, gestureName) { c in
                                 let local = (store.transport.playhead - c.start).clamped(.zero, c.duration)
                                 c.setValue(key, .scalar(fromUI(v)), at: local)
                             }
                         },
                         onBegin: { store.beginGesture(gestureName) }, onEnd: { store.endGesture() })
    }

    /// Slider on an arbitrary clip value (not animatable).
    static func value(_ ctx: InspectorContext, _ label: String, range: ClosedRange<Double>, display: @escaping (Double) -> String,
                      gestureName: String = "cmd.editClip", get: @escaping (Clip) -> Double, set: @escaping (inout Clip, Double) -> Void) -> SliderRow {
        let store = ctx.store
        let id = ctx.clip?.id
        return SliderRow(label, range: range, display: display,
                         get: { id.flatMap { store.project.timeline.clip($0) }.map(get) ?? range.lowerBound },
                         set: { v in if let id { apply(store, id, gestureName) { set(&$0, v) } } },
                         onBegin: { store.beginGesture(gestureName) }, onEnd: { store.endGesture() })
    }

    static func apply(_ store: EditorStore, _ id: ClipID, _ name: String, _ body: @escaping (inout Clip) -> Void) {
        let box = UncheckedSendable(body)  // runs synchronously on the main actor inside perform/updateGesture
        if store.session.isInGesture {
            store.updateGesture { p in if var c = p.timeline.clip(id) { box.value(&c); p.timeline[clip: id] = c } }
        } else {
            store.perform(UpdateClip(id, nameKey: name) { box.value(&$0) })
        }
    }

    static func keyframeState(_ ctx: InspectorContext, _ key: ParamKey) -> KeyframeButton.State? {
        guard let clip = ctx.clip else { return nil }
        let store = ctx.store
        let local = ctx.localTime
        let tol = store.project.settings.frameRate.frameDuration / 2.0
        let track = clip.keyframes[key.raw]
        let on = track?.index(near: local, tolerance: tol) != nil
        let prev = track?.keyframes.last { $0.time < local - tol }
        let next = track?.keyframes.first { $0.time > local + tol }
        let start = clip.start
        return KeyframeButton.State(
            isOnKeyframe: on, hasKeyframes: !(track?.isEmpty ?? true),
            toggle: { store.perform(UpdateClip(clip.id, nameKey: "cmd.keyframe") { $0.toggleKeyframe(key, at: local, tolerance: tol) }) },
            previous: prev.map { k in { store.seek(to: start + k.time) } },
            next: next.map { k in { store.seek(to: start + k.time) } })
    }
}

enum Fmt {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func degrees(_ v: Double) -> String { String(format: "%.1f°", v) }
    static func seconds(_ v: Double) -> String { String(format: "%.1fs", v) }
    static func speed(_ v: Double) -> String { String(format: "%.2fx", v) }
    static func db(_ gain: Double) -> String {
        let d = AudioProps.decibels(gain)
        return d.isFinite ? String(format: "%.1fdB", d) : "-∞dB"
    }
    static func int(_ v: Double) -> String { "\(Int(v.rounded()))" }
}
