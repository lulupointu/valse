import Foundation
import MontageCore

/// Thread-safe, ordered registry of descriptors keyed by id. Built-ins are registered at first access;
/// extensions may `register` more at startup (before the UI appears).
public final class Registry<Item: Identifiable & Sendable>: @unchecked Sendable where Item.ID == String {
    private let lock = NSLock()
    private var order: [String] = []
    private var items: [String: Item] = [:]

    public init(_ initial: [Item] = []) { initial.forEach(register) }

    public func register(_ item: Item) {
        lock.withLock {
            if items[item.id] == nil { order.append(item.id) }
            items[item.id] = item
        }
    }

    /// Removes an item (user content deleted from its library, e.g. custom effects FX-018).
    public func unregister(_ id: String) {
        lock.withLock { items[id] = nil; order.removeAll { $0 == id } }
    }

    public subscript(id: String) -> Item? { lock.withLock { items[id] } }

    public var all: [Item] { lock.withLock { order.compactMap { items[$0] } } }
}

/// Entry point for every content registry. Adding a built-in = one file in Builtin/ + one line in its catalog list.
public enum Registries {
    public static let effects = Registry<EffectDescriptor>(BuiltinFilters.all + BuiltinEffects.all + BuiltinAdjustments.all
                                                            + BuiltinColor.all + BuiltinKeying.all + BuiltinCutoutStroke.all + BuiltinCanvasStyles.all
                                                            + BuiltinLensCorrection.all)
    public static let transitions = Registry<TransitionDescriptor>(BuiltinTransitions.all)
    public static let animations = Registry<AnimationDescriptor>(BuiltinAnimations.all + BuiltinTextAnimations.all)
    public static let stickers = Registry<StickerDescriptor>(BuiltinStickers.all)
    public static let textStyles = Registry<TextStyleDescriptor>(BuiltinTextStyles.all)
    // Text engine content (W7)
    public static let textBubbles = Registry<TextBubbleDescriptor>(BuiltinTextBubbles.all)
    public static let textTemplates = Registry<TextTemplateDescriptor>(BuiltinTextTemplates.all)
    public static let captionTemplates = Registry<CaptionTemplateDescriptor>(BuiltinCaptionTemplates.all + BuiltinLyricTemplates.all)   // + TX-026 lyrics (F3)

    public static func textStyles(_ kind: TextStyleKind) -> [TextStyleDescriptor] { textStyles.all.filter { $0.kind == kind } }

    public static func effects(in category: EffectCategory) -> [EffectDescriptor] {
        effects.all.filter { $0.category == category }
    }

    public static func animations(_ phase: AnimationPhaseKind, for target: AnimationTargets) -> [AnimationDescriptor] {
        animations.all.filter { $0.phase == phase && $0.targets.contains(target) }
    }
}

public enum EffectsResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Montage_MontageEffects", fallback: .module)
    /// Registers this module's strings with `L10n` (called by the app bootstrap and tests).
    public static func register() {
        L10n.shared.register(bundle)
        installLaneResolver()
    }

    /// Lets MontageCore put effect / filter / adjustment clips on their own lanes (`AdjustmentLanes`).
    public static func installLaneResolver() {
        guard AdjustmentLanes.resolver == nil else { return }  // idempotent
        AdjustmentLanes.resolver = { id in
            switch Registries.effects[id]?.category {
            case .effect: return .effect
            case .filter: return .filter
            case .adjustment: return .adjustment
            default: return nil
            }
        }
    }
}
