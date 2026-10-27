import Foundation

/// Canvas fill behind a main-track clip (CapCut Video ▸ Basic ▸ Canvas: None / Blur / Color / Style).
/// Evaluated by `FrameEvaluator` into ordinary render items, so preview and export need no special renderer code:
/// - `.color`: the frame background becomes that colour while the clip is on screen;
/// - `.blur(level)`: a blurred copy of the clip, scaled to *fill* the canvas, is drawn right below it;
/// - `.style(id)`: a full-canvas pattern layer (a `.solid` layer carrying the pattern effect `id`) is drawn below it.
public enum CanvasBackground: Hashable, Codable, Sendable {
    /// 1…4 (CapCut's four blur swatches, light → strong).
    case blur(level: Int)
    case color(RGBA)
    /// Registry id of a canvas pattern effect (ValseEffects `EffectCategory.canvas`).
    case style(id: String)

    public static let blurLevels = 1...4
    /// Effect used for the blurred fill (ValseEffects built-in blur, param "radius" 0…1).
    public static let blurEffectID = "valse.effect.blur"

    /// Blur radii for a level: one blur instance per entry. Stacking widens the kernel.
    public static func blurStack(level: Int) -> [Double] {
        switch min(max(level, 1), 4) {
        case 1: return [0.35]
        case 2: return [0.7]
        case 3: return [1, 0.6]
        default: return [1, 1, 1]
        }
    }

    public var kindID: String {
        switch self {
        case .blur: return "blur"
        case .color: return "color"
        case .style: return "style"
        }
    }
}
