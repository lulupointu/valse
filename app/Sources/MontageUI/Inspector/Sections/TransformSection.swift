import SwiftUI
import MontageCore

/// Video/Text/Sticker ▸ Position & Size (UX.md §5.1): Scale (+ Uniform scale / Scale X·Y), Position X·Y, Rotate with
/// dial, alignment strip. Header: reset + group diamond over scale/position/rotation.
struct TransformSection: View {
    let ctx: InspectorContext
    var rotateLabelKey = "inspector.rotate"

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(reset: {
            guard let id = ctx.clip?.id else { return }
            ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.transform") { c in
                let flip = (c.transform.flipH, c.transform.flipV)
                c.transform = Transform(flipH: flip.0, flipV: flip.1)
                c.clearKeyframes(ParamKey.transformGroup + [.tilt])
            })
        }, keyframeKeys: ParamKey.transformGroup)
    }

    var body: some View {
        let canvas = ctx.store.projectSettings.canvasSize   // observation slice (perf)
        let uniform = UniformScaleState.isUniform(ctx)
        let pct = RowSpec(range: 1...500, step: 1, fieldRange: 1...1000, format: Fmt.percentValue)
        VStack(alignment: .leading, spacing: 6) {
            if uniform {
                ClipParamRow(ctx: ctx, label: tr("prop.scale"), spec: pct,
                             get: { c, t in (c.value(.scale, at: t)?.vec2?.x ?? 1) * 100 },
                             set: { c, v, t in c.setValue(.scale, .vec2(Vec2(v / 100, v / 100)), at: t) },
                             dependsOnTime: { $0.hasKeyframes(.scale) }, keyframeKeys: [.scale], gestureName: "cmd.transform")
            } else {
                Bind.row(ctx, tr("inspector.scaleX"), key: .scale, component: 0, spec: pct, toUI: { $0 * 100 }, fromUI: { $0 / 100 },
                         gestureName: "cmd.transform")
                Bind.row(ctx, tr("inspector.scaleY"), key: .scale, component: 1, spec: pct, toUI: { $0 * 100 }, fromUI: { $0 / 100 },
                         gestureName: "cmd.transform")
            }
            ToggleLine(label: tr("inspector.uniformScale"), isOn: Binding(get: { uniform }, set: { UniformScaleState.set(ctx, $0) }))
            InlineRow(label: tr("prop.position"), triplet: Bind.triplet(ctx, [.position])) {
                HStack(spacing: 14) {
                    Bind.field(ctx, key: .position, component: 0, prefix: "X",
                               spec: RowSpec(range: -canvas.width * 4...canvas.width * 4, step: 1, format: Fmt.int),
                               toUI: { $0 * canvas.width }, fromUI: { $0 / canvas.width }, gestureName: "cmd.transform")
                    // CapCut: Y grows upward.
                    Bind.field(ctx, key: .position, component: 1, prefix: "Y",
                               spec: RowSpec(range: -canvas.height * 4...canvas.height * 4, step: 1, format: Fmt.int),
                               toUI: { -$0 * canvas.height }, fromUI: { -$0 / canvas.height }, gestureName: "cmd.transform")
                }
            }
            InlineRow(label: tr(rotateLabelKey), triplet: Bind.triplet(ctx, [.rotation])) {
                HStack(spacing: 18) {
                    Bind.field(ctx, key: .rotation, spec: RowSpec(range: -360...360, step: 1, format: Fmt.degrees),
                               gestureName: "cmd.transform").testID("transform.rotate")
                    RotationDialBinding(ctx: ctx, key: .rotation)
                }
            }
            // CV-018: 3D rotation (tilt around the horizontal / vertical axis, perspective), keyframeable.
            InlineRow(label: tr("inspector.rotate3D"), triplet: Bind.triplet(ctx, [.tilt])) {
                HStack(spacing: 14) {
                    Bind.field(ctx, key: .tilt, component: 0, prefix: "X", spec: RowSpec(range: -85...85, step: 1, format: { "\(Int($0.rounded()))°" }),
                               gestureName: "cmd.transform").testID("transform.tilt.x")
                    Bind.field(ctx, key: .tilt, component: 1, prefix: "Y", spec: RowSpec(range: -85...85, step: 1, format: { "\(Int($0.rounded()))°" }),
                               gestureName: "cmd.transform").testID("transform.tilt.y")
                }
            }
            .help(tr("inspector.rotate3D.help"))
            AlignmentStrip(ctx: ctx)
        }
    }
}

/// Dial bound to a scalar angle property (gesture-coalesced).
struct RotationDialBinding: View {
    let ctx: InspectorContext
    let key: ParamKey
    var body: some View {
        let store = ctx.store
        let clip = ctx.clip
        let deg = clip.map { $0.value(key, at: $0.hasKeyframes(key) ? ctx.localTime : .zero)?.scalar ?? 0 } ?? 0
        RotationDial(degrees: deg, enabled: clip != nil,
                     onBegin: { store.beginGesture("cmd.transform") },
                     onChange: { v in
                         guard let id = clip?.id else { return }
                         Bind.apply(store, id, "cmd.transform") { c in c.setValue(key, .scalar((v * 100).rounded() / 100), at: Bind.local(store, c)) }
                     },
                     onEnd: { store.endGesture() })
    }
}

/// "Uniform scale" is a UI mode in CapCut; we keep it per clip and infer it from the model (x ≠ y → off).
@MainActor
enum UniformScaleState {
    static func isUniform(_ ctx: InspectorContext) -> Bool {
        guard let c = ctx.clip else { return true }
        if InspectorUIState.shared.nonUniform.contains(c.id) { return false }
        let s = c.value(.scale, at: c.hasKeyframes(.scale) ? ctx.localTime : .zero)?.vec2 ?? .one
        return abs(s.x - s.y) < 1e-9
    }
    static func set(_ ctx: InspectorContext, _ on: Bool) {
        guard let c = ctx.clip else { return }
        if on {
            InspectorUIState.shared.nonUniform.remove(c.id)
            let local = ctx.localTime
            ctx.store.performInspector(UpdateClip(c.id, nameKey: "cmd.transform") { c in
                c.modifyValue(.scale, at: local) { v in if let x = v.vec2?.x { v = .vec2(Vec2(x, x)) } }
            })
        } else {
            InspectorUIState.shared.nonUniform.insert(c.id)
        }
    }
}

/// Align left / centre / right / top / middle / bottom (+ distribute, greyed for a single clip), then mirror & flip.
struct AlignmentStrip: View {
    let ctx: InspectorContext
    enum Edge { case left, hCenter, right, top, vCenter, bottom }

    var body: some View {
        let canAlign = geometry() != nil
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                button("align.horizontal.left", "inspector.align.left", .left, canAlign)
                button("align.horizontal.center", "inspector.align.hCenter", .hCenter, canAlign)
                button("align.horizontal.right", "inspector.align.right", .right, canAlign)
                button("align.vertical.top", "inspector.align.top", .top, canAlign)
                button("align.vertical.center", "inspector.align.vCenter", .vCenter, canAlign)
                button("align.vertical.bottom", "inspector.align.bottom", .bottom, canAlign)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1, height: 16).padding(.horizontal, 4)
                SmallIconButton(symbol: "distribute.horizontal.center", help: tr("inspector.align.distributeH"), enabled: false, size: 13) {}
                    .frame(width: 30)
                SmallIconButton(symbol: "distribute.vertical.center", help: tr("inspector.align.distributeV"), enabled: false, size: 13) {}
                    .frame(width: 30)
            }
            .padding(.horizontal, 4)
            .frame(height: 26)
            .background(IStyle.strip, in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 0) {
                SmallIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: tr("inspector.flipH"),
                                active: ctx.clip?.transform.flipH ?? false, size: 13) { flip(h: true) }
                    .frame(width: 30)
                SmallIconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: tr("inspector.flipV"),
                                active: ctx.clip?.transform.flipV ?? false, size: 13) { flip(h: false) }
                    .frame(width: 30)
            }
            .padding(.horizontal, 4)
            .frame(height: 26)
            .background(IStyle.strip, in: RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    func button(_ symbol: String, _ help: String, _ edge: Edge, _ enabled: Bool) -> some View {
        SmallIconButton(symbol: symbol, help: tr(help), enabled: enabled, size: 13) { align(edge) }.frame(width: 30)
    }

    func flip(h: Bool) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.transform") { c in if h { c.transform.flipH.toggle() } else { c.transform.flipV.toggle() } })
    }

    /// Current on-canvas geometry of a clip (nil when its size is only known after rasterization, e.g. text).
    func geometry(_ clip: Clip? = nil) -> (LayerGeometry, Size2)? {
        guard let clip = clip ?? ctx.clip else { return nil }
        let p = ctx.store.project
        guard let loc = p.timeline.locate(clip.id) else { return nil }
        let track = p.timeline.tracks[loc.track]
        let t = clip.start + (clip.id == ctx.clip?.id ? ctx.localTime : Bind.local(ctx.store, clip))
        guard let l = FrameEvaluator.layer(clip, track: track, project: p, at: t), l.sourceSize.width > 0 else { return nil }
        return (l.geometry(canvasSize: p.settings.canvasSize), p.settings.canvasSize)
    }

    /// Moves each selected clip (C2: every clip of a multi-selection, by its own geometry) to the edge; one undo step.
    func align(_ edge: Edge) {
        var moves: [(ClipID, Time, Double, Double)] = []
        var size = Size2(1, 1)
        for clip in ctx.clips {
            guard let (g, canvas) = geometry(clip) else { continue }
            size = canvas
            let xs = g.corners.map(\.x), ys = g.corners.map(\.y)
            let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
            var dx = 0.0, dy = 0.0
            switch edge {
            case .left: dx = -minX
            case .right: dx = canvas.width - maxX
            case .hCenter: dx = canvas.width / 2 - (minX + maxX) / 2
            case .top: dy = -minY
            case .bottom: dy = canvas.height - maxY
            case .vCenter: dy = canvas.height / 2 - (minY + maxY) / 2
            }
            let local = clip.id == ctx.clip?.id ? ctx.localTime : Bind.local(ctx.store, clip)
            moves.append((clip.id, local, dx, dy))
        }
        guard !moves.isEmpty else { return }
        let canvas = size, all = moves
        ctx.store.perform(Edit("cmd.align") { p in
            for (id, local, fx, fy) in all {
                guard var c = p.timeline.clip(id) else { continue }
                c.modifyValue(.position, at: local) { v in
                    if let p = v.vec2 { v = .vec2(Vec2(p.x + fx / canvas.width, p.y + fy / canvas.height)) }
                }
                p.timeline[clip: id] = c
            }
        })
    }
}
