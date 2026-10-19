import Foundation

// Multiple masks (MK-005, CapCut "Mask %d (%s)"): a clip has its primary `mask` (Mask 1) plus up to three more
// (`extraMasks`, Masks 2…4). The visible area is the union of every mask (each with its own shape, feather, invert and
// keyframes: `mask<N>.center`, `mask<N>.size`…).
extension Clip {
    public static let maxMasks = 4

    /// Mask `n` (1 = `mask`, 2… = `extraMasks[n - 2]`).
    public func mask(_ n: Int) -> Mask? {
        n <= 1 ? mask : extraMasks.flatMap { n - 2 < $0.count ? $0[n - 2] : nil }
    }

    public mutating func setMask(_ n: Int, _ m: Mask?) {
        if n <= 1 { mask = m; return }
        var list = extraMasks ?? []
        let i = n - 2
        if let m {
            if i < list.count { list[i] = m } else if i == list.count { list.append(m) } else { return }
        } else if i < list.count {
            list.remove(at: i)
        }
        extraMasks = list.isEmpty ? nil : list
    }

    /// Number of masks (0…4).
    public var maskCount: Int { mask == nil ? 0 : 1 + (extraMasks?.count ?? 0) }

    /// Removes mask `n` and renumbers the later ones (their keyframes follow).
    public mutating func removeMask(_ n: Int) {
        let count = maskCount
        guard n >= 1, n <= count else { return }
        clearKeyframes(ParamKey.maskGroup(n))
        for k in n..<count {
            setMask(k, mask(k + 1))
            for (a, b) in zip(ParamKey.maskGroup(k), ParamKey.maskGroup(k + 1)) { keyframes[a.raw] = keyframes[b.raw] }
        }
        clearKeyframes(ParamKey.maskGroup(count))
        if count == 1 { mask = nil } else { setMask(count, nil) }
    }

    /// Masks 2…4 as optional properties (key paths for the inspector / canvas).
    public var mask2: Mask? { get { mask(2) } set { setMask(2, newValue) } }
    public var mask3: Mask? { get { mask(3) } set { setMask(3, newValue) } }
    public var mask4: Mask? { get { mask(4) } set { setMask(4, newValue) } }

    public static func maskKeyPath(_ n: Int) -> WritableKeyPath<Clip, Mask?> {
        switch n { case 2: return \.mask2; case 3: return \.mask3; case 4: return \.mask4; default: return \.mask }
    }
}

extension ParamKey {
    /// Keyframe keys of mask `n` (1 = the primary `mask.*` keys).
    public static func maskParam(_ n: Int, _ p: String) -> ParamKey { ParamKey(n <= 1 ? "mask.\(p)" : "mask\(n).\(p)") }
    public static func maskGroup(_ n: Int) -> [ParamKey] { ["center", "rotation", "size", "feather", "roundness"].map { maskParam(n, $0) } }

    /// Animatable properties of masks 2…4.
    static var extraMaskProperties: [AnimatableProperty] {
        func prop(_ n: Int, _ p: String, _ name: String, get: @escaping @Sendable (Mask?) -> AnimValue,
                  set: @escaping @Sendable (inout Mask, AnimValue) -> Void) -> AnimatableProperty {
            .init(key: maskParam(n, p), nameKey: name, get: { get($0.mask(n)) },
                  set: { c, v in if var m = c.mask(n) { set(&m, v); c.setMask(n, m) } })
        }
        return (2...Clip.maxMasks).flatMap { n -> [AnimatableProperty] in [
            prop(n, "center", "prop.maskCenter", get: { .vec2($0?.center ?? .zero) }, set: { m, v in if let v = v.vec2 { m.center = v } }),
            prop(n, "size", "prop.maskSize", get: { .vec2($0?.size ?? .one) }, set: { m, v in if let v = v.vec2 { m.size = v } }),
            prop(n, "feather", "prop.maskFeather", get: { .scalar($0?.feather ?? 0) }, set: { m, v in if let v = v.scalar { m.feather = v } }),
            prop(n, "rotation", "prop.maskRotation", get: { .scalar($0?.rotation ?? 0) }, set: { m, v in if let v = v.scalar { m.rotation = v } }),
            prop(n, "roundness", "prop.maskRoundness", get: { .scalar($0?.roundness ?? 0) }, set: { m, v in if let v = v.scalar { m.roundness = v } }),
        ] }
    }
}
