import SwiftUI
import MontageCore

// MARK: - Audio

/// Audio ▸ Basic: Volume (dB, keyframeable), Fade in / Fade out (0 … half the clip, greyed diamonds) (UX.md §5.1 Audio).
struct AudioBasicSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(reset: {
            guard let id = ctx.clip?.id else { return }
            ctx.store.perform(UpdateClip(id, nameKey: "cmd.volume") { c in
                c.audio.volume = 1; c.audio.fadeIn = .zero; c.audio.fadeOut = .zero; c.clearKeyframes([.volume])
            })
        }, keyframeKeys: [.volume])
    }

    static func dbFormat(_ v: Double) -> String { Fmt.decibels(v <= -59.95 ? -.infinity : v) }

    var body: some View {
        let half = max((ctx.clip?.duration.seconds ?? 2) / 2, 0.1)
        VStack(alignment: .leading, spacing: 4) {
            Bind.row(ctx, tr("prop.volume"), key: .volume,
                     spec: RowSpec(range: -60...20, step: 0.1, format: Self.dbFormat),
                     toUI: { max(-60, AudioProps.decibels($0)) }, fromUI: { $0 <= -59.95 ? 0 : pow(10, $0 / 20) },
                     gestureName: "cmd.volume")
            ClipParamRow(ctx: ctx, label: tr("inspector.fadeIn"), spec: RowSpec(range: 0...half, step: 0.1, format: Fmt.seconds),
                         get: { c, _ in c.audio.fadeIn.seconds }, set: { c, v, _ in c.audio.fadeIn = Time(v) },
                         keyframeKeys: [], gestureName: "cmd.fade")
            ClipParamRow(ctx: ctx, label: tr("inspector.fadeOut"), spec: RowSpec(range: 0...half, step: 0.1, format: Fmt.seconds),
                         get: { c, _ in c.audio.fadeOut.seconds }, set: { c, v, _ in c.audio.fadeOut = Time(v) },
                         keyframeKeys: [], gestureName: "cmd.fade")
        }
    }
}

// MARK: - Speed ▸ Normal

/// Speed ▸ Normal: log-scale Speed slider (0.1×–100×, ticks at 1/2/5/10×), Duration original ┈▸ new (typing a
/// duration sets the speed), Change pitch, Smooth slow-mo (UX.md §5.1, [30]).
struct SpeedNormalSection: View {
    let ctx: InspectorContext
    static let scale = SliderScale.piecewiseLog([0.1, 1, 2, 5, 10, 100], positions: [0, 0.2, 0.4, 0.6, 0.8, 1])

    var body: some View {
        let store = ctx.store
        let clip = ctx.clip
        let rate = clip?.speed.averageRate ?? 1
        let source = clip?.sourceDuration.seconds ?? 0
        let id = clip?.id
        func setLive(_ v: Double) {
            guard let id else { return }
            let s = Speed.constant((v * 100).rounded() / 100)
            store.updateGesture { p in try TimelineOps.setSpeed(id, s, in: &p.timeline) }
        }
        func commit(_ v: Double) {
            guard let id else { return }
            store.perform(SetSpeed(id, .constant(min(max((v * 100).rounded() / 100, 0.1), 100))))
        }
        return VStack(alignment: .leading, spacing: 10) {
            SliderRowView(label: tr("inspector.speed"), unit: Self.scale.toUnit(rate), ticks: [0, 0.4, 0.6, 0.8, 1],
                          display: Fmt.speed(rate), enabled: clip != nil, parse: NumberParse.number,
                          onBegin: { store.beginGesture("cmd.speed") },
                          onChange: { u in setLive(Self.scale.fromUnit(u)) },
                          onEnd: { store.endGesture() },
                          commit: commit,
                          step: { d in commit(rate + Double(d) * (rate < 1 ? 0.05 : 0.1)) })
            VStack(alignment: .leading, spacing: 4) {
                Text(loc: "inspector.duration").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                HStack(spacing: 10) {
                    Text(verbatim: Fmt.seconds(source)).font(Theme.Fonts.numeric).foregroundStyle(IStyle.label)
                    DashedArrow().frame(height: 10)
                    NumericField(display: Fmt.seconds(clip?.duration.seconds ?? 0), enabled: clip != nil, parse: NumberParse.number,
                                 commit: { d in if d > 0.05 { commit(source / d) } },
                                 step: { d in
                                     let nd = max(0.1, (clip?.duration.seconds ?? 1) + Double(d) * 0.1)
                                     commit(source / nd)
                                 })
                    Color.clear.frame(width: IStyle.tripletWidth - 4, height: 1)
                }
            }
            ToggleLine(label: tr("inspector.changePitch"),
                       isOn: Bind.binding(ctx, "cmd.speed", get: { !$0.audio.preservePitch }, set: { $0.audio.preservePitch = !$1 }, default: false))
            if ctx.kind == .video {  // smooth slow-mo is a video-frame feature: hidden for audio clips (W3-5)
                SmoothSlowMoRow(ctx: ctx)
                    .padding(.top, 6)
                    .testID("speed.smoothSlowmo")
            }
        }
    }
}

/// `├ ─ ─ ─ ─ ▸` between the original and the new duration.
struct DashedArrow: View {
    var body: some View {
        GeometryReader { g in
            let y = g.size.height / 2
            Path { p in
                p.move(to: CGPoint(x: 0, y: y - 4)); p.addLine(to: CGPoint(x: 0, y: y + 4))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width - 6, y: y))
            }
            .stroke(Color(hex: 0x6A6A6A), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            Path { p in
                p.move(to: CGPoint(x: g.size.width - 8, y: y - 4)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                p.addLine(to: CGPoint(x: g.size.width - 8, y: y + 4)); p.closeSubpath()
            }
            .fill(Color(hex: 0x6A6A6A))
        }
    }
}

// MARK: - Speed ▸ Curve

/// Speed ▸ Curve: preset tiles (None, Customized, Montage, Hero time, Bullet, Jump Cut, Flash in, Flash out) with
/// yellow glyphs drawn from the preset data, then the curve editor (UX.md §5.1, [42]/[44]).
struct SpeedCurveSection: View {
    let ctx: InspectorContext

    var body: some View {
        let speed = ctx.clip?.speed ?? .normal
        let curve: SpeedCurve? = { if case .curve(let c) = speed { return c }; return nil }()
        let selected: String = curve.map { $0.presetID ?? SpeedCurvePreset.customized.id } ?? "none"
        VStack(alignment: .leading, spacing: 14) {
            TileGrid {
                Tile(title: tr("speed.preset.none"), selected: selected == "none") { apply(nil) } content: {
                    Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
                }
                ForEach(SpeedCurvePreset.all) { p in
                    Tile(title: tr(p.nameKey), selected: selected == p.id) { apply(p) } content: {
                        if p.id == SpeedCurvePreset.customized.id {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 24)).foregroundStyle(IStyle.curve)
                        } else {
                            CurveGlyph(curve: p.curve).padding(.vertical, 8)
                        }
                    }
                }
            }
            if let curve, let clip = ctx.clip {
                SpeedCurveEditor(ctx: ctx, clip: clip, curve: curve)
            }
        }
    }

    func apply(_ p: SpeedCurvePreset?) {
        guard let id = ctx.clip?.id else { return }
        InspectorUIState.shared.curvePoint[id] = nil
        ctx.store.perform(SetSpeed(id, p.map { .curve($0.curve) } ?? .normal))
    }
}

/// Speed ▸ Velocity effects (W3-9): one-tap speed-ramp presets (None + `SpeedCurvePreset.velocity`). The result is a
/// normal speed curve, so Speed ▸ Curve can fine-tune it afterwards.
struct VelocityEffectsSection: View {
    let ctx: InspectorContext
    var body: some View {
        let selected: String = { if case .curve(let c)? = ctx.clip?.speed { return c.presetID ?? "" }; return "none" }()
        TileGrid {
            Tile(title: tr("speed.preset.none"), selected: selected == "none") { apply(nil) } content: {
                Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
            }
            .testID("velocity.none")
            ForEach(SpeedCurvePreset.velocity) { p in
                Tile(title: tr(p.nameKey), selected: selected == p.id) { apply(p) } content: {
                    CurveGlyph(curve: p.curve).padding(.vertical, 8)
                }
                .testID("velocity.\(p.id.split(separator: ".").last ?? "")")
            }
        }
    }

    func apply(_ p: SpeedCurvePreset?) {
        guard let id = ctx.clip?.id else { return }
        InspectorUIState.shared.curvePoint[id] = nil
        ctx.store.perform(SetSpeed(id, p.map { .curve($0.curve) } ?? .normal))
    }
}

/// Log-scale (0.1×…10×) mapping shared by glyphs and the editor: y = 0 at 10×, 1 at 0.1×.
enum CurveMath {
    static func y(_ v: Double) -> Double { (1 - log10(min(max(v, 0.1), 10))) / 2 }
    static func v(_ y: Double) -> Double { pow(10, 1 - 2 * min(max(y, 0), 1)) }
}

/// Yellow preset glyph with dashed 10× / 0.1× guides and the 1× line.
struct CurveGlyph: View {
    let curve: SpeedCurve
    var body: some View {
        Canvas { g, size in
            for (yy, dashed) in [(0.15, true), (0.5, false), (0.85, true)] {
                var p = Path(); p.move(to: CGPoint(x: 0, y: size.height * yy)); p.addLine(to: CGPoint(x: size.width, y: size.height * yy))
                g.stroke(p, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : []))
            }
            var path = Path()
            for i in 0...60 {
                let x = Double(i) / 60
                let pt = CGPoint(x: 6 + x * (size.width - 12), y: size.height * (0.15 + 0.7 * CurveMath.y(curve.value(at: x))))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            g.stroke(path, with: .color(IStyle.curve), lineWidth: 2)
        }
    }
}

/// Curve editor: "Duration 01:00 ┈▸ 41s", graph with 10× / 1× / 0.1× guides (log Y), the white curve, draggable beats,
/// a playhead line, and [Reset] [+] [−]. Dragging a beat is one undo step with live preview of the new duration.
struct SpeedCurveEditor: View {
    let ctx: InspectorContext
    let clip: Clip
    let curve: SpeedCurve
    @State private var dragBase: SpeedCurve?
    @State private var dragIndex: Int?

    var body: some View {
        let store = ctx.store
        let selected = InspectorUIState.shared.curvePoint[clip.id]
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(loc: "inspector.duration").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                Text(verbatim: Fmt.clock(clip.sourceDuration.seconds)).font(Theme.Fonts.numeric).foregroundStyle(IStyle.caption)
                DashedArrow().frame(height: 10)
                Text(verbatim: Fmt.clock(clip.duration.seconds)).font(Theme.Fonts.numeric).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Rectangle().fill(Theme.separator).frame(height: 1)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let pad: CGFloat = 14
                let plotH = h - 2 * pad
                let point: (SpeedPoint) -> CGPoint = { p in CGPoint(x: p.x * w, y: pad + CurveMath.y(p.v) * plotH) }
                ZStack(alignment: .topLeading) {
                    Canvas { gc, size in
                        for (v, label) in [(10.0, "10x"), (1.0, "1x"), (0.1, "0.1x")] {
                            let y = pad + CurveMath.y(v) * plotH
                            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                            gc.stroke(p, with: .color(Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            gc.draw(Text(verbatim: label).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35)),
                                    at: CGPoint(x: 8, y: y + (v == 10 ? 9 : -9)), anchor: .leading)
                        }
                        var path = Path()
                        for i in 0...200 {
                            let x = Double(i) / 200
                            let pt = CGPoint(x: x * size.width, y: pad + CurveMath.y(curve.value(at: x)) * plotH)
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                        gc.stroke(path, with: .color(Color(white: 0.85)), lineWidth: 2)
                    }
                    CurvePlayhead(ctx: ctx, clip: clip).frame(width: w, height: h)
                    ForEach(Array(curve.points.enumerated()), id: \.offset) { i, p in
                        BeatHandle(selected: selected == i)
                            .position(point(p))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("curve"))
                                .onChanged { v in
                                    if dragBase == nil {
                                        dragBase = curve; dragIndex = i
                                        InspectorUIState.shared.curvePoint[clip.id] = i
                                        store.beginGesture("cmd.speedCurve")
                                    }
                                    guard var c = dragBase, let di = dragIndex else { return }
                                    c.movePoint(di, x: Double(v.location.x / w), v: CurveMath.v(Double((v.location.y - pad) / plotH)))
                                    let id = clip.id
                                    store.updateGesture { p in try TimelineOps.setSpeed(id, .curve(c), in: &p.timeline) }
                                }
                                .onEnded { _ in dragBase = nil; dragIndex = nil; store.endGesture() })
                    }
                }
                .coordinateSpace(name: "curve")
                .contentShape(Rectangle())
                .onTapGesture { InspectorUIState.shared.curvePoint[clip.id] = nil }
            }
            .frame(height: 190)
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: tr("inspector.reset")) { reset() }
                SmallIconButton(symbol: "plus", help: tr("inspector.curve.addPoint"), enabled: curve.points.count < SpeedCurve.maxPoints, size: 12) { addPoint() }
                    .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 4))
                SmallIconButton(symbol: "minus", help: tr("inspector.curve.removePoint"),
                                enabled: selected.map { $0 > 0 && $0 < curve.points.count - 1 } ?? false, size: 12) { removePoint() }
                    .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(10)
        }
        .background(IStyle.graph, in: RoundedRectangle(cornerRadius: 6))
    }

    func reset() {
        let base = SpeedCurvePreset.preset(curve.presetID) ?? SpeedCurvePreset.customized
        InspectorUIState.shared.curvePoint[clip.id] = nil
        ctx.store.perform(SetSpeed(clip.id, .curve(base.curve)))
    }

    /// Adds a beat at the playhead (or the middle of the widest gap when the playhead sits on a beat).
    func addPoint() {
        var c = curve
        let x = clip.duration.ticks > 0 ? ctx.localTime / clip.duration : 0.5
        var i = c.insertPoint(at: x)
        if i == nil {
            let gaps = zip(c.points, c.points.dropFirst()).map { ($0.x + $1.x) / 2 }
            let widest = zip(gaps, zip(c.points, c.points.dropFirst()).map { $1.x - $0.x }).max { $0.1 < $1.1 }?.0 ?? 0.5
            i = c.insertPoint(at: widest)
        }
        guard let idx = i else { return }
        InspectorUIState.shared.curvePoint[clip.id] = idx
        ctx.store.perform(SetSpeed(clip.id, .curve(c)))
    }

    func removePoint() {
        guard let sel = InspectorUIState.shared.curvePoint[clip.id] else { return }
        var c = curve
        c.removePoint(at: sel)
        InspectorUIState.shared.curvePoint[clip.id] = nil
        ctx.store.perform(SetSpeed(clip.id, .curve(c)))
    }
}

/// ◖◗ beat handle.
struct BeatHandle: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().fill(selected ? Theme.accent : Color(hex: 0x5A5A5A)).frame(width: 16, height: 16)
            Rectangle().fill(IStyle.graph).frame(width: 2, height: 16)
        }
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
}

struct CurvePlayhead: View {
    let ctx: InspectorContext
    let clip: Clip
    var body: some View {
        GeometryReader { g in
            let x = clip.duration.ticks > 0 ? CGFloat(ctx.localTime / clip.duration) * g.size.width : 0
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5, height: g.size.height).offset(x: x)
        }
        .allowsHitTesting(false)
    }
}
