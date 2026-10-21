import SwiftUI
import Metal
import MontageCore
import MontageEffects
import MontageEngine
import Perception

/// Asset panel ▸ Transitions (UX.md §3.8, [64]): category sub-nav, search, 86 pt tiles whose thumbnail is rendered by the
/// real shader (A → B sample pictures) and **plays the transition on hover**; ⊕ / double-click / drag onto a cut adds it
/// (default 0.5 s); clicking a tile while a transition is selected in the timeline replaces it (keeps the duration).
struct TransitionsTab: View {
    let store: EditorStore
    @State private var group = ""
    @State private var query = ""
    /// Last clicked tile (shows its ⊕ without hover, like CapCut's selected card).
    @State private var highlighted: String?

    /// "Trending" (CapCut's first category): a curated pick across groups.
    static let trending = ["dissolve", "pullIn", "whipLeft", "glitch", "lightLeak", "cubeLeft", "zoomBlur", "slideRight",
                           "inkWipe", "heart", "flash", "rgbSplit", "pageCurl", "swirl", "filmBurn", "mosaic"]
        .map { "montage.transition.\($0)" }
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        WithPerceptionTracking {
            let byGroup = BuiltinAssetTabs.grouped(Registries.transitions.all, \.groupKey)
            let nav: [(String, String)] = [(EffectLibraryCatalog.favoritesNav, tr("fxlib.favorites")), (EffectLibraryCatalog.curatedNav, tr("fxlib.trending"))]
                + byGroup.map { ($0.0, tr($0.0)) }
            let groups: [(String, [TransitionDescriptor])] = [
                (EffectLibraryCatalog.favoritesNav, Registries.transitions.all.filter { favorites.contains($0.id) }),
                (EffectLibraryCatalog.curatedNav, Self.trending.compactMap { Registries.transitions[$0] }),
            ] + byGroup
            let current = group.isEmpty ? EffectLibraryCatalog.curatedNav : group
            let title = current == EffectLibraryCatalog.favoritesNav ? tr("fxlib.favorites")
                : current == EffectLibraryCatalog.curatedNav ? tr("fxlib.trending") : tr(current)
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let items = q.isEmpty ? (groups.first { $0.0 == current }?.1 ?? [])
                : Registries.transitions.all.filter { tr($0.nameKey).lowercased().contains(q) || tr($0.groupKey).lowercased().contains(q) }
            let selectedType = store.selectedTransition.flatMap { store.project.timeline.clip($0)?.transitionOut?.typeID }
            HStack(spacing: 0) {
                // while searching no category is highlighted (results span all of them)
                SubNav(items: nav, selection: Binding.perceived(get: { q.isEmpty ? current : "" }, set: { group = $0; query = "" }))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField(tr("transitions.search"), text: $query).textFieldStyle(.plain).font(.system(size: 12))
                            .testID("transitions.search")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 12).padding(.top, 10)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: q.isEmpty ? title : tr("transitions.results"))
                                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                            if items.isEmpty { Text(loc: current == EffectLibraryCatalog.favoritesNav && q.isEmpty ? "fxlib.favorites.empty" : "transitions.noResults").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary) }
                            // UX.md §3.2: 86 pt squares, 16 pt gaps (4 per row at the default panel width)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 104), spacing: 16)], spacing: 12) {
                                ForEach(items) { d in
                                    WithPerceptionTracking {
                                        TransitionTile(descriptor: d, selected: selectedType == d.id, highlighted: highlighted == d.id,
                                                       add: { store.applyTransition(d) },
                                                       select: { highlighted = d.id; if store.selectedTransition != nil { store.applyTransition(d) } else { store.previewTransition(d) } })   // click = "Previewing — Transitions" (W13)
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

/// One transition card: still thumbnail, A → B loop on hover, ⊕ add button.
struct TransitionTile: View {
    let descriptor: TransitionDescriptor
    let selected: Bool
    var highlighted = false
    let add: () -> Void
    let select: () -> Void
    @State private var hover = false
    @State private var start = Date()

    var shortID: String { descriptor.id.replacingOccurrences(of: "montage.transition.", with: "") }

    var body: some View {
        WithPerceptionTracking {
            let thumbs = TransitionThumbnails.shared
            let _ = thumbs.revision
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Button(action: select) {
                        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !hover)) { tl in
                            WithPerceptionTracking {
                                picture(at: tl.date, thumbs)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected || highlighted ? Theme.accent : (hover ? Theme.accent.opacity(0.7) : .clear),
                                          lineWidth: selected ? 2 : 1.5))
                    }
                    .buttonStyle(.plain)
                    .testID("transition.tile.\(shortID)")
                    let fav = EffectFavorites.shared.contains(descriptor.id)
                    if hover || highlighted {
                        // UX.md §3.2: ☆ favourite + ⊕ add, bottom-right
                        HStack(spacing: 4) {
                            RoundBadge(symbol: fav ? "star.fill" : "star", tint: fav ? Color(hex: 0xF5C542) : .white, fill: Color.black.opacity(0.55),
                                       help: tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { EffectFavorites.shared.toggle(descriptor.id) }
                                .testID("transition.favorite.\(shortID)")
                            RoundBadge(symbol: "plus", tint: .white, fill: Theme.accent, help: tr("asset.addToTrack"), action: add)
                                .testID("transition.add.\(shortID)")
                        }
                        .padding(4)
                    } else if fav {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xF5C542)).padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                Text(verbatim: tr(descriptor.nameKey)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onHover { h in hover = h; if h { start = Date() } }
            .simultaneousGesture(TapGesture(count: 2).onEnded(add))
            .onDrag { NSItemProvider(object: DragPayload.transition(descriptor.id) as NSString) }
            .contextMenu {
                Button(tr(EffectFavorites.shared.contains(descriptor.id) ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { EffectFavorites.shared.toggle(descriptor.id) }
                Button(tr("asset.addToTrack"), action: add)
            }
            .help(tr(descriptor.nameKey))
        }
    }

    /// Hover: 1.2 s A → B then a 0.4 s hold on B, looping. Idle: the still at 40 %.
    @ViewBuilder func picture(at date: Date, _ thumbs: TransitionThumbnails) -> some View {
        if hover, let frames = thumbs.loop(descriptor), !frames.isEmpty {
            let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.6)
            let i = Int((min(t / 1.2, 1) * Double(frames.count - 1)).rounded())
            Image(decorative: frames[min(i, frames.count - 1)], scale: 2).resizable().interpolation(.medium)
        } else if let s = thumbs.still(descriptor) {
            Image(decorative: s, scale: 2).resizable().interpolation(.medium)
        } else {
            ZStack {
                Theme.segmentSelected
                Image(systemName: descriptor.symbol).font(.system(size: 24)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
        }
    }
}

/// Transition tile pictures, rendered off the main thread through the real transition shaders between two sample
/// pictures (`PresetPreviewRenderer`), cached for the session (a still ≈ 80 KB, a 20-frame loop ≈ 1.6 MB, loops are
/// only made for hovered tiles and the cache keeps the 24 most recent).
@MainActor @Perceptible final class TransitionThumbnails {
    static let shared = TransitionThumbnails()
    nonisolated static let px = 144
    nonisolated static let loopFrames = 20
    nonisolated static let samples = UncheckedSendable(PresetPreviewRenderer.sampleTextures(width: px, height: px))

    /// Bumped when a picture lands (tiles observe it).
    var revision = 0
    @PerceptionIgnored private var stills: [String: CGImage] = [:]
    @PerceptionIgnored private var loops: [String: [CGImage]] = [:]
    @PerceptionIgnored private var loopOrder: [String] = []
    @PerceptionIgnored private var pending: Set<String> = []
    @PerceptionIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @PerceptionIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    func still(_ d: TransitionDescriptor) -> CGImage? {
        if let s = stills[d.id] { return s }
        request(d, loop: false)
        return nil
    }

    func loop(_ d: TransitionDescriptor) -> [CGImage]? {
        if let l = loops[d.id] { return l }
        request(d, loop: true)
        return nil
    }

    private func request(_ d: TransitionDescriptor, loop: Bool) {
        let key = (loop ? "loop:" : "still:") + d.id
        guard !pending.contains(key) else { return }
        pending.insert(key)
        let n = Self.loopFrames, px = Self.px
        queue.addOperation {
            guard let (a, b) = Self.samples.value else {
                Task { @MainActor in TransitionThumbnails.shared.store([], for: d.id, loop: loop, key: key) }
                return
            }
            let progresses = loop ? (0..<n).map { Double($0) / Double(n - 1) } : [0.4]
            let images = UncheckedSendable(PresetPreviewRenderer.transitionFrames(d, from: a, to: b, progresses: progresses,
                                                                                 width: px, height: px).compactMap { $0 })
            Task { @MainActor in TransitionThumbnails.shared.store(images.value, for: d.id, loop: loop, key: key) }
        }
    }

    /// UI tests (state dump `ui.assets.transitionThumbsMissing`): whether the still of a transition is ready.
    func hasStill(_ id: String) -> Bool { stills[id] != nil }

    /// Resolves once no picture is being rendered (tests wait on this instead of polling with a time budget).
    func idle() async {
        if pending.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func store(_ images: [CGImage], for id: String, loop: Bool, key: String) {
        pending.remove(key)
        if pending.isEmpty { let w = idleWaiters; idleWaiters = []; for c in w { c.resume() } }
        guard !images.isEmpty else { return }
        if loop {
            loops[id] = images
            loopOrder.removeAll { $0 == id }; loopOrder.append(id)
            if loopOrder.count > 24 { loops[loopOrder.removeFirst()] = nil }
        } else {
            stills[id] = images[0]
        }
        revision += 1
    }
}

/// Transition ▸ parameters below Duration (direction / colour / softness / count…, TR-006): generated from the
/// descriptor's `ParamSpec`s, one undo step per drag. Transitions have no keyframes (CapCut).
struct TransitionParamRows: View {
    let ctx: InspectorContext

    var body: some View {
        WithPerceptionTracking {
            if let a = ctx.transitionClip, let t = a.transitionOut, let d = Registries.transitions[t.typeID], !d.params.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(d.params, id: \.key) { spec in WithPerceptionTracking { row(spec, clip: a.id, instance: t) } }
                }
            }
        }
    }

    @ViewBuilder func row(_ spec: ParamSpec, clip: ClipID, instance t: TransitionInstance) -> some View {
        let store = ctx.store
        let value = t.params[spec.key] ?? spec.defaultValue
        let write: (ParamValue, Bool) -> Void = { v, live in
            // Start from the transition as it is NOW, not the instance captured when this row was built: on macOS 13
            // SwiftUI can keep a field's earlier onSubmit closure (same display text), and a softness edit then wrote
            // back the old duration.
            var nt = store.project.timeline.clip(clip)?.transitionOut ?? t
            guard nt.typeID == t.typeID else { return }
            nt.params[spec.key] = v
            let inst = nt
            if live { store.updateGesture { p in try TimelineOps.setTransition(clip, inst, in: &p.timeline) } }
            else { store.perform(SetTransition(clip, inst)) }
        }
        switch spec.kind {
        case .scalar(let lo, let hi, _):
            let v = value.scalar ?? lo
            let k = spec.displayScale
            let scale = SliderScale.linear(lo...hi)
            let integral = k != 1 || (hi - lo) >= 10
            SliderRowView(label: tr(spec.nameKey), unit: scale.toUnit(v), display: integral ? Fmt.int(v * k) : String(format: "%.2f", v),
                          parse: NumberParse.number,
                          onBegin: { store.beginGesture("cmd.transition") },
                          onChange: { u in write(.scalar(Self.snap(scale.fromUnit(u), integral: integral && k == 1)), true) },
                          onEnd: { store.endGesture() },
                          commit: { x in write(.scalar(min(max(x / k, lo), hi)), false) },
                          step: { s in write(.scalar(min(max(v + Double(s) * (integral ? 1 / k : 0.01), lo), hi)), false) },
                          testID: "transition.param.\(spec.key)")
        case .color:
            InlineRow(label: tr(spec.nameKey)) {
                ColorSwatchButton(color: { if case .color(let c) = value { return c }; return .white }()) { c in write(.color(c), false) }
            }
        case .bool:
            ToggleLine(label: tr(spec.nameKey), isOn: Binding.perceived(get: { value.scalar == 1 }, set: { write(.bool($0), false) }))
        case .choice(let keys, _):
            InlineRow(label: tr(spec.nameKey)) {
                Dropdown(items: keys.enumerated().map { ($0.offset, tr($0.element)) },
                         selection: { if case .choice(let i) = value { return i }; return 0 }()) { write(.choice($0), false) }
            }
        }
    }

    /// Count-like parameters move in whole steps.
    static func snap(_ v: Double, integral: Bool) -> Double { integral ? v.rounded() : v }
}
