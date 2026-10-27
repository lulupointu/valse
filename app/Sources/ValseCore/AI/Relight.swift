import Foundation

// Relight / Ajout de lumière (AI2, AI-024 / CL-020, UX_AI §4.10): virtual lights shaded on a depth map of the media.
// The depth pass runs once per media in ValseAI (`RelightDepth`, Depth Anything V2 Core ML, or a Vision person
// matte + luma pseudo-depth fallback) and is stored as a grey "depth" matte video; the renderer derives normals from
// it and shades every frame in real time (FrameRenderer+Relight), so every slider here updates the player live.

public struct RelightLight: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case point, directional
        public var nameKey: String { "relight.type.\(rawValue)" }
    }
    public var kind: Kind
    /// Light position on the layer, 0…1 (origin top-left). Directional lights shine from this point towards the centre.
    public var x: Double, y: Double
    public var color: RGBA
    /// Light strength 0…1 (× 2 in the shader).
    public var intensity: Double
    /// Exposure of the lit area 0…1 (0.5 = neutral).
    public var brightness: Double
    /// Reach of a point light, 0…1 of the layer diagonal.
    public var radius: Double
    /// Height of the light above the picture, 0…1 (low = grazing light, strong relief).
    public var distance: Double
    /// Specular highlights 0…1.
    public var highlights: Double
    /// Animation: circular motion speed, blinking speed, hue cycling (each 0…1, 0 = off).
    public var movingSpeed: Double
    public var blinkingSpeed: Double
    public var colorChanging: Double

    public init(kind: Kind = .point, x: Double = 0.3, y: Double = 0.3, color: RGBA = RGBA(1, 0.92, 0.8),
                intensity: Double = 0.6, brightness: Double = 0.5, radius: Double = 0.6, distance: Double = 0.4,
                highlights: Double = 0.3, movingSpeed: Double = 0, blinkingSpeed: Double = 0, colorChanging: Double = 0) {
        self.kind = kind; self.x = x; self.y = y; self.color = color; self.intensity = intensity; self.brightness = brightness
        self.radius = radius; self.distance = distance; self.highlights = highlights
        self.movingSpeed = movingSpeed; self.blinkingSpeed = blinkingSpeed; self.colorChanging = colorChanging
    }

    /// The light at clip-local time `t` (seconds) with its animations applied.
    public func resolved(at t: Double) -> RelightLight {
        var l = self
        if movingSpeed > 0 {
            // small circle around the set position (one turn every 8 s … 0.8 s)
            let w = 2 * Double.pi * (0.125 + movingSpeed * 1.125) * t
            l.x = x + 0.18 * cos(w) - 0.18
            l.y = y + 0.12 * sin(w)
        }
        if blinkingSpeed > 0 {
            let w = 2 * Double.pi * (0.5 + blinkingSpeed * 4) * t
            l.intensity = intensity * (0.55 + 0.45 * cos(w))
        }
        if colorChanging > 0 {
            l.color = Self.rotateHue(color, by: t * (0.05 + colorChanging * 0.45))
        }
        return l
    }

    /// Hue rotation by `turns` (fraction of 360°), keeps saturation/value (pure colour math, mirrored nowhere else).
    public static func rotateHue(_ c: RGBA, by turns: Double) -> RGBA {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 1e-6 else { return c }
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h = (h / 6 + turns).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let s = d / mx, v = mx
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), u = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return RGBA(v, u, p, c.a)
        case 1: return RGBA(q, v, p, c.a)
        case 2: return RGBA(p, v, u, c.a)
        case 3: return RGBA(p, q, v, c.a)
        case 4: return RGBA(u, p, v, c.a)
        default: return RGBA(v, p, q, c.a)
        }
    }
}

public struct RelightSettings: Hashable, Codable, Sendable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case facial, object, ambient, creative, custom
        public var nameKey: String { "relight.preset.\(rawValue)" }
    }
    /// What gets lit: people only (Vision person matte), the background only, or everything.
    public enum Target: String, Codable, Sendable, CaseIterable {
        case people, background, both
        public var nameKey: String { "relight.target.\(rawValue)" }
        /// Needs the person matte.
        public var usesPersonMatte: Bool { self != .both }
    }
    public var preset: Preset
    public var target: Target
    public var lights: [RelightLight]
    /// How much the unlit scene darkens, 0…1 (0 = no darkening).
    public var ambientDarkening: Double
    /// Relief strength of the depth-derived normals, 0…1.
    public var relief: Double

    public static let maxLights = 4

    public init(preset: Preset = .facial, target: Target = .both, lights: [RelightLight] = [RelightLight()],
                ambientDarkening: Double = 0.35, relief: Double = 0.5) {
        self.preset = preset; self.target = target; self.lights = lights
        self.ambientDarkening = ambientDarkening; self.relief = relief
    }

    /// CapCut-style one-tap looks.
    public static func preset(_ p: Preset) -> RelightSettings {
        switch p {
        case .facial:
            return RelightSettings(preset: .facial, target: .people, lights: [
                RelightLight(kind: .point, x: 0.28, y: 0.25, color: RGBA(1, 0.88, 0.74), intensity: 0.7, radius: 0.55,
                             distance: 0.45, highlights: 0.35)], ambientDarkening: 0.3, relief: 0.55)
        case .object:
            return RelightSettings(preset: .object, target: .both, lights: [
                RelightLight(kind: .directional, x: 0.8, y: 0.15, color: RGBA(1, 1, 1), intensity: 0.6, radius: 1,
                             distance: 0.35, highlights: 0.5)], ambientDarkening: 0.35, relief: 0.7)
        case .ambient:
            return RelightSettings(preset: .ambient, target: .background, lights: [
                RelightLight(kind: .directional, x: 0.5, y: 0.0, color: RGBA(0.62, 0.74, 1), intensity: 0.45, radius: 1,
                             distance: 0.7, highlights: 0.1)], ambientDarkening: 0.25, relief: 0.3)
        case .creative:
            return RelightSettings(preset: .creative, target: .both, lights: [
                RelightLight(kind: .point, x: 0.15, y: 0.4, color: RGBA(1, 0.2, 0.75), intensity: 0.75, radius: 0.5, distance: 0.35, highlights: 0.3),
                RelightLight(kind: .point, x: 0.85, y: 0.4, color: RGBA(0.15, 0.75, 1), intensity: 0.75, radius: 0.5, distance: 0.35,
                             highlights: 0.3, colorChanging: 0.3)], ambientDarkening: 0.5, relief: 0.5)
        case .custom:
            return RelightSettings(preset: .custom)
        }
    }

    /// Settings at clip-local time `t` (animated lights resolved, at most `maxLights`).
    public func resolved(at t: Double) -> RelightSettings {
        var s = self
        s.lights = Array(lights.prefix(Self.maxLights)).map { $0.resolved(at: t) }
        return s
    }
}

public enum RelightOps {
    /// Matte kinds (MatteStore) the relight of a clip reads.
    public static let depthKind = "depth"
    public static let personKind = "person"
}
