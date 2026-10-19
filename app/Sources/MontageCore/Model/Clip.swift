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
    /// Compound clip: plays a nested timeline (`Project.compounds`), see Compound.swift.
    case compound(CompoundID)

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
    /// Canvas fill behind a main-track clip (CapCut Video ▸ Basic ▸ Canvas). nil = None (project background shows).
    public var canvas: CanvasBackground?
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
    public var matte: ClipMatte?
    public var smoothSlowMo: SlowMotionMethod?
    public var motionBlur: MotionBlur?
    public var stabilization: Stabilization?
    // Timeline editing (W1). Optional so older project files decode unchanged.
    /// Clips sharing a group id move / select together (CapCut "Group", ⌘G).
    public var groupID: ClipGroupID?
    /// Freeze-frame clip (CapCut "Freeze"): holds one source frame; trimming keeps the one-frame source extent.
    public var freezeFrame: Bool?
    /// Freeze frame linked to its original clip (TL-013 "Link freeze frame clips to original video"): the original's
    /// look (transform, opacity, blend, crop, mask, canvas, effects, enhance, relight) is copied onto it after every edit
    /// (`FreezeLinks.sync`). nil = independent.
    public var freezeSource: ClipID?
    /// Beat markers in clip-local time (CapCut "Mark beats" on audio clips). Clips snap to them.
    public var beats: [Time]?
    /// Clip markers (TL-025) in clip-local time: added with M while the clip is selected, move with the clip. nil = none.
    public var markers: [Marker]?
    /// Audio clip extracted from this video clip ("Extract audio"): id of the source clip.
    public var extractedFrom: ClipID?
    /// Clip colour label index (TL-040), nil = default kind colour.
    public var colorLabel: Int?
    /// Text-to-speech provenance (W10): this audio clip speaks a text clip. See Captions/TTSModel.swift.
    public var tts: TTSInfo?
    /// Auto reframe applied to this clip (W10, AI/Reframe.swift): its position keyframes come from subject tracking.
    public var reframe: ReframeOptions?
    /// Motion tracking (W10, AI/MotionTracking.swift): this clip's position/scale keyframes follow a tracked object.
    public var tracking: MotionTrackInfo?
    /// Reduce image noise / Remove flickers / Enhance quality (W10, AI/VideoEnhance.swift): the clip plays a processed
    /// copy of its media; `enhance.original` is the media to restore.
    public var enhance: VideoEnhancement?
    /// Camera tracking / lens lock (W10, AI/CameraLock.swift): position/scale keyframes keep a person centred.
    public var cameraLock: CameraLockOptions?
    /// AI remove (W10): the clip plays an inpainted copy of `removal.original`.
    public var removal: ObjectRemovalInfo?
    /// Adjust ▸ Mask (W3): limits the clip's Adjust-tab grading (adjustment-category effects) to a region.
    public var adjustMask: Mask?
    /// AI movement (AI2, AI/AIMovement.swift): position/scale(/rotation) keyframes of a subject-centred camera move.
    public var aiMovement: AIMovementOptions?
    /// Relight (AI2, AI/Relight.swift): virtual lights shaded on a depth map of the media.
    public var relight: RelightSettings?
    /// Adjust ▸ LUT ▸ Skin tone protection (CL-010): the Adjust-tab grading is held back on skin tones. nil = off.
    public var skinToneProtection: Bool?
    /// Face cover sticker (ST-006): this sticker clip follows a face of that clip (MontageAI `FaceStickers`).
    public var faceCoverOf: ClipID?
    /// Masks 2…4 (MK-005, see MultiMask.swift); the layer shows the union of `mask` and these.
    public var extraMasks: [Mask]?
    /// Shape sticker look (ST-008, see ShapeStickerStyle.swift); nil = the sticker's own colours.
    public var shapeStyle: ShapeStickerStyle?
    /// Effect / filter clip ▸ "Apply to" (FX-004, see EffectScope.swift): which layers below it the effects process.
    /// nil = all (CapCut default).
    public var effectScope: EffectScope?
    /// HDR conversion (CL-014, see HDRConversion.swift); nil = the default conversion.
    public var hdrConversion: HDRConversion?

    public var isFreezeFrame: Bool { freezeFrame ?? false }

    public init(content: ClipContent, start: Time, duration: Time, sourceStart: Time = .zero) {
        id = ClipID(); self.content = content; self.start = start; self.duration = duration
        self.sourceStart = sourceStart; speed = .normal; reversed = false; isEnabled = true
        transform = Transform(); opacity = 1; blendMode = .normal; crop = CropRect(); mask = nil; canvas = nil
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
    /// 3D planar rotation (CV-018), degrees: x = tilt around the horizontal axis (top edge away from the viewer for
    /// positive values), y = around the vertical axis (right edge away). Perspective-projected by `LayerGeometry`.
    public var tilt: Vec2
    public init(position: Vec2 = .zero, scale: Vec2 = .one, rotation: Double = 0, flipH: Bool = false, flipV: Bool = false,
                tilt: Vec2 = .zero) {
        self.position = position; self.scale = scale; self.rotation = rotation; self.flipH = flipH; self.flipV = flipV
        self.tilt = tilt
    }
    public static let identity = Transform()

    enum CodingKeys: String, CodingKey { case position, scale, rotation, flipH, flipV, tilt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Vec2.self, forKey: .position)
        scale = try c.decode(Vec2.self, forKey: .scale)
        rotation = try c.decode(Double.self, forKey: .rotation)
        flipH = try c.decode(Bool.self, forKey: .flipH)
        flipV = try c.decode(Bool.self, forKey: .flipV)
        tilt = try c.decodeIfPresent(Vec2.self, forKey: .tilt) ?? .zero   // added by CV-018: older files have none
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position); try c.encode(scale, forKey: .scale); try c.encode(rotation, forKey: .rotation)
        try c.encode(flipH, forKey: .flipH); try c.encode(flipV, forKey: .flipV)
        if tilt != .zero { try c.encode(tilt, forKey: .tilt) }
    }
}

/// Normalized crop insets (0…1 of the source on each side).
public struct CropRect: Hashable, Codable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    /// Rotation of the image inside the crop window, degrees clockwise (crop dialog "Rotate", CV-006); nil = 0.
    /// The sampled window zooms in just enough to stay inside the source (`CropGeometry`).
    public var rotation: Double?
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0, rotation: Double? = nil) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom; self.rotation = rotation
    }
    public var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 && (rotation ?? 0) == 0 }
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
    // analytic shapes (shader indices = positions, never reorder) …
    case linear, mirror, circle, rectangle, heart, star
    // … then rasterized ones (W3-7): glyph outlines of `Mask.text`, closed smooth path through `Mask.points`.
    case text, pen
    /// Painted region (CL-012 Adjust mask "Quick brush" / "Quick eraser"): `Mask.strokes`, rasterized too.
    case brush
    public var nameKey: String { "mask.\(rawValue)" }
    /// Drawn on the CPU into a mask texture instead of evaluated in the placement shader.
    public var isRaster: Bool { self == .text || self == .pen || self == .brush }
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
    /// Text mask: the string whose glyphs cut the mask (fitted into the mask box).
    public var text: String?
    /// Pen mask: closed smooth path through these points, in mask-box units (−0.5…0.5, y down).
    public var points: [Vec2]?
    /// Brush mask: painted / erased strokes in paint order (mask-box units).
    public var strokes: [MaskStroke]?
    /// Brush mask tracked through the clip (MK-004): the region's shape per source frame; when set it replaces the
    /// strokes at render time (`Mask.atSource`).
    public var propagation: MaskPropagation?
    public init(shape: MaskShape, center: Vec2 = .zero, size: Vec2 = Vec2(0.5, 0.5), rotation: Double = 0,
                feather: Double = 0, roundness: Double = 0, inverted: Bool = false) {
        self.shape = shape; self.center = center; self.size = size; self.rotation = rotation
        self.feather = feather; self.roundness = roundness; self.inverted = inverted
    }

    /// Default pen outline (an organic blob filling the mask box) until the user moves the points.
    public static let defaultPenPoints: [Vec2] = [0.5, 0.42, 0.48, 0.4, 0.5, 0.44, 0.47].enumerated().map { i, r in
        let a = Double(i) / 7 * 2 * .pi - .pi / 2
        return Vec2(cos(a) * r, sin(a) * r)
    }
}

/// One brush stroke of a brush mask (CL-012): a round-capped polyline through `points` (mask-box units, y down) of
/// radius `radius` (fraction of the layer height); `erase` strokes remove coverage.
public struct MaskStroke: Hashable, Codable, Sendable {
    public var points: [Vec2]
    public var radius: Double
    public var erase: Bool
    /// Smart brush (CL-012): the object picked under the stroke as filled closed contours (mask-box units, even-odd
    /// fill, so holes stay holes). Drawn instead of the polyline when set.
    public var region: [[Vec2]]?
    public init(points: [Vec2], radius: Double, erase: Bool = false, region: [[Vec2]]? = nil) {
        self.points = points; self.radius = radius; self.erase = erase; self.region = region
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

    // Audio effects (W8, see AudioEffects.swift). All optional / neutral by default.
    /// "Change pitch" in semitones (−12…12), independent of speed. Formants are preserved.
    public var pitch: Double
    /// Voice changer preset, nil = "Original".
    public var voice: VoiceEffect?
    /// "Reduce noise" strength 0…1, nil = off.
    public var noiseReduction: Double?
    /// "Enhance voice" strength 0…1, nil = off.
    public var enhanceVoice: Double?
    /// "Isolate voice" keep/remove vocals, nil = off.
    public var separation: VocalSeparation?
    public var loudness: LoudnessNormalization?
    public var eq: AudioEQ?
    public var channels: ChannelMode
    public var ducking: AudioDucking?

    public init() {
        volume = 1; fadeIn = .zero; fadeOut = .zero; isMuted = false; preservePitch = true
        pitch = 0; voice = nil; noiseReduction = nil; enhanceVoice = nil; separation = nil; loudness = nil; eq = nil
        channels = .stereo; ducking = nil
    }

    // Files written before the audio effects existed lack the new keys: every field decodes with a default.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try c.decodeIfPresent(Time.self, forKey: .fadeIn) ?? .zero
        fadeOut = try c.decodeIfPresent(Time.self, forKey: .fadeOut) ?? .zero
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        preservePitch = try c.decodeIfPresent(Bool.self, forKey: .preservePitch) ?? true
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        voice = try c.decodeIfPresent(VoiceEffect.self, forKey: .voice)
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction)
        enhanceVoice = try c.decodeIfPresent(Double.self, forKey: .enhanceVoice)
        separation = try c.decodeIfPresent(VocalSeparation.self, forKey: .separation)
        loudness = try c.decodeIfPresent(LoudnessNormalization.self, forKey: .loudness)
        eq = try c.decodeIfPresent(AudioEQ.self, forKey: .eq)
        channels = try c.decodeIfPresent(ChannelMode.self, forKey: .channels) ?? .stereo
        ducking = try c.decodeIfPresent(AudioDucking.self, forKey: .ducking)
    }

    /// The clip contributes sound to the mix.
    public var isAudible: Bool { !isMuted }

    public static func decibels(_ gain: Double) -> Double { gain <= 0 ? -.infinity : 20 * log10(gain) }
}

// Text model (TextContent, TextAlignment…) lives in MontageCore/Text/ (text engine, W7).
