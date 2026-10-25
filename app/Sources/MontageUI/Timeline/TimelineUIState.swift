import Foundation
import Perception
import MontageCore

/// Timeline view state that isn't part of the document (not undoable, not saved): tool mode, scroll, clipboard,
/// selected transition / marker / keyframe, preview axis. Owned by `EditorStore.timelineUI`.
@Perceptible
public final class TimelineUIState {
    public enum Tool: String, Sendable { case select, split }

    /// CapCut select (A) / split-blade (B) mode.
    public var tool: Tool = .select
    /// "Change frame rate for this project?" banner (SP-009): the first video's rate when it differs from the project.
    public var frameRatePrompt: FrameRate?
    /// "Your media may cause playback lag" banner (MI-009): the imported videos it is about.
    public var lagPrompt: [MediaID]?
    /// Clip being renamed (TL-040, right-click ▸ Rename).
    public var renamingClip: ClipID?
    /// Leftmost visible time in seconds.
    public var scrollTime: Double = 0
    /// Vertical scroll in points.
    public var scrollY: Double = 0
    /// Width of the timeline canvas (for zoom to fit / keep playhead fixed).
    public var viewWidth: Double = 1200

    /// Transition selected on the timeline: the clip whose `transitionOut` it is.
    public var selectedTransition: ClipID?
    public var selectedMarker: MarkerID?
    /// Selected keyframe (clip, param key, time) — drawn in accent, deleted with ⌫.
    public var selectedKeyframe: KeyframeRef?

    /// In-app clip clipboard (also mirrored as JSON on the general pasteboard).
    public var clipboard: [ClipboardItem] = []
    /// "Copy attributes" source clip.
    public var attributeSource: Clip?
    public var pasteAttributeGroups: Set<AttributeGroup> = Set(AttributeGroup.allCases)
    public var pasteKeyframeTiming: KeyframeTiming = .stretch

    /// CapCut "Preview axis" (hover scrubbing, S) and its "preview audio" sub-option.
    public var previewAxis = false
    public var previewAxisAudio = false
    /// Index into `TimelineOps.markerColors` for ⌥M.
    public var markerColorIndex = 0
    /// Open cover editor (main-track "Cover" button), nil = closed.
    var coverEditor: CoverEditorModel?
    /// Open Quick cut popover (TL-048), nil = closed.
    public internal(set) var quickCut: QuickCutSession?
    /// Window frame (SwiftUI global space) of the toolbar's Quick cut button: the popover hangs from it.
    @PerceptionIgnored var quickCutButtonFrame: CGRect = .zero
    /// Lane-size tuner popover (TL-SIZE-TUNER) open, and its toolbar button's frame (the popover hangs from it).
    public var sizesOpen = false
    @PerceptionIgnored var sizesButtonFrame: CGRect = .zero


    public init() {}
}

public struct KeyframeRef: Hashable, Sendable {
    public var clip: ClipID
    public var key: String
    public var time: Time
    public init(clip: ClipID, key: String, time: Time) { self.clip = clip; self.key = key; self.time = time }
}
