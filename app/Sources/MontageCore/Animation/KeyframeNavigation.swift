import Foundation

/// Keyframe queries and edits over a *group* of properties — what an inspector diamond operates on.
///
/// CapCut puts a `‹ ◇ ›` triplet on every row (one property, e.g. Opacity) and on section headers (a group, e.g.
/// Position & Size = position + scale + rotation). A group behaves like one property: the diamond is filled when any
/// member has a keyframe at the playhead, toggling adds a keyframe for every member (at its current value) or removes
/// them all, and prev/next jump over the union of the members' keyframe times.
extension Clip {
    /// Sorted, de-duplicated clip-local times of every keyframe of `keys`.
    public func keyframeTimes(_ keys: [ParamKey]) -> [Time] {
        var set = Set<Time>()
        for k in keys { keyframes[k.raw]?.keyframes.forEach { set.insert($0.time) } }
        return set.sorted()
    }

    public func hasKeyframes(_ keys: [ParamKey]) -> Bool { keys.contains { hasKeyframes($0) } }

    /// Whether any of `keys` has a keyframe within `tolerance` of `local`.
    public func isOnKeyframe(_ keys: [ParamKey], at local: Time, tolerance: Time) -> Bool {
        keys.contains { keyframes[$0.raw]?.index(near: local, tolerance: tolerance) != nil }
    }

    /// Latest keyframe time strictly before `local - tolerance` (inspector ‹).
    public func previousKeyframe(_ keys: [ParamKey], before local: Time, tolerance: Time) -> Time? {
        keyframeTimes(keys).last { $0 < local - tolerance }
    }

    /// Earliest keyframe time strictly after `local + tolerance` (inspector ›).
    public func nextKeyframe(_ keys: [ParamKey], after local: Time, tolerance: Time) -> Time? {
        keyframeTimes(keys).first { $0 > local + tolerance }
    }

    /// Group diamond: removes the members' keyframes at `local` if there are any, else adds one per member holding
    /// its current (resolved) value. Members without a value (e.g. mask props with no mask) are skipped.
    public mutating func toggleKeyframes(_ keys: [ParamKey], at local: Time, tolerance: Time) {
        if isOnKeyframe(keys, at: local, tolerance: tolerance) {
            for k in keys { removeKeyframe(k, at: local, tolerance: tolerance) }
        } else {
            for k in keys { addKeyframe(k, at: local, tolerance: tolerance) }
        }
    }

    /// Adds (or refreshes) a keyframe holding the property's current value at `local`.
    public mutating func addKeyframe(_ key: ParamKey, at local: Time, tolerance: Time = Time(ticks: 1)) {
        guard let v = value(key, at: local) else { return }
        var track = keyframes[key.raw] ?? KeyframeTrack()
        track.set(v, at: local, tolerance: tolerance)
        keyframes[key.raw] = track
    }

    public mutating func removeKeyframe(_ key: ParamKey, at local: Time, tolerance: Time = Time(ticks: 1)) {
        guard var track = keyframes[key.raw] else { return }
        track.remove(near: local, tolerance: tolerance)
        keyframes[key.raw] = track.isEmpty ? nil : track
    }

    /// Drops every keyframe of `keys` (section reset).
    public mutating func clearKeyframes(_ keys: [ParamKey]) {
        for k in keys { keyframes[k.raw] = nil }
    }

    /// Keyframe keys of every parameter of one effect instance (effect section diamonds / reset).
    public func effectParamKeys(_ instance: EffectInstanceID) -> [ParamKey] {
        guard let e = effects.first(where: { $0.id == instance }) else { return [] }
        return e.params.keys.sorted().map { ParamKey.effect(instance, $0) }
    }

    /// Edits a value with CapCut semantics through a closure on the *current* value, so multi-component properties
    /// (position x/y, scale x/y, mask size w/h) can change one component without touching the others.
    public mutating func modifyValue(_ key: ParamKey, at local: Time, _ body: (inout AnimValue) -> Void) {
        guard var v = value(key, at: local) else { return }
        body(&v)
        setValue(key, v, at: local)
    }
}

extension AnimValue {
    /// Replace one component (0 = x/scalar, 1 = y). Colours are left untouched.
    public func with(component i: Int, _ x: Double) -> AnimValue {
        switch self {
        case .scalar: return .scalar(x)
        case .vec2(var v): if i == 0 { v.x = x } else { v.y = x }; return .vec2(v)
        case .color: return self
        }
    }

    public func component(_ i: Int) -> Double? {
        switch self {
        case .scalar(let v): return v
        case .vec2(let v): return i == 0 ? v.x : v.y
        case .color: return nil
        }
    }
}
