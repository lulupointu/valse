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
}

/// Effect with its parameters resolved (keyframes applied) for this frame.
public struct ResolvedEffect: Hashable, Sendable {
    public var instanceID: EffectInstanceID
    public var typeID: String
    public var params: [String: ParamValue]
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
    /// Adjustment layer: apply `effects` to everything composited so far, blended by `opacity`.
    case adjustment(clipID: ClipID, effects: [ResolvedEffect], opacity: Double, localTime: Time)
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
    public var mediaLayers: [LayerDescription] {
        items.flatMap { item -> [LayerDescription] in
            switch item {
            case .layer(let l): return [l]
            case .transition(let a, let b, _, _, _): return [a, b]
            case .adjustment: return []
            }
        }.filter { if case .media = $0.source { return true }; return false }
    }
}

/// Evaluates a project at a time. Cost: O(tracks · log clips). Safe to call from any thread.
public enum FrameEvaluator {
    public static func evaluate(_ project: Project, at t: Time) -> FrameDescription {
        var items: [RenderItem] = []
        let canvas = project.settings.canvasSize
        for track in project.timeline.tracks where track.kind.isVisual && !track.isHidden {
            let active = track.clips(at: t).filter(\.isEnabled)
            guard !active.isEmpty else { continue }
            if active.count >= 2, track.isMain,
               let a = active.first, let b = active.dropFirst().first, let tr = a.transitionOut {
                // a ends inside b's head: transition region is [b.start, a.end)
                guard let la = layer(a, track: track, project: project, at: t),
                      let lb = layer(b, track: track, project: project, at: t) else { continue }
                let d = max(tr.duration.ticks, 1)
                let p = min(max(Double((t - b.start).ticks) / Double(d), 0), 1)
                items.append(.transition(from: la, to: lb, typeID: tr.typeID, progress: p, params: tr.params))
                continue
            }
            for c in active {
                if case .adjustment = c.content {
                    let local = c.localTime(t)
                    let r = c.resolved(at: local)
                    items.append(.adjustment(clipID: c.id, effects: resolveEffects(r), opacity: r.opacity, localTime: local))
                } else if let l = layer(c, track: track, project: project, at: t) {
                    items.append(.layer(l))
                }
            }
        }
        return FrameDescription(time: t, canvasSize: canvas, background: project.settings.backgroundColor, items: items,
                                colorSpace: project.settings.colorSpace)
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
        case .text(let text):
            // Real size is known only after rasterization (engine measures the text); placement uses `.native`.
            source = .text(text); size = .zero
        case .solid(let color):
            source = .solid(color); size = project.settings.canvasSize
        case .sticker(let id):
            let side = project.settings.canvasSize.height * 0.35
            source = .sticker(id: id); size = Size2(side, side)
        case .adjustment:
            return nil
        }
        return LayerDescription(clipID: c.id, trackID: track.id, source: source, sourceSize: size,
                                transform: r.transform, opacity: r.opacity, blendMode: r.blendMode, crop: r.crop,
                                mask: r.mask, effects: resolveEffects(r), animations: animations(c, local: local),
                                localTime: local)
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
    }

    /// Corners (TL, TR, BL, BR) in canvas pixels.
    public var corners: [Vec2] {
        let c = cos(rotation), s = sin(rotation)
        return [Vec2(-1, -1), Vec2(1, -1), Vec2(-1, 1), Vec2(1, 1)].map { k in
            let x = k.x * halfSize.x, y = k.y * halfSize.y
            return Vec2(center.x + x * c - y * s, center.y + x * s + y * c)
        }
    }

    /// Whether a canvas point lies inside the (rotated) layer.
    public func contains(_ p: Vec2) -> Bool {
        let c = cos(-rotation), s = sin(-rotation)
        let d = p - center
        let x = d.x * c - d.y * s, y = d.x * s + d.y * c
        return abs(x) <= abs(halfSize.x) && abs(y) <= abs(halfSize.y)
    }
}
