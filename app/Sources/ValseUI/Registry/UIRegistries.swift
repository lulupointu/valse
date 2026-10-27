import SwiftUI
import ValseCore
import ValseEffects
import ValseEngine

/// What inspector tabs/sections see.
public struct InspectorContext {
    public let store: EditorStore
    // Observation slices (perf, W14): sections re-render when the selected clip changes, not on every project edit.
    public var clip: Clip? { store.selectedClipSlice }
    public var trackKind: TrackKind? { store.selectedTrackKindSlice }
    public var track: Track? { clip.flatMap { c in store.project.timeline.locate(c.id).map { store.project.timeline.tracks[$0.track] } } }
    public var asset: MediaAsset? { clip?.mediaID.flatMap { store.mediaBin.asset($0) } }
    public var hasSelection: Bool { !store.selection.isEmpty || store.selectedTransition != nil }
    public var isVisualClip: Bool { trackKind.map { $0 != .audio } ?? false }
    public var hasAudio: Bool { (asset?.hasAudio ?? false) }
    public var isMediaVideo: Bool { asset?.kind == .video }
    public var isText: Bool { if case .text = clip?.content { return true }; return false }
    public var isAdjustment: Bool { if case .adjustment = clip?.content { return true }; return false }
    public var isMainTrack: Bool { track?.isMain ?? false }
    /// Playhead relative to the selected clip (for keyframes).
    public var localTime: Time { clip.map { (store.transport.playhead - $0.start).clamped(.zero, $0.duration) } ?? .zero }
    /// Half a frame: keyframes closer than this to the playhead count as "on" it.
    public var keyframeTolerance: Time { store.projectSettings.frameRate.frameDuration / 2.0 }

    /// What the inspector is showing (drives tabs, like CapCut's per-type headers).
    public var kind: InspectorSelectionKind {
        if store.selection.isEmpty { return store.selectedTransition != nil ? .transition : .none }
        if store.selection.count > 1 { return store.multiEditKind ?? .multiple }
        guard let clip else { return .none }
        return Self.kind(of: clip, asset: asset)
    }

    /// Inspector kind of one clip (also used to group a multi-selection, C2).
    public static func kind(of clip: Clip, asset: MediaAsset?) -> InspectorSelectionKind {
        switch clip.content {
        case .text: return .text
        case .sticker: return .sticker
        case .solid: return .image
        case .adjustment:
            let cats = clip.effects.compactMap { Registries.effects[$0.typeID]?.category }
            if cats.first == .filter { return .filter }
            if cats.first == .effect { return .effect }
            return .adjustment
        case .compound: return .video
        case .media:
            switch asset?.kind {
            case .audio: return .audio
            case .image: return .image
            default: return .video
            }
        }
    }

    /// C2: every clip an inspector edit applies to (2+ when several clips of the same kind are selected; `clip` is the first).
    public var clips: [Clip] { let m = store.selectedClipsSlice; return m.count > 1 ? m : (clip.map { [$0] } ?? []) }
    /// Several same-kind clips are edited together (mixed values show "-").
    public var isMulti: Bool { store.selectedClipsSlice.count > 1 }

    /// Main-track clip whose `transitionOut` is selected in the timeline.
    public var transitionClip: Clip? { store.selectedTransition.flatMap { store.project.timeline.clip($0) } }
}

/// Selection type → inspector layout (UX.md §5.1–5.9).
public enum InspectorSelectionKind: String, Sendable {
    case none, video, image, audio, text, sticker, effect, filter, adjustment, transition, multiple
    /// Has pixels on the canvas with a transform (Position & Size, Blend, Mask…).
    public var isPlacedVisual: Bool { [.video, .image, .text, .sticker].contains(self) }
}

/// Segmented sub-tab under a header tab (e.g. Video ▸ Basic · Cutout · Mask).
public struct InspectorSubTab: Identifiable {
    public let id: String
    public let titleKey: String
    public let order: Int
    public let appliesTo: @MainActor (InspectorContext) -> Bool
    public init(id: String, titleKey: String, order: Int, appliesTo: @escaping @MainActor (InspectorContext) -> Bool = { _ in true }) {
        self.id = id; self.titleKey = titleKey; self.order = order; self.appliesTo = appliesTo
    }
}

/// Inspector header tab (e.g. Video, Audio, Speed, Animation, Adjust, Text, Details).
public struct InspectorTab: Identifiable {
    public let id: String
    public let titleKey: String
    public let order: Int
    public let appliesTo: @MainActor (InspectorContext) -> Bool
    /// Sub-tabs shown as a segmented control when two or more of them have sections.
    public var subTabs: [InspectorSubTab]
    /// Sticky bar under the sections ("Apply to all", "Modify"…), nil = none.
    public let footer: (@MainActor (InspectorContext, String?) -> AnyView?)?
    /// Order depending on the selection (nil = `order`), e.g. Captions first for a caption, last for other clips.
    public var dynamicOrder: (@MainActor (InspectorContext) -> Int)? = nil
    func order(for ctx: InspectorContext) -> Int { dynamicOrder?(ctx) ?? order }
    public init(id: String, titleKey: String, order: Int, subTabs: [InspectorSubTab] = [],
                footer: (@MainActor (InspectorContext, String?) -> AnyView?)? = nil,
                appliesTo: @escaping @MainActor (InspectorContext) -> Bool) {
        self.id = id; self.titleKey = titleKey; self.order = order; self.subTabs = subTabs; self.footer = footer
        self.appliesTo = appliesTo
    }
}

/// Header chrome of a section: `[☐] Title ▾ … [accessory] [↺] ‹◇›` (UX.md §5 "Sections").
public struct InspectorSectionChrome {
    /// Optional-feature checkbox (Blend, Canvas, Chroma key…). When off, the body is hidden.
    public var isEnabled: Binding<Bool>?
    public var reset: (() -> Void)?
    /// Keys the header diamond toggles together (nil = no triplet, [] = greyed triplet).
    public var keyframeKeys: [ParamKey]?
    public var accessory: AnyView?
    /// Small grey text after the title (e.g. "(Only applied to slow-mo videos)").
    public var subtitle: String?
    /// Greys the whole section out (backend missing); the reason is shown under the header.
    public var disabledReason: String?
    public var startsCollapsed: Bool
    public init(isEnabled: Binding<Bool>? = nil, reset: (() -> Void)? = nil, keyframeKeys: [ParamKey]? = nil,
                accessory: AnyView? = nil, subtitle: String? = nil, disabledReason: String? = nil, startsCollapsed: Bool = false) {
        self.isEnabled = isEnabled; self.reset = reset; self.keyframeKeys = keyframeKeys; self.accessory = accessory
        self.subtitle = subtitle; self.disabledReason = disabledReason; self.startsCollapsed = startsCollapsed
    }
}

/// One collapsible section inside an inspector tab. Add a feature's inspector UI by registering one of these.
public struct InspectorSection: Identifiable {
    public let id: String
    public let tabID: String
    /// Sub-tab the section lives in (nil = the tab's first sub-tab, or the tab itself when it has none).
    public let subTabID: String?
    public let order: Int
    public let titleKey: String?
    public let appliesTo: @MainActor (InspectorContext) -> Bool
    public let chrome: (@MainActor (InspectorContext) -> InspectorSectionChrome)?
    public let content: @MainActor (InspectorContext) -> AnyView
    /// The section fills the panel and scrolls itself (no panel ScrollView, no rebuild on selection change: the caption
    /// editor, CAP-EDITOR-UX). Only honoured when it is the only section of its (sub-)tab.
    public var ownsScroll = false
    public init(id: String, tab: String, subTab: String? = nil, order: Int, titleKey: String?,
                appliesTo: @escaping @MainActor (InspectorContext) -> Bool = { _ in true },
                chrome: (@MainActor (InspectorContext) -> InspectorSectionChrome)? = nil,
                content: @escaping @MainActor (InspectorContext) -> AnyView) {
        self.id = id; self.tabID = tab; self.subTabID = subTab; self.order = order; self.titleKey = titleKey
        self.appliesTo = appliesTo; self.chrome = chrome; self.content = content
    }
}

@MainActor
public enum InspectorRegistry {
    public private(set) static var allTabs: [InspectorTab] = BuiltinInspector.tabs
    public private(set) static var sections: [InspectorSection] = BuiltinInspector.sections

    public static func register(_ tab: InspectorTab) { allTabs.removeAll { $0.id == tab.id }; allTabs.append(tab) }
    public static func register(_ section: InspectorSection) { sections.removeAll { $0.id == section.id }; sections.append(section) }
    /// Adds a sub-tab to an existing tab (e.g. Adjust ▸ HSL from the colour team, Audio ▸ Voice changer).
    public static func register(_ subTab: InspectorSubTab, in tabID: String) {
        guard let i = allTabs.firstIndex(where: { $0.id == tabID }) else { return }
        allTabs[i].subTabs.removeAll { $0.id == subTab.id }
        allTabs[i].subTabs.append(subTab)
    }

    public static func tabs(for ctx: InspectorContext) -> [InspectorTab] {
        allTabs.filter { $0.appliesTo(ctx) && !sections(tab: $0.id, ctx: ctx).isEmpty }.sorted { $0.order(for: ctx) < $1.order(for: ctx) }
    }

    /// Every applicable section of a tab, all sub-tabs together.
    public static func sections(tab: String, ctx: InspectorContext) -> [InspectorSection] {
        sections.filter { $0.tabID == tab && $0.appliesTo(ctx) && InspectorMultiEdit.shows($0, ctx) }.sorted { $0.order < $1.order }
    }

    /// Sub-tabs of `tab` that apply and have at least one section.
    public static func subTabs(of tab: InspectorTab, ctx: InspectorContext) -> [InspectorSubTab] {
        let secs = sections(tab: tab.id, ctx: ctx)
        let first = tab.subTabs.sorted { $0.order < $1.order }.first?.id
        return tab.subTabs.filter { st in st.appliesTo(ctx) && secs.contains { ($0.subTabID ?? first) == st.id } }
            .sorted { $0.order < $1.order }
    }

    /// Sections shown for `tab` with `subTab` active.
    public static func sections(tab: InspectorTab, subTab: String?, ctx: InspectorContext) -> [InspectorSection] {
        let first = tab.subTabs.sorted { $0.order < $1.order }.first?.id
        return sections(tab: tab.id, ctx: ctx).filter { subTab == nil || ($0.subTabID ?? first) == subTab }
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
