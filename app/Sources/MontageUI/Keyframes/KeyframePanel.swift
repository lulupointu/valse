import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import Perception

/// Keyframe panel (⌥K, "Show variable speed animation"; FEATURES KF-004/005/006): a dope sheet of the clip's keyframed
/// properties (click a diamond = select + jump, drag = retime, ⇧-click a lane = add a keyframe there, ⌫ deletes) and
/// the curve editor of the selected keyframe's outgoing segment (preset curves, draggable bezier handles, value or
/// speed graph).
struct KeyframePanel: View {
    let store: EditorStore

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if let clip = store.keyframeClip {
                    HStack(spacing: 8) {
                        Image(systemName: "diamond").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(verbatim: clip.name ?? tr("keyframes.panel.clip")).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Button(tr("keyframes.reset")) { KeyframePanel.confirmReset(store) }.testID("keyframes.reset")
                            .buttonStyle(.plain).font(Theme.Fonts.row).foregroundStyle(clip.keyframes.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                            .disabled(clip.keyframes.isEmpty)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    Rectangle().fill(Theme.separator).frame(height: 1)
                    if clip.keyframes.isEmpty {
                        hint(tr("keyframes.panel.empty"))
                    } else {
                        KeyframeDopeSheet(store: store, clip: clip).padding(.vertical, 6)
                        Rectangle().fill(Theme.separator).frame(height: 1)
                        KeyframeCurveEditor(store: store, clip: clip).padding(12)
                    }
                } else {
                    hint(tr("keyframes.panel.noClip"))
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 460, minHeight: 300)
            .background(Theme.panel)
        }
    }

    func hint(_ s: String) -> some View {
        Text(verbatim: s).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity).padding(24)
    }

    /// CapCut asks before wiping a clip's keyframes.
    static func confirmReset(_ store: EditorStore) {
        let a = NSAlert()
        a.messageText = tr("keyframes.reset.confirm")
        a.addButton(withTitle: tr("keyframes.reset"))
        a.addButton(withTitle: tr("common.cancel"))
        if a.runModal() == .alertFirstButtonReturn { store.resetKeyframes() }
    }

    /// Display name of a keyframe key ("Position", "Blur · Radius"…).
    static func name(_ key: String, in clip: Clip) -> String {
        let k = ParamKey(key)
        if let p = AnimatableProperties.property(k) { return tr(p.nameKey) }
        if let (id, param) = k.effectParam, let inst = clip.effects.first(where: { $0.id == id }),
           let d = Registries.effects[inst.typeID] {
            let pn = d.params.first { $0.key == param }.map { tr($0.nameKey) } ?? param
            return "\(tr(d.nameKey)) · \(pn)"
        }
        return key
    }

    /// Keys in inspector order (built-ins first, then effect parameters).
    static func orderedKeys(_ clip: Clip) -> [String] {
        let order = Dictionary(uniqueKeysWithValues: AnimatableProperties.all.enumerated().map { ($0.element.key.raw, $0.offset) })
        return clip.keyframes.keys.sorted { (order[$0] ?? 1000, $0) < (order[$1] ?? 1000, $1) }
    }
}

/// Dope sheet: one lane per keyframed property over the clip's duration, playhead line, diamonds.
struct KeyframeDopeSheet: View {
    let store: EditorStore
    let clip: Clip
    static let labelWidth: CGFloat = 130
    static let rowHeight: CGFloat = 22

    var body: some View {
        WithPerceptionTracking {
            let keys = KeyframePanel.orderedKeys(clip)
            VStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    WithPerceptionTracking {
                        HStack(spacing: 0) {
                            Text(verbatim: KeyframePanel.name(key, in: clip)).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: Self.labelWidth, alignment: .leading).padding(.leading, 12)
                            KeyframeLane(store: store, clip: clip, key: key).frame(height: Self.rowHeight).padding(.trailing, 12)
                        }
                    }
                }
            }
        }
    }
}

struct KeyframeLane: View {
    let store: EditorStore
    let clip: Clip
    let key: String
    @State private var grabbed: KeyframeRef?

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { g in
                WithPerceptionTracking {
                    let w = max(g.size.width - 2 * Self.inset, 1), o = Self.inset
                    let dur = max(clip.duration.seconds, 1e-6)
                    let sel = store.timelineUI.selectedKeyframe
                    let local = (store.transport.playhead - clip.start).seconds
                    Canvas { ctx, size in
                        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Theme.inset))
                        // segments between keyframes (eased segments drawn in accent)
                        let frames = clip.keyframes[key]?.keyframes ?? []
                        for (i, k) in frames.enumerated() where i + 1 < frames.count {
                            let x0 = o + k.time.seconds / dur * w, x1 = o + frames[i + 1].time.seconds / dur * w
                            let eased = k.easing != .linear
                            ctx.fill(Path(CGRect(x: x0, y: size.height / 2 - 1, width: max(x1 - x0, 0), height: 2)),
                                     with: .color(eased ? Theme.accent.opacity(0.55) : Theme.textTertiary.opacity(0.5)))
                        }
                        if local >= 0 && local <= dur {
                            let x = o + local / dur * w
                            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.8)))
                        }
                        for k in frames {
                            let x = o + k.time.seconds / dur * w, y = size.height / 2
                            let isSel = sel.map { $0.clip == clip.id && $0.key == key && abs(($0.time - k.time).ticks) <= keyframeRefTolerance.ticks } ?? false
                            var d = Path()
                            d.move(to: CGPoint(x: x, y: y - 5)); d.addLine(to: CGPoint(x: x + 5, y: y))
                            d.addLine(to: CGPoint(x: x, y: y + 5)); d.addLine(to: CGPoint(x: x - 5, y: y)); d.closeSubpath()
                            ctx.fill(d, with: .color(isSel ? Theme.accent : Color(white: 0.85)))
                            ctx.stroke(d, with: .color(.black.opacity(0.6)), lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in drag(v, width: w) }.onEnded { _ in endDrag() })
                    .accessibilityLabel(Text(verbatim: KeyframePanel.name(key, in: clip)))
                }
            }
        }
    }

    /// Diamonds at the clip's first/last frame stay fully visible.
    static let inset: CGFloat = 7

    private func time(atX x: CGFloat, width w: CGFloat) -> Time {
        (clip.duration * Double(min(max((x - Self.inset) / w, 0), 1)))
    }

    private func drag(_ v: DragGesture.Value, width w: CGFloat) {
        if let g = grabbed {
            let nt = time(atX: v.location.x, width: w)
            let key = self.key
            store.updateGesture { p in
                guard var c = p.timeline.clip(g.clip), var track = c.keyframes[key],
                      let i = track.index(near: g.time, tolerance: keyframeRefTolerance) else { return }
                let k = track.keyframes[i]
                track.remove(near: g.time, tolerance: keyframeRefTolerance)
                track.set(k.value, at: nt, easing: k.easing)
                c.keyframes[key] = track
                p.timeline[clip: g.clip] = c
            }
            store.timelineUI.selectedKeyframe = KeyframeRef(clip: g.clip, key: key, time: nt)
            store.seek(to: clip.start + nt, exact: false)
            return
        }
        guard v.translation == .zero else { return }   // first event only
        let frames = clip.keyframes[key]?.keyframes ?? []
        let dur = max(clip.duration.seconds, 1e-6)
        let kx = { (k: Keyframe) -> CGFloat in Self.inset + k.time.seconds / dur * w }
        if let hit = frames.min(by: { abs(kx($0) - v.location.x) < abs(kx($1) - v.location.x) }), abs(kx(hit) - v.location.x) <= 7 {
            let ref = KeyframeRef(clip: clip.id, key: key, time: hit.time)
            store.timelineUI.selectedKeyframe = ref
            store.seek(to: clip.start + hit.time)
            store.beginGesture("cmd.keyframe")
            grabbed = ref
        } else if NSEvent.modifierFlags.contains(.shift) {
            // ⇧-click: add a keyframe for this property here (CapCut "Add keyframe on keyframe panel")
            let t = time(atX: v.location.x, width: w), id = clip.id, key = ParamKey(self.key)
            store.edit("cmd.keyframe") { p in
                guard var c = p.timeline.clip(id) else { return }
                c.addKeyframe(key, at: t, tolerance: keyframeRefTolerance)
                p.timeline[clip: id] = c
            }
            store.timelineUI.selectedKeyframe = KeyframeRef(clip: id, key: self.key, time: t)
        } else {
            store.seek(to: clip.start + time(atX: v.location.x, width: w))
        }
    }

    private func endDrag() {
        if grabbed != nil { store.endGesture() }
        grabbed = nil
    }
}

/// Curve of the selected keyframe's outgoing segment: preset tiles, bezier graph with two handles, value / speed view.
struct KeyframeCurveEditor: View {
    let store: EditorStore
    let clip: Clip

    var ref: KeyframeRef? {
        guard let r = store.timelineUI.selectedKeyframe, r.clip == clip.id, clip.keyframes[r.key] != nil else { return nil }
        return r
    }

    var body: some View {
        WithPerceptionTracking {
            if let ref, let track = clip.keyframes[ref.key], let i = track.index(near: ref.time, tolerance: keyframeRefTolerance) {
                let easing = track.keyframes[i].easing
                let isLast = i + 1 >= track.keyframes.count
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(verbatim: tr("keyframes.curve.title", KeyframePanel.name(ref.key, in: clip)))
                            .font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Picker("", selection: Binding(get: { store.keyframeUI.graphMode }, set: { store.keyframeUI.graphMode = $0 })) {
                            ForEach(KeyframeUIState.GraphMode.allCases, id: \.self) { m in WithPerceptionTracking { Text(verbatim: tr("keyframes.graph.\(m.rawValue)")).tag(m) } }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    }
                    if isLast {
                        Text(loc: "keyframes.curve.last").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            CurveGraph(store: store, ref: ref, easing: easing, mode: store.keyframeUI.graphMode).frame(width: 170, height: 170)
                            VStack(alignment: .leading, spacing: 8) {
                                EasingPresetGrid(selected: easing) { store.setKeyframeEasing($0, ref) }
                                Button(tr("keyframes.curve.applyAll")) { store.setKeyframeEasing(easing, ref, allSegments: true) }
                                    .buttonStyle(.plain).font(Theme.Fonts.row).foregroundStyle(Theme.accent).testID("keyframes.applyAll")
                            }
                        }
                    }
                }
            } else {
                Text(loc: "keyframes.curve.select").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Square graph of an easing: value (progress over time) with draggable bezier handles, or speed (derivative).
struct CurveGraph: View {
    let store: EditorStore
    let ref: KeyframeRef
    let easing: Easing
    let mode: KeyframeUIState.GraphMode
    @State private var dragging: Int?
    /// Visible progress range (rebound curves overshoot).
    static let yMin = -0.4, yMax = 1.4
    /// Horizontal inset so the 0 / 1 ends and the handles at x = 0 / 1 are not clipped by the graph edge.
    static let inset: CGFloat = 8

    static func point(_ x: Double, _ y: Double, in s: CGSize) -> CGPoint {
        CGPoint(x: inset + x * max(s.width - 2 * inset, 1), y: (1 - (y - yMin) / (yMax - yMin)) * s.height)
    }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { g in
                WithPerceptionTracking {
                    let s = g.size
                    let pt = { (x: Double, y: Double) -> CGPoint in Self.point(x, y, in: s) }
                    Canvas { ctx, size in
                        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color(hex: 0x0F0F0F)))
                        for y in [0.0, 1.0] {
                            var l = Path(); l.move(to: pt(0, y)); l.addLine(to: pt(1, y))
                            ctx.stroke(l, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        var curve = Path()
                        if mode == .value {
                            for i in 0...96 { let x = Double(i) / 96; let p = pt(x, easing.apply(x)); i == 0 ? curve.move(to: p) : curve.addLine(to: p) }
                        } else {
                            let sp = easing.speedSamples(97)
                            let m = max(sp.map(abs).max() ?? 1, 1e-6)
                            for (i, v) in sp.enumerated() {
                                let x = Double(i) / 96
                                let p = CGPoint(x: Self.inset + x * (size.width - 2 * Self.inset), y: size.height * (0.92 - 0.84 * (v / m)))
                                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
                            }
                        }
                        ctx.stroke(curve, with: .color(.white), lineWidth: 2)
                        if mode == .value, let c = easing.controlPoints {
                            let p1 = pt(c.x1, c.y1), p2 = pt(c.x2, c.y2)
                            for (a, b) in [(pt(0, 0), p1), (pt(1, 1), p2)] {
                                var l = Path(); l.move(to: a); l.addLine(to: b)
                                ctx.stroke(l, with: .color(Theme.accent.opacity(0.8)), lineWidth: 1)
                            }
                            for p in [p1, p2] { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Theme.accent)) }
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        guard mode == .value else { return }
                        let x = min(max(Double((v.location.x - Self.inset) / max(s.width - 2 * Self.inset, 1)), 0), 1)
                        let y = min(max(Self.yMax - Double(v.location.y / s.height) * (Self.yMax - Self.yMin), Self.yMin), Self.yMax)
                        let c = easing.controlPoints ?? (0.33, 0.33, 0.67, 0.67)
                        if dragging == nil {
                            let d1 = hypot(Double(pt(c.x1, c.y1).x - v.location.x), Double(pt(c.x1, c.y1).y - v.location.y))
                            let d2 = hypot(Double(pt(c.x2, c.y2).x - v.location.x), Double(pt(c.x2, c.y2).y - v.location.y))
                            dragging = d1 <= d2 ? 1 : 2
                            store.beginGesture("cmd.keyframeCurve")
                        }
                        let e: Easing = dragging == 1 ? .bezier(x1: x, y1: y, x2: c.x2, y2: c.y2) : .bezier(x1: c.x1, y1: c.y1, x2: x, y2: y)
                        let r = ref
                        store.updateGesture { p in
                            guard var clip = p.timeline.clip(r.clip) else { return }
                            clip.setEasing(e, key: r.key, at: r.time, tolerance: keyframeRefTolerance)
                            p.timeline[clip: r.clip] = clip
                        }
                    }.onEnded { _ in if dragging != nil { store.endGesture() }; dragging = nil })
                }
            }
        }
    }
}

/// CapCut "Preset curves" tiles ([102]): curve glyph + name, selected = accent ring.
struct EasingPresetGrid: View {
    let selected: Easing
    let apply: (Easing) -> Void

    var body: some View {
        WithPerceptionTracking {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 60), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(EasingPreset.all) { p in
                    WithPerceptionTracking {
                        Button { apply(p.easing) } label: { presetLabel(p) }
                            .buttonStyle(.plain).help(tr(p.nameKey)).testID("keyframes.preset.\(p.id)")
                    }
                }
            }
        }
    }

    func presetLabel(_ p: EasingPreset) -> some View {
                VStack(spacing: 2) {
                    EasingGlyph(easing: p.easing)
                        .frame(width: 44, height: 34)
                        .background(Theme.segmentSelected, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.easing == selected ? Theme.accent : .clear, lineWidth: 1.5))
                    Text(verbatim: tr(p.nameKey)).font(.system(size: 9)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .frame(width: 56)
                .contentShape(Rectangle())
    }
}

struct EasingGlyph: View {
    let easing: Easing
    var body: some View {
        WithPerceptionTracking {
            Canvas { ctx, size in
                let inset: CGFloat = 6
                let w = size.width - 2 * inset, h = size.height - 2 * inset
                var p = Path()
                for i in 0...32 {
                    let x = Double(i) / 32
                    let y = easing.apply(x)
                    let q = CGPoint(x: inset + x * w, y: inset + (1 - (y + 0.2) / 1.4) * h)
                    i == 0 ? p.move(to: q) : p.addLine(to: q)
                }
                ctx.stroke(p, with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}
