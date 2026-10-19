import Foundation

/// What a layer draws. Media frames are fetched by the engine (decoder) for `sourceTime`.
public enum LayerSource: Hashable, Sendable {
    case media(MediaID, sourceTime: Time)
    case image(MediaID)
    case text(TextContent)
    case solid(RGBA)
    case sticker(id: String)
}

/// An animation active on a layer at this frame; the engine applies the registered descriptor
/// (MontageEffects.AnimationRegistry) to the layer's transform/opacity with `progress` ∈ [0,1].
public struct ActiveAnimation: Hashable, Sendable {
    public enum Phase: String, Sendable { case `in`, out, combo }
    public var typeID: String
    public var phase: Phase
    public var progress: Double
    public init(typeID: String, phase: Phase, progress: Double) { self.typeID = typeID; self.phase = phase; self.progress = progress }
}

/// Effect with its parameters resolved (keyframes applied) for this frame.
public struct ResolvedEffect: Hashable, Sendable {
    public var instanceID: EffectInstanceID
    public var typeID: String
    public var params: [String: ParamValue]
    public init(instanceID: EffectInstanceID, typeID: String, params: [String: ParamValue]) {
        self.instanceID = instanceID; self.typeID = typeID; self.params = params
    }
}

/// A fully resolved visual layer at one instant: no keyframes, no timing left to compute.
public struct LayerDescription: Hashable, Sendable {
    public var clipID: ClipID
    public var trackID: TrackID
    public var source: LayerSource
    /// Pixel size / aspect of the source (media pixel size, or canvas size for generators).
    public var sourceSize: Size2
    public var transform: Transform
    public var opacity: Double
    public var blendMode: BlendMode
    public var crop: CropRect
    public var mask: Mask?
    public var effects: [ResolvedEffect]
    public var animations: [ActiveAnimation]
    /// Clip-local time (for time-based effects such as glitch/shake).
    public var localTime: Time
    // W6/W9 per-layer features (defaults = off).
    public var matte: ClipMatte? = nil
    /// Adjust ▸ Mask: region (layer space) where the adjustment-category effects apply; nil = whole layer.
    public var adjustMask: Mask? = nil
    /// Skin tone protection (CL-010) for the adjustment-category effects.
    public var skinProtect = false
    /// Masks 2…4 (MK-005): the layer shows the union of `mask` and these.
    public var extraMasks: [Mask] = []
    /// Smooth slow-mo: weight 0…1 of the NEXT source frame (aux lane `.nextFrame`) at this instant; nil = off.
    public var frameBlend: Double? = nil
    public var slowMoMethod: SlowMotionMethod? = nil
    public var motionBlur: MotionBlur? = nil
    public var stabilization: Stabilization? = nil
    /// Relight with animated lights resolved at this instant (AI/Relight.swift); nil = off.
    public var relight: RelightSettings? = nil
    /// Canvas background fill (blurred copy / image) of a main-track clip, not the clip itself: not hit-testable.
    public var isCanvasBackground = false
    /// Clip duration (text templates time their layers on it).
    public var duration: Time = .zero
    /// Shape sticker look at this instant (ST-008); nil = the sticker's own.
    public var shapeStyle: ShapeStickerStyle? = nil
    /// Container of an effect clip's "Apply to ▸ PiP" group (FX-004): not a layer of its own (canvas hit-testing
    /// looks inside it).
    public var isEffectGroup = false

    /// Media/images/solids are aspect-fitted to the canvas at scale 1; text and stickers use their own
    /// size in canvas pixels (`sourceSize`).
    public var fitsCanvas: Bool {
        switch source {
        case .text, .sticker: return false
        default: return true
        }
    }

    public func geometry(canvasSize: Size2, sourceSizeOverride: Size2? = nil) -> LayerGeometry {
        LayerGeometry(sourceSize: sourceSizeOverride ?? sourceSize, canvasSize: canvasSize, transform: transform,
                      crop: crop, fitsCanvas: fitsCanvas)
    }
}

public enum RenderItem: Hashable, Sendable {
    case layer(LayerDescription)
    /// Main-track transition between two layers.
    case transition(from: LayerDescription, to: LayerDescription, typeID: String, progress: Double, params: [String: ParamValue])
    /// Adjustment layer: apply `effects` to everything composited so far, blended by `opacity`; `mask` (canvas space,
    /// the clip's `adjustMask`) limits them to a region (effect mask, FX-005 / MK-006).
    case adjustment(clipID: ClipID, effects: [ResolvedEffect], opacity: Double, localTime: Time, mask: Mask?)
    /// Compound clip: `items` (the nested timeline at this instant, clip ids made unique with `nestedClipID`) are
    /// composited into one canvas-size layer, which is then placed like `container` (transform, opacity, blend, mask,
    /// effects of the compound clip; its source is a placeholder).
    case nested(container: LayerDescription, items: [RenderItem])
}

/// Everything the compositor needs for one output frame, bottom to top. Produced by `FrameEvaluator` (pure Swift),
/// consumed by the Metal renderer for preview, export and thumbnails alike → identical output everywhere.
public struct FrameDescription: Hashable, Sendable {
    public var time: Time
    public var canvasSize: Size2
    public var background: RGBA
    public var items: [RenderItem]
    /// Working/output colour space (sources are converted into it by the renderer).
    public var colorSpace: ProjectColorSpace = .sdr709

    /// All media-backed layers (incl. both sides of transitions).
    public var mediaLayers: [LayerDescription] { Self.mediaLayers(items) }

    static func mediaLayers(_ items: [RenderItem]) -> [LayerDescription] {
        items.flatMap { item -> [LayerDescription] in
            switch item {
            case .layer(let l): return [l]
            case .transition(let a, let b, _, _, _): return [a, b]
            case .adjustment: return []
            case .nested(_, let inner): return mediaLayers(inner)
            }
        }.filter { if case .media = $0.source { return true }; return false }
    }
}

/// Evaluates a project at a time. Cost: O(tracks · log clips). Safe to call from any thread.
public enum FrameEvaluator {
    public static func evaluate(_ project: Project, at t: Time) -> FrameDescription {
        let canvas = project.settings.canvasSize
        var background = project.settings.backgroundColor
        let items = items(project, at: t, depth: 0, background: &background)
        return FrameDescription(time: t, canvasSize: canvas, background: background, items: items,
                                colorSpace: project.settings.colorSpace)
    }

    static func items(_ project: Project, at t: Time, depth: Int, background: inout RGBA) -> [RenderItem] {
        let canvas = project.settings.canvasSize
        var items: [RenderItem] = []
        // FX-004: index in `items` just after the main track's items (main-scoped effects go there).
        var mainEnd: Int?
        for track in project.timeline.tracks where track.kind.isVisual && !track.isHidden {
            let active = track.clips(at: t).filter(\.isEnabled)
            guard !active.isEmpty else { continue }
            defer { if track.isMain { mainEnd = items.count } }
            if active.count >= 2,   // main or overlay (PiP) transition
               let a = active.first, let b = active.dropFirst().first, let tr = a.transitionOut {
                // a ends inside b's head: transition region is [b.start, a.end)
                guard let la = layer(a, track: track, project: project, at: t),
                      let lb = layer(b, track: track, project: project, at: t) else { continue }
                let d = max(tr.duration.ticks, 1)
                let p = min(max(Double((t - b.start).ticks) / Double(d), 0), 1)
                let dominant = p < 0.5 ? (a, la) : (b, lb)
                if let cv = dominant.0.canvas {
                    items += canvasItems(cv, for: dominant.1, canvasSize: canvas, background: &background)
                }
                items.append(.transition(from: la, to: lb, typeID: tr.typeID, progress: p, params: tr.params))
                continue
            }
            for c in active {
                if case .adjustment = c.content {
                    let local = c.localTime(t)
                    let r = c.resolved(at: local)
                    let adj = RenderItem.adjustment(clipID: c.id, effects: resolveEffects(r), opacity: r.opacity, localTime: local, mask: r.adjustMask)
                    switch c.effectScope ?? .all {
                    case .all:
                        items.append(adj)
                    case .main:
                        // only the main track (+ background / canvas fill): processed before the overlays are placed
                        guard let m = mainEnd else { continue }
                        items.insert(adj, at: m)
                        mainEnd = m + 1
                    case .pip:
                        // only the overlays between the main track and this clip: composited as a group, processed,
                        // then placed back over the untouched main track
                        let start = mainEnd ?? 0
                        guard start < items.count else { continue }
                        let group = Array(items[start...]) + [adj]
                        items.removeSubrange(start...)
                        items.append(.nested(container: effectGroupContainer(c, track: track, canvas: canvas, local: local), items: group))
                    }
                } else if case .compound(let cid) = c.content {
                    if let n = nestedItem(c, cid, track: track, project: project, at: t, depth: depth) { items.append(n) }
                } else if let l = layer(c, track: track, project: project, at: t) {
                    if track.isMain, let cv = c.canvas {
                        items += canvasItems(cv, for: l, canvasSize: canvas, background: &background)
                    }
                    items.append(.layer(l))
                }
            }
        }
        return items
    }

    /// Full-canvas, identity placement of an "Apply to ▸ PiP" effect group (FX-004).
    static func effectGroupContainer(_ c: Clip, track: Track, canvas: Size2, local: Time) -> LayerDescription {
        var l = LayerDescription(clipID: c.id, trackID: track.id, source: .solid(.clear), sourceSize: canvas, transform: Transform(),
                                 opacity: 1, blendMode: .normal, crop: CropRect(), mask: nil, effects: [], animations: [],
                                 localTime: local)
        l.isEffectGroup = true
        return l
    }

    /// The nested timeline of a compound clip at parent time `t` (nested time = the clip's remapped source time).
    static func nestedItem(_ c: Clip, _ cid: CompoundID, track: Track, project: Project, at t: Time, depth: Int) -> RenderItem? {
        guard depth < Project.maxCompoundDepth, let comp = project.compound(cid) else { return nil }
        let tau = c.sourceTime(at: t)
        var nestedBackground = RGBA.clear
        let inner = items(project.nested(comp), at: tau, depth: depth + 1, background: &nestedBackground).map { rewriteIDs($0, container: c.id) }
        guard !inner.isEmpty else { return nil }
        let local = c.localTime(t)
        let r = c.resolved(at: local)
        let container = LayerDescription(clipID: c.id, trackID: track.id, source: .solid(.clear), sourceSize: project.settings.canvasSize,
                                         transform: r.transform, opacity: r.opacity, blendMode: r.blendMode, crop: r.crop,
                                         mask: r.mask, effects: resolveEffects(r), animations: animations(c, local: local),
                                         localTime: local)
        return .nested(container: container, items: inner)
    }

    static func rewriteIDs(_ item: RenderItem, container: ClipID) -> RenderItem {
        func fix(_ l: LayerDescription) -> LayerDescription { var x = l; x.clipID = nestedClipID(container, l.clipID); return x }
        switch item {
        case .layer(let l): return .layer(fix(l))
        case .transition(let a, let b, let id, let p, let params): return .transition(from: fix(a), to: fix(b), typeID: id, progress: p, params: params)
        case .adjustment(let id, let e, let o, let lt, let m): return .adjustment(clipID: nestedClipID(container, id), effects: e, opacity: o, localTime: lt, mask: m)
        case .nested(let cont, let inner): return .nested(container: fix(cont), items: inner.map { rewriteIDs($0, container: container) })
        }
    }

    /// Fixed instance ids for the synthetic canvas effects (stable `FrameDescription` hashes across frames).
    static let canvasEffectIDs: [EffectInstanceID] = (1...4).map {
        EffectInstanceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000CA%03d", $0))!)
    }

    /// Render items drawn *below* main-track layer `l` for its canvas setting (see `CanvasBackground`).
    public static func canvasItems(_ canvas: CanvasBackground, for l: LayerDescription, canvasSize: Size2,
                                   background: inout RGBA) -> [RenderItem] {
        switch canvas {
        case .color(let c):
            background = RGBA(c.r, c.g, c.b, 1)
            return []
        case .blur(let level):
            let s = l.sourceSize
            guard l.fitsCanvas, s.width > 0, s.height > 0 else { return [] }
            let fit = min(canvasSize.width / s.width, canvasSize.height / s.height)
            let fill = max(canvasSize.width / s.width, canvasSize.height / s.height)
            let k = fill / max(fit, 1e-9)
            var b = l
            b.transform = Transform(position: .zero, scale: Vec2(k, k), rotation: 0,
                                    flipH: l.transform.flipH, flipV: l.transform.flipV)
            b.opacity = 1; b.blendMode = .normal; b.crop = CropRect(); b.mask = nil; b.animations = []
            b.effects = l.effects + CanvasBackground.blurStack(level: level).enumerated().map { i, r in
                ResolvedEffect(instanceID: canvasEffectIDs[i], typeID: CanvasBackground.blurEffectID, params: ["radius": .scalar(r)])
            }
            b.isCanvasBackground = true
            return [.layer(b)]
        case .style(let id):
            var fillLayer = LayerDescription(
                clipID: l.clipID, trackID: l.trackID, source: .solid(.black), sourceSize: canvasSize, transform: .identity,
                opacity: 1, blendMode: .normal, crop: CropRect(), mask: nil,
                effects: [ResolvedEffect(instanceID: canvasEffectIDs[3], typeID: id, params: [:])], animations: [],
                localTime: l.localTime)
            fillLayer.isCanvasBackground = true
            return [.layer(fillLayer)]
        }
    }

    public static func layer(_ c: Clip, track: Track, project: Project, at t: Time) -> LayerDescription? {
        let local = c.localTime(t)
        let r = c.resolved(at: local)
        let source: LayerSource
        let size: Size2
        switch c.content {
        case .media(let id):
            guard let a = project.asset(id), a.hasVideo || a.kind == .image else { return nil }
            source = a.kind == .image ? .image(id) : .media(id, sourceTime: c.sourceTime(at: t))
            size = a.pixelSize
        case .text(var text):
            // Real size is known only after rasterization (engine measures the text); placement uses `.native`.
            // Caption word timings are content time; the renderer wants clip-local time.
            if c.sourceStart != .zero, text.caption?.words.isEmpty == false {
                let d = c.sourceStart
                text.caption!.words = text.caption!.words.map { var w = $0; w.start = w.start - d; w.end = w.end - d; return w }
            }
            // TX-039: counters show their value at this frame (template slot 0 reads the same string)
            if let k = text.counter { text.string = k.string(at: local, duration: c.duration); text.runs = [] }
            source = .text(text); size = .zero
        case .solid(let color):
            source = .solid(color); size = project.settings.canvasSize
        case .sticker(let id):
            let side = project.settings.canvasSize.height * 0.35
            source = .sticker(id: id); size = Size2(side, side)
        case .adjustment, .compound:
            return nil
        }
        var l = LayerDescription(clipID: c.id, trackID: track.id, source: source, sourceSize: size,
                                 transform: r.transform, opacity: r.opacity, blendMode: r.blendMode, crop: r.crop,
                                 mask: r.mask, effects: resolveEffects(r), animations: animations(c, local: local),
                                 localTime: local)
        l.matte = r.matte
        l.adjustMask = r.adjustMask
        l.skinProtect = c.skinToneProtection ?? false
        if r.mask != nil, let extra = r.extraMasks { l.extraMasks = extra }
        if case .sticker = c.content { l.shapeStyle = r.shapeStyle }
        l.stabilization = r.stabilization
        if let rl = c.relight, c.mediaID != nil { l.relight = rl.resolved(at: local.seconds) }
        l.duration = c.duration
        if case .media(let id) = c.content, let a = project.asset(id), a.kind == .video {
            l.motionBlur = r.motionBlur
            if let m = r.smoothSlowMo, FrameUpconversion.needsInterpolation(rate: c.speed.rate(at: local, outputDuration: c.duration),
                                                                           sourceRate: a.frameRate, projectRate: project.settings.frameRate) {
                l.slowMoMethod = m
                l.frameBlend = frameBlendWeight(c, asset: a, at: t)
            }
        }
        return l
    }

    /// Fractional position between the decoded source frame and the next one (in the file actually decoded: the
    /// reversed render plays forwards in reversed time).
    public static func frameBlendWeight(_ c: Clip, asset: MediaAsset, at t: Time) -> Double {
        let sfd = (asset.frameRate ?? .fps30).frameDuration
        let s = c.sourceTime(at: t)
        let fileTime = c.reversed ? asset.duration - s : s
        let x = Double(fileTime.ticks) / Double(max(sfd.ticks, 1))
        return min(max(x - x.rounded(.down), 0), 1)
    }

    static func resolveEffects(_ c: Clip) -> [ResolvedEffect] {
        c.effects.filter(\.isEnabled).map { ResolvedEffect(instanceID: $0.id, typeID: $0.typeID, params: $0.params) }
    }

    static func animations(_ c: Clip, local: Time) -> [ActiveAnimation] {
        var out: [ActiveAnimation] = []
        if let combo = c.animations.combo {
            let d = max(combo.duration.ticks, 1)
            out.append(ActiveAnimation(typeID: combo.typeID, phase: .combo,
                                       progress: Double(local.ticks % d) / Double(d)))
        }
        if let a = c.animations.inAnim, local < a.duration {
            out.append(ActiveAnimation(typeID: a.typeID, phase: .in, progress: local / a.duration))
        }
        if let a = c.animations.outAnim, local > c.duration - a.duration {
            out.append(ActiveAnimation(typeID: a.typeID, phase: .out,
                                       progress: (local - (c.duration - a.duration)) / a.duration))
        }
        return out
    }
}

/// Placement of a layer on the canvas, shared by the renderer (vertex positions) and the UI (canvas handles,
/// hit-testing). Canvas pixel coordinates, origin top-left, y down.
public struct LayerGeometry: Equatable, Sendable {
    public var center: Vec2
    /// Half extents before rotation (after scale, crop).
    public var halfSize: Vec2
    /// Radians, clockwise.
    public var rotation: Double
    /// 3D planar rotation in radians (x around the horizontal axis, y around the vertical axis); zero = flat.
    public var tilt: Vec2 = .zero
    /// Focal length (canvas px) of the perspective used for `tilt`.
    public var focal: Double = 1

    public init(sourceSize: Size2, canvasSize: Size2, transform: Transform, crop: CropRect = CropRect(), fitsCanvas: Bool = true) {
        // aspect-fit at scale 1 (or native canvas-pixel size for text/stickers)
        let fit = fitsCanvas ? min(canvasSize.width / max(sourceSize.width, 1), canvasSize.height / max(sourceSize.height, 1)) : 1
        let w = sourceSize.width * fit * (1 - crop.left - crop.right)
        let h = sourceSize.height * fit * (1 - crop.top - crop.bottom)
        let cropShift = Vec2((crop.left - crop.right) / 2 * sourceSize.width * fit, (crop.top - crop.bottom) / 2 * sourceSize.height * fit)
        center = Vec2(canvasSize.width / 2 + transform.position.x * canvasSize.width,
                      canvasSize.height / 2 + transform.position.y * canvasSize.height) + cropShift * transform.scale
        halfSize = Vec2(w / 2 * transform.scale.x, h / 2 * transform.scale.y)
        rotation = transform.rotation * .pi / 180
        let maxTilt = 85.0
        tilt = Vec2(min(max(transform.tilt.x, -maxTilt), maxTilt), min(max(transform.tilt.y, -maxTilt), maxTilt)) * (.pi / 180)
        focal = 1.4 * max(canvasSize.width, canvasSize.height)
    }

    public var hasTilt: Bool { tilt.x != 0 || tilt.y != 0 }

    /// Corners (TL, TR, BL, BR) in canvas pixels (perspective-projected when tilted).
    public var corners: [Vec2] { projectedCorners.map(\.point) }

    /// Corners with their perspective divisor `w` (1 when flat): the renderer emits clip-space `(ndc · w, w)` so
    /// texture coordinates interpolate perspective-correctly across the quad.
    public var projectedCorners: [(point: Vec2, w: Double)] {
        let c = cos(rotation), s = sin(rotation)
        let cx = cos(tilt.x), sx = sin(tilt.x), cy = cos(tilt.y), sy = sin(tilt.y)
        return [Vec2(-1, -1), Vec2(1, -1), Vec2(-1, 1), Vec2(1, 1)].map { k in
            var x = k.x * halfSize.x, y = k.y * halfSize.y, z = 0.0
            if hasTilt {
                // around the vertical axis (right edge away for +y), then the horizontal axis (top edge away for +x)
                let x1 = x * cy, z1 = x * sy
                let y2 = y * cx + z1 * sx, z2 = z1 * cx - y * sx
                x = x1; y = y2; z = z2
            }
            let w = max(0.05, (focal + z) / focal)
            x /= w; y /= w
            return (Vec2(center.x + x * c - y * s, center.y + x * s + y * c), w)
        }
    }

    /// Whether a canvas point lies inside the (rotated) layer.
    public func contains(_ p: Vec2) -> Bool {
        if hasTilt {
            // convex quad TL → TR → BR → BL: same side of every edge
            let q = corners, poly = [q[0], q[1], q[3], q[2]]
            var sign = 0.0
            for i in 0..<4 {
                let a = poly[i], b = poly[(i + 1) % 4]
                let cr = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if cr != 0 { if sign == 0 { sign = cr } else if (cr > 0) != (sign > 0) { return false } }
            }
            return true
        }
        let c = cos(-rotation), s = sin(-rotation)
        let d = p - center
        let x = d.x * c - d.y * s, y = d.x * s + d.y * c
        return abs(x) <= abs(halfSize.x) && abs(y) <= abs(halfSize.y)
    }
}

extension LayerDescription {
    /// Public memberwise init (engine-synthesized layers, e.g. render-cache frames); feature fields default to off.
    public init(clipID: ClipID, trackID: TrackID, source: LayerSource, sourceSize: Size2, transform: Transform, opacity: Double,
                blendMode: BlendMode, crop: CropRect, mask: Mask?, effects: [ResolvedEffect], animations: [ActiveAnimation],
                localTime: Time) {
        self.clipID = clipID; self.trackID = trackID; self.source = source; self.sourceSize = sourceSize
        self.transform = transform; self.opacity = opacity; self.blendMode = blendMode; self.crop = crop; self.mask = mask
        self.effects = effects; self.animations = animations; self.localTime = localTime
    }
}

extension FrameDescription {
    public init(time: Time, canvasSize: Size2, background: RGBA, items: [RenderItem]) {
        self.time = time; self.canvasSize = canvasSize; self.background = background; self.items = items
    }
}
