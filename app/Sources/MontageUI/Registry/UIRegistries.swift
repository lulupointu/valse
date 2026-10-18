import SwiftUI
import MontageCore
import MontageEngine

/// What inspector tabs/sections see.
public struct InspectorContext {
    public let store: EditorStore
    public var clip: Clip? { store.singleSelectedClip }
    public var trackKind: TrackKind? { clip.flatMap { store.trackKind(of: $0) } }
    public var asset: MediaAsset? { clip?.mediaID.flatMap { store.project.asset($0) } }
    public var hasSelection: Bool { !store.selection.isEmpty }
    public var isVisualClip: Bool { trackKind.map { $0 != .audio } ?? false }
    public var hasAudio: Bool { (asset?.hasAudio ?? false) }
    public var isMediaVideo: Bool { asset?.kind == .video }
    public var isText: Bool { if case .text = clip?.content { return true }; return false }
    public var isAdjustment: Bool { if case .adjustment = clip?.content { return true }; return false }
    /// Playhead relative to the selected clip (for keyframes).
    public var localTime: Time { clip.map { (store.transport.playhead - $0.start).clamped(.zero, $0.duration) } ?? .zero }
}

/// Inspector header tab (e.g. Video, Audio, Speed, Animation, Adjust, Text, Details).
public struct InspectorTab: Identifiable {
    public let id: String
    public let titleKey: String
    public let order: Int
    public let appliesTo: @MainActor (InspectorContext) -> Bool
    public init(id: String, titleKey: String, order: Int, appliesTo: @escaping @MainActor (InspectorContext) -> Bool) {
        self.id = id; self.titleKey = titleKey; self.order = order; self.appliesTo = appliesTo
    }
}

/// One collapsible section inside an inspector tab. Add a feature's inspector UI by registering one of these.
public struct InspectorSection: Identifiable {
    public let id: String
    public let tabID: String
    public let order: Int
    public let titleKey: String?
    public let appliesTo: @MainActor (InspectorContext) -> Bool
    public let content: @MainActor (InspectorContext) -> AnyView
    public init(id: String, tab: String, order: Int, titleKey: String?, appliesTo: @escaping @MainActor (InspectorContext) -> Bool = { _ in true },
                content: @escaping @MainActor (InspectorContext) -> AnyView) {
        self.id = id; self.tabID = tab; self.order = order; self.titleKey = titleKey; self.appliesTo = appliesTo; self.content = content
    }
}

@MainActor
public enum InspectorRegistry {
    public private(set) static var allTabs: [InspectorTab] = BuiltinInspector.tabs
    public private(set) static var sections: [InspectorSection] = BuiltinInspector.sections

    public static func register(_ tab: InspectorTab) { allTabs.removeAll { $0.id == tab.id }; allTabs.append(tab) }
    public static func register(_ section: InspectorSection) { sections.removeAll { $0.id == section.id }; sections.append(section) }

    public static func tabs(for ctx: InspectorContext) -> [InspectorTab] {
        allTabs.filter { $0.appliesTo(ctx) && !sections(tab: $0.id, ctx: ctx).isEmpty }.sorted { $0.order < $1.order }
    }
    public static func sections(tab: String, ctx: InspectorContext) -> [InspectorSection] {
        sections.filter { $0.tabID == tab && $0.appliesTo(ctx) }.sorted { $0.order < $1.order }
    }
}

/// Asset panel tab (Media, Audio, Text, Stickers, Effects, Transitions, Captions, Filters, Adjustment, Templates).
public struct AssetTab: Identifiable {
    public let id: String
    public let titleKey: String
    public let symbol: String
    public let order: Int
    public let content: @MainActor (EditorStore) -> AnyView
    public init(id: String, titleKey: String, symbol: String, order: Int, content: @escaping @MainActor (EditorStore) -> AnyView) {
        self.id = id; self.titleKey = titleKey; self.symbol = symbol; self.order = order; self.content = content
    }
}

@MainActor
public enum AssetTabRegistry {
    public private(set) static var tabs: [AssetTab] = BuiltinAssetTabs.all
    public static func register(_ tab: AssetTab) { tabs.removeAll { $0.id == tab.id }; tabs.append(tab); tabs.sort { $0.order < $1.order } }
    public static var sorted: [AssetTab] { tabs.sorted { $0.order < $1.order } }
}
