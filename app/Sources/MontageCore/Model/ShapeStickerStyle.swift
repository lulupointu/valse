import Foundation

/// Per-clip look of a shape sticker (ST-008 "Shapes" / basic graphics): fill (solid or top → bottom gradient), stroke
/// (colour, width, solid / dashed / dotted), corner radius and an optional custom outline drawn on the canvas.
/// nil on the clip = the sticker's own look. Fill, stroke colour and stroke width are keyframeable (`shape.*`).
public struct ShapeStickerStyle: Codable, Sendable, Hashable {
    public enum Dash: String, Codable, Sendable, CaseIterable { case solid, dashed, dotted }
    /// nil = no fill.
    public var fill: RGBA?
    /// Gradient end colour (top = `fill`, bottom = `fillEnd`); nil = solid fill.
    public var fillEnd: RGBA?
    /// nil = no stroke.
    public var stroke: RGBA?
    /// Stroke width as a fraction of the sticker side (0…0.2).
    public var strokeWidth: Double
    public var dash: Dash
    /// Corner radius of rectangles, fraction of the shorter side (0…0.5); nil = the shape's default.
    public var cornerRadius: Double?
    /// Custom outline (closed smooth curve) in the sticker's unit square (0…1, y down), drawn on the canvas.
    public var points: [Vec2]?

    public init(fill: RGBA? = .white, fillEnd: RGBA? = nil, stroke: RGBA? = nil, strokeWidth: Double = 0.04,
                dash: Dash = .solid, cornerRadius: Double? = nil, points: [Vec2]? = nil) {
        self.fill = fill; self.fillEnd = fillEnd; self.stroke = stroke; self.strokeWidth = strokeWidth
        self.dash = dash; self.cornerRadius = cornerRadius; self.points = points
    }

    public static let maxStrokeWidth = 0.2

    /// Dash lengths (unit-square units) for a stroke of width `w`; nil = solid. Dotted = round dots (zero-length dashes
    /// with round caps).
    public func dashPattern(width w: Double) -> [Double]? {
        switch dash {
        case .solid: return nil
        case .dashed: return [w * 3, w * 2]
        case .dotted: return [0, w * 2]
        }
    }
}

extension ParamKey {
    public static let shapeFill: ParamKey = "shape.fill"
    public static let shapeStroke: ParamKey = "shape.stroke"
    public static let shapeStrokeWidth: ParamKey = "shape.strokeWidth"

    /// Keyframeable shape style properties (only meaningful once the clip has a `shapeStyle`).
    static var shapeProperties: [AnimatableProperty] {
        [
            .init(key: .shapeFill, nameKey: "prop.shapeFill", get: { .color($0.shapeStyle?.fill ?? .white) },
                  set: { c, v in if let col = v.color, c.shapeStyle?.fill != nil { c.shapeStyle?.fill = col } }),
            .init(key: .shapeStroke, nameKey: "prop.shapeStroke", get: { .color($0.shapeStyle?.stroke ?? .white) },
                  set: { c, v in if let col = v.color, c.shapeStyle?.stroke != nil { c.shapeStyle?.stroke = col } }),
            .init(key: .shapeStrokeWidth, nameKey: "prop.shapeStrokeWidth", get: { .scalar($0.shapeStyle?.strokeWidth ?? 0) },
                  set: { c, v in if let w = v.scalar { c.shapeStyle?.strokeWidth = min(max(w, 0), ShapeStickerStyle.maxStrokeWidth) } }),
        ]
    }
}
