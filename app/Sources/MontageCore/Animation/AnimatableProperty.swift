import Foundation

/// Key of an animatable clip property. Built-ins are listed in `AnimatableProperties`; effect parameters use
/// `ParamKey.effect(instance, param)`. Keys are persisted in `Clip.keyframes`, so never rename one.
public struct ParamKey: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value }
    public var description: String { raw }

    public static let position: ParamKey = "transform.position"
    public static let scale: ParamKey = "transform.scale"
    public static let rotation: ParamKey = "transform.rotation"
    public static let opacity: ParamKey = "opacity"
    public static let volume: ParamKey = "audio.volume"
    public static let maskCenter: ParamKey = "mask.center"
    public static let maskSize: ParamKey = "mask.size"
    public static let maskFeather: ParamKey = "mask.feather"
    public static let maskRotation: ParamKey = "mask.rotation"
    public static let textColor: ParamKey = "text.color"
    public static let maskRoundness: ParamKey = "mask.roundness"
    public static let cropLeft: ParamKey = "crop.left"
    public static let cropTop: ParamKey = "crop.top"
    public static let cropRight: ParamKey = "crop.right"
    public static let cropBottom: ParamKey = "crop.bottom"

    /// Inspector groups (section-level diamonds).
    public static let transformGroup: [ParamKey] = [.scale, .position, .rotation]
    public static let maskGroup: [ParamKey] = [.maskCenter, .maskRotation, .maskSize, .maskFeather, .maskRoundness]
    public static let cropGroup: [ParamKey] = [.cropLeft, .cropTop, .cropRight, .cropBottom]

    public static func effect(_ id: EffectInstanceID, _ param: String) -> ParamKey { ParamKey("effect.\(id.raw.uuidString).\(param)") }

    /// Parses "effect.<uuid>.<param>".
    public var effectParam: (EffectInstanceID, String)? {
        guard raw.hasPrefix("effect.") else { return nil }
        let rest = raw.dropFirst("effect.".count)
        guard let dot = rest.firstIndex(of: "."), let id = EffectInstanceID(string: String(rest[..<dot])) else { return nil }
        return (id, String(rest[rest.index(after: dot)...]))
    }
}

/// Getter/setter for one built-in animatable property.
public struct AnimatableProperty: Sendable {
    public let key: ParamKey
    /// Localization key for the inspector label.
    public let nameKey: String
    public let get: @Sendable (Clip) -> AnimValue
    public let set: @Sendable (inout Clip, AnimValue) -> Void
}

/// Table of built-in animatable properties. To make a new clip property keyframeable add one entry here
/// (and a `ParamKey` constant). Effect parameters are animatable automatically.
public enum AnimatableProperties {
    public static let all: [AnimatableProperty] = [
        .init(key: .position, nameKey: "prop.position", get: { .vec2($0.transform.position) },
              set: { c, v in if let v = v.vec2 { c.transform.position = v } }),
        .init(key: .scale, nameKey: "prop.scale", get: { .vec2($0.transform.scale) },
              set: { c, v in if let v = v.vec2 { c.transform.scale = v } }),
        .init(key: .rotation, nameKey: "prop.rotation", get: { .scalar($0.transform.rotation) },
              set: { c, v in if let v = v.scalar { c.transform.rotation = v } }),
        .init(key: .opacity, nameKey: "prop.opacity", get: { .scalar($0.opacity) },
              set: { c, v in if let v = v.scalar { c.opacity = v } }),
        .init(key: .volume, nameKey: "prop.volume", get: { .scalar($0.audio.volume) },
              set: { c, v in if let v = v.scalar { c.audio.volume = v } }),
        .init(key: .maskCenter, nameKey: "prop.maskCenter", get: { .vec2($0.mask?.center ?? .zero) },
              set: { c, v in if let v = v.vec2 { c.mask?.center = v } }),
        .init(key: .maskSize, nameKey: "prop.maskSize", get: { .vec2($0.mask?.size ?? .one) },
              set: { c, v in if let v = v.vec2 { c.mask?.size = v } }),
        .init(key: .maskFeather, nameKey: "prop.maskFeather", get: { .scalar($0.mask?.feather ?? 0) },
              set: { c, v in if let v = v.scalar { c.mask?.feather = v } }),
        .init(key: .maskRotation, nameKey: "prop.maskRotation", get: { .scalar($0.mask?.rotation ?? 0) },
              set: { c, v in if let v = v.scalar { c.mask?.rotation = v } }),
        .init(key: .maskRoundness, nameKey: "prop.maskRoundness", get: { .scalar($0.mask?.roundness ?? 0) },
              set: { c, v in if let v = v.scalar { c.mask?.roundness = v } }),
        .init(key: .cropLeft, nameKey: "prop.cropLeft", get: { .scalar($0.crop.left) },
              set: { c, v in if let v = v.scalar { c.crop.left = v } }),
        .init(key: .cropTop, nameKey: "prop.cropTop", get: { .scalar($0.crop.top) },
              set: { c, v in if let v = v.scalar { c.crop.top = v } }),
        .init(key: .cropRight, nameKey: "prop.cropRight", get: { .scalar($0.crop.right) },
              set: { c, v in if let v = v.scalar { c.crop.right = v } }),
        .init(key: .cropBottom, nameKey: "prop.cropBottom", get: { .scalar($0.crop.bottom) },
              set: { c, v in if let v = v.scalar { c.crop.bottom = v } }),
        .init(key: .textColor, nameKey: "prop.textColor",
              get: { if case .text(let t) = $0.content { return .color(t.color) }; return .color(.white) },
              set: { c, v in if case .text(var t) = c.content, let col = v.color { t.color = col; c.content = .text(t) } }),
    ]

    private static let byKey: [ParamKey: AnimatableProperty] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    public static func property(_ key: ParamKey) -> AnimatableProperty? { byKey[key] }
}

extension Clip {
    /// Static (un-keyframed) value of a property.
    public func baseValue(_ key: ParamKey) -> AnimValue? {
        if let p = AnimatableProperties.property(key) { return p.get(self) }
        if let (id, name) = key.effectParam, let e = effects.first(where: { $0.id == id }) { return e.params[name]?.animValue }
        return nil
    }

    /// Writes the static value of a property (no keyframe).
    public mutating func setBaseValue(_ key: ParamKey, _ value: AnimValue) {
        if let p = AnimatableProperties.property(key) { p.set(&self, value); return }
        if let (id, name) = key.effectParam, let i = effects.firstIndex(where: { $0.id == id }) {
            switch value {
            case .scalar(let v): effects[i].params[name] = .scalar(v)
            case .color(let c): effects[i].params[name] = .color(c)
            case .vec2: break
            }
        }
    }

    /// Value at clip-local time: keyframed if the property has keyframes, else the base value.
    public func value(_ key: ParamKey, at local: Time) -> AnimValue? {
        if let track = keyframes[key.raw], let v = track.value(at: local) { return v }
        return baseValue(key)
    }

    public func hasKeyframes(_ key: ParamKey) -> Bool { !(keyframes[key.raw]?.isEmpty ?? true) }

    /// CapCut semantics: if the property already has keyframes, editing it at the playhead adds/updates a keyframe
    /// there; otherwise it changes the static value.
    public mutating func setValue(_ key: ParamKey, _ value: AnimValue, at local: Time) {
        if var track = keyframes[key.raw], !track.isEmpty {
            track.set(value, at: local)
            keyframes[key.raw] = track
        } else {
            setBaseValue(key, value)
        }
    }

    /// Toggles a keyframe at `local` (the inspector diamond).
    public mutating func toggleKeyframe(_ key: ParamKey, at local: Time, tolerance: Time) {
        var track = keyframes[key.raw] ?? KeyframeTrack()
        if track.index(near: local, tolerance: tolerance) != nil {
            track.remove(near: local, tolerance: tolerance)
        } else if let v = value(key, at: local) {
            track.set(v, at: local)
        }
        keyframes[key.raw] = track.isEmpty ? nil : track
    }

    /// A copy with every keyframed property replaced by its value at clip-local time `local`.
    /// The renderer and the inspector both read resolved clips, so preview/export/UI agree.
    public func resolved(at local: Time) -> Clip {
        guard !keyframes.isEmpty else { return self }
        var c = self
        for (raw, track) in keyframes {
            guard let v = track.value(at: local) else { continue }
            c.setBaseValue(ParamKey(raw), v)
        }
        return c
    }
}
