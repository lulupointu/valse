import AppKit
import MontageCore

/// Settings ▸ Edit ▸ Mouse (SE-016): what the scroll wheel does on the timeline. Pure so it can be unit-tested.
enum TimelineScrollMapping {
    enum Action: Equatable {
        case zoom(Double)
        case scroll(dx: Double, dy: Double)
        case none
    }

    /// Wheel direction for a plain mouse wheel (trackpads always scroll in 2D).
    enum WheelScroll: String, CaseIterable { case vertical, horizontal
        var nameKey: String { "settings.mouse.wheel.\(rawValue)" }
    }
    /// Modifier that turns scrolling into zooming ("none" = the plain wheel zooms, ⌘ scrolls).
    enum ZoomModifier: String, CaseIterable { case command, option, none
        var nameKey: String { "settings.mouse.zoom.\(rawValue)" }
    }

    static func action(dx: Double, dy: Double, command: Bool, option: Bool, shift: Bool, precise: Bool,
                       wheel: WheelScroll, zoomModifier: ZoomModifier) -> Action {
        let wantsZoom: Bool = switch zoomModifier {
        case .command: command
        case .option: option
        case .none: !command && !precise
        }
        if wantsZoom {
            guard dy != 0 else { return .none }
            return .zoom(precise ? exp(dy * 0.01) : (dy > 0 ? 1.1 : 1 / 1.1))
        }
        // ⇧ (or ⌥ when ⌥ isn't the zoom modifier) = horizontal; a mouse wheel set to "horizontal" too
        let horizontal = shift || (option && zoomModifier != .option) || (!precise && wheel == .horizontal)
        let h = horizontal ? (dx != 0 ? dx : dy) : dx
        let v = horizontal ? 0 : dy
        return h == 0 && v == 0 ? .none : .scroll(dx: h, dy: v)
    }
}
