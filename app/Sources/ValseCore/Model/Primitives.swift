import Foundation

/// Typed UUID identifier. `Identifier<Clip>` and `Identifier<Track>` cannot be mixed up.
/// Encoded as a plain UUID string.
public struct Identifier<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID
    public init() { raw = UUID() }
    public init(_ raw: UUID) { self.raw = raw }
    public init?(string: String) { guard let u = UUID(uuidString: string) else { return nil }; raw = u }
    public init(from decoder: any Decoder) throws { raw = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
    public var description: String { raw.uuidString }
    public var short: String { String(raw.uuidString.prefix(8)) }
}

public typealias ProjectID = Identifier<Project>
public typealias TrackID = Identifier<Track>
public typealias ClipID = Identifier<Clip>
public typealias MediaID = Identifier<MediaAsset>
public typealias EffectInstanceID = Identifier<EffectInstance>
public typealias MarkerID = Identifier<Marker>
/// Tag type for clip group ids.
public enum ClipGroupTag {}
public typealias ClipGroupID = Identifier<ClipGroupTag>

/// 2D vector in model space (Double for exact persistence).
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public static let one = Vec2(1, 1)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public static func * (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x * b.x, a.y * b.y) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var description: String { String(format: "(%.3f, %.3f)", x, y) }
}

/// Pixel size (or aspect) of a media item / canvas.
public struct Size2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var aspect: Double { height > 0 ? width / height : 1 }
    public static let hd1080 = Size2(1920, 1080)
    public static let zero = Size2(0, 0)
    public var description: String { "\(Int(width))x\(Int(height))" }
}

/// Straight (non-premultiplied) RGBA color, components 0…1, sRGB.
public struct RGBA: Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let red = RGBA(1, 0, 0)
    public static let green = RGBA(0, 1, 0)
    public static let blue = RGBA(0, 0, 1)
    /// `RGBA(hex: 0x00C1CD)`
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }
}
