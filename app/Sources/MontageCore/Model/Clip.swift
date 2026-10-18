import Foundation

/// What a clip shows.
public enum ClipContent: Hashable, Codable, Sendable {
    /// Video, audio or image from the media bin.
    case media(MediaID)
    case text(TextContent)
    /// Solid colour generator (CapCut "Background"/blank clips).
    case solid(RGBA)
    /// Sticker from a sticker pack (`StickerRegistry` id) — rendered as an image layer.
    case sticker(id: String)
    /// Adjustment layer: no own pixels, `Clip.effects` apply to everything composited below it
    /// (CapCut effect / filter / adjustment clips on their own tracks).
    case adjustment

    public var mediaID: MediaID? { if case .media(let id) = self { return id }; return nil }
    public var isGenerator: Bool { mediaID == nil }
}

/// A clip on a track. All timing is in timeline time except `sourceStart` (media time).
public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public var id: ClipID
    public var name: String?
    public var content: ClipContent
    /// Timeline position.
    public var start: Time
    /// Timeline duration (output). For media clips the consumed source extent is `speed.sourceDuration(forOutput:)`.
    public var duration: Time
    /// In-point inside the media (media clips only).
    public var sourceStart: Time
    public var speed: Speed
    /// Play the source backwards (needs a reversed render, see ARCHITECTURE "Reverse").
    public var reversed: Bool
    public var isEnabled: Bool

    // Visual
    public var transform: Transform
    public var opacity: Double
    public var blendMode: BlendMode
    public var crop: CropRect
    public var mask: Mask?
    /// Filters / effects / adjustments applied in order (registry ids, see MontageEffects).
    public var effects: [EffectInstance]
    /// Transition into the *next* clip on the same track (main track).
    public var transitionOut: TransitionInstance?
    public var animations: ClipAnimations

    // Audio
    public var audio: AudioProps
    /// Audio stream of the media to play (multi-track files, MI-014). nil = first stream.
    public var audioStreamIndex: Int?

    /// Keyframe tracks keyed by `ParamKey.raw` (e.g. "transform.position", "opacity", "effect.<id>.<param>").
    public var keyframes: [String: KeyframeTrack]
    /// Linkage: this clip follows that main-track clip (CapCut "linkage").
    public var linkedTo: ClipID?

    // Render-engine features (W6/W9, see ClipRendering.swift). nil = off.
    public var chromaKey: ChromaKey?
    public var matte: ClipMatte?
    public var smoothSlowMo: SlowMotionMethod?
    public var motionBlur: MotionBlur?
    public var stabilization: Stabilization?
    // Timeline editing (W1). Optional so older project files decode unchanged.
    /// Clips sharing a group id move / select together (CapCut "Group", ⌘G).
    public var groupID: ClipGroupID?
    /// Freeze-frame clip (CapCut "Freeze"): holds one source frame; trimming keeps the one-frame source extent.
    public var freezeFrame: Bool?
    /// Beat markers in clip-local time (CapCut "Mark beats" on audio clips). Clips snap to them.
    public var beats: [Time]?
    /// Audio clip extracted from this video clip ("Extract audio"): id of the source clip.
    public var extractedFrom: ClipID?
    /// Clip colour label index (TL-040), nil = default kind colour.
    public var colorLabel: Int?

    public var isFreezeFrame: Bool { freezeFrame ?? false }

    public init(content: ClipContent, start: Time, duration: Time, sourceStart: Time = .zero) {
        id = ClipID(); self.content = content; self.start = start; self.duration = duration
        self.sourceStart = sourceStart; speed = .normal; reversed = false; isEnabled = true
        transform = Transform(); opacity = 1; blendMode = .normal; crop = CropRect(); mask = nil
        effects = []; transitionOut = nil; animations = ClipAnimations(); audio = AudioProps()
        keyframes = [:]; linkedTo = nil
    }

    public var end: Time { start + duration }
    public var range: TimeRange { TimeRange(start: start, duration: duration) }
    public var mediaID: MediaID? { content.mediaID }

    /// Source extent consumed by the clip.
    public var sourceDuration: Time { speed.sourceDuration(forOutput: duration) }
    public var sourceRange: TimeRange { TimeRange(start: sourceStart, duration: sourceDuration) }

    /// Media time shown at timeline time `t` (time remap incl. speed curve and reverse).
    public func sourceTime(at t: Time) -> Time {
        let local = (t - start).clamped(.zero, duration)
        let off = speed.sourceOffset(at: local, outputDuration: duration)
        return reversed ? sourceStart + sourceDuration - off : sourceStart + off
    }

    /// Clip-local time (0 at the clip's start) for timeline time `t`.
    public func localTime(_ t: Time) -> Time { t - start }
}

/// Position / scale / rotation in canvas-normalized units.
/// `position` is the offset of the layer centre from the canvas centre, in fractions of canvas width/height
/// (x → right, y → down). `scale` 1 = the source fitted inside the canvas (aspect-fit), like CapCut.
public struct Transform: Hashable, Codable, Sendable {
    public var position: Vec2
    public var scale: Vec2
    /// Degrees, clockwise.
    public var rotation: Double
    public var flipH: Bool
    public var flipV: Bool
    public init(position: Vec2 = .zero, scale: Vec2 = .one, rotation: Double = 0, flipH: Bool = false, flipV: Bool = false) {
        self.position = position; self.scale = scale; self.rotation = rotation; self.flipH = flipH; self.flipV = flipV
    }
    public static let identity = Transform()
}

/// Normalized crop insets (0…1 of the source on each side).
public struct CropRect: Hashable, Codable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

/// CapCut blend modes ("Mix mode"). Raw values are persisted and also index the shader switch.
public enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge, add, overlay, softLight, hardLight,
         difference, exclusion,
         // appended (shader indices are positions, never reorder): CapCut "Linear burn" + the usual pro set
         linearBurn, linearDodge, vividLight, linearLight, pinLight, hardMix, subtract, divide,
         hue, saturation, color, luminosity, darkerColor, lighterColor
    public var shaderIndex: Int { BlendMode.allCases.firstIndex(of: self)! }
    public var nameKey: String { "blend.\(rawValue)" }
}

public enum MaskShape: String, Codable, Sendable, CaseIterable {
    case linear, mirror, circle, rectangle, heart, star
    public var nameKey: String { "mask.\(rawValue)" }
}

/// Shape mask in layer-normalized coordinates (0,0 = layer centre, units of layer size).
public struct Mask: Hashable, Codable, Sendable {
    public var shape: MaskShape
    public var center: Vec2
    /// Width/height of the shape in layer units (circle/rectangle) — or band width (mirror).
    public var size: Vec2
    public var rotation: Double
    /// Edge softness 0…1.
    public var feather: Double
    /// Rectangle corner roundness 0…1.
    public var roundness: Double
    public var inverted: Bool
    public init(shape: MaskShape, center: Vec2 = .zero, size: Vec2 = Vec2(0.5, 0.5), rotation: Double = 0,
                feather: Double = 0, roundness: Double = 0, inverted: Bool = false) {
        self.shape = shape; self.center = center; self.size = size; self.rotation = rotation
        self.feather = feather; self.roundness = roundness; self.inverted = inverted
    }
}

/// Parameter value of an effect / transition / animation.
public enum ParamValue: Hashable, Codable, Sendable {
    case scalar(Double)
    case color(RGBA)
    case bool(Bool)
    /// Index into a choice list.
    case choice(Int)

    /// Flattened to floats for shaders (color → 4 floats).
    public var floats: [Float] {
        switch self {
        case .scalar(let v): return [Float(v)]
        case .color(let c): return [Float(c.r), Float(c.g), Float(c.b), Float(c.a)]
        case .bool(let b): return [b ? 1 : 0]
        case .choice(let i): return [Float(i)]
        }
    }
    public var scalar: Double? {
        switch self {
        case .scalar(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .choice(let i): return Double(i)
        case .color: return nil
        }
    }
    public var animValue: AnimValue? {
        switch self {
        case .scalar(let v): return .scalar(v)
        case .color(let c): return .color(c)
        default: return nil
        }
    }
}

/// One entry of a clip's effect stack (filter, effect or adjustment). `typeID` is a registry id from MontageEffects,
/// e.g. "montage.filter.mono". `params` is filled with the descriptor defaults when the instance is created.
public struct EffectInstance: Hashable, Codable, Sendable, Identifiable {
    public var id: EffectInstanceID
    public var typeID: String
    public var params: [String: ParamValue]
    public var isEnabled: Bool
    public init(typeID: String, params: [String: ParamValue] = [:]) {
        id = EffectInstanceID(); self.typeID = typeID; self.params = params; isEnabled = true
    }
}

public struct TransitionInstance: Hashable, Codable, Sendable {
    public var typeID: String
    public var duration: Time
    public var params: [String: ParamValue]
    public init(typeID: String, duration: Time = Time(0.5), params: [String: ParamValue] = [:]) {
        self.typeID = typeID; self.duration = duration; self.params = params
    }
}

/// In / out / combo ("loop") animation applied to a visual clip (video, image, text, sticker).
public struct AnimationInstance: Hashable, Codable, Sendable {
    public var typeID: String
    public var duration: Time
    public init(typeID: String, duration: Time = Time(0.5)) { self.typeID = typeID; self.duration = duration }
}

public struct ClipAnimations: Hashable, Codable, Sendable {
    public var inAnim: AnimationInstance?
    public var outAnim: AnimationInstance?
    /// Combo animation spans the whole clip (mutually exclusive with in/out in CapCut).
    public var combo: AnimationInstance?
    public init() {}
}

public struct AudioProps: Hashable, Codable, Sendable {
    /// Linear gain (1 = 100 %, CapCut range 0…10 i.e. up to +20 dB).
    public var volume: Double
    public var fadeIn: Time
    public var fadeOut: Time
    public var isMuted: Bool
    /// Keep pitch when speed ≠ 1 (CapCut "Pitch" toggle off = chipmunk).
    public var preservePitch: Bool
    public init() { volume = 1; fadeIn = .zero; fadeOut = .zero; isMuted = false; preservePitch = true }

    public static func decibels(_ gain: Double) -> Double { gain <= 0 ? -.infinity : 20 * log10(gain) }
}

public enum TextAlignment: String, Codable, Sendable { case left, center, right }

/// Text clip content. Sizes are canvas-relative so a project renders identically at any export resolution.
public struct TextContent: Hashable, Codable, Sendable {
    public var string: String
    /// PostScript or family name; empty = system font.
    public var fontName: String
    /// Font size as a fraction of canvas height (CapCut default ≈ 15 → 0.06).
    public var fontSize: Double
    public var color: RGBA
    public var alignment: TextAlignment
    public var bold: Bool
    public var italic: Bool
    public var strokeColor: RGBA
    public var strokeWidth: Double
    public var backgroundColor: RGBA
    public var shadowColor: RGBA
    public var lineSpacing: Double
    public var letterSpacing: Double
    /// Text style preset id (registry), if any.
    public var styleID: String?

    public init(string: String, fontName: String = "", fontSize: Double = 0.06, color: RGBA = .white,
                alignment: TextAlignment = .center) {
        self.string = string; self.fontName = fontName; self.fontSize = fontSize; self.color = color
        self.alignment = alignment; bold = false; italic = false
        strokeColor = .black; strokeWidth = 0; backgroundColor = .clear; shadowColor = .clear
        lineSpacing = 0; letterSpacing = 0; styleID = nil
    }
}
