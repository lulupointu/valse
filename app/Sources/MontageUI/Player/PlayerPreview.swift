import Foundation
import MontageCore
import MontageEffects
import MontageEngine

/// Library / source preview in the player (UX.md §4.1, screenshot 70b): the header reads "Previewing — <type>", the
/// timecode shows the item's own time and duration, Space plays it, Esc (or a click on the canvas / timeline, a seek,
/// an edit) returns to the timeline. Nothing is added to the project and the timeline playhead doesn't move.
///
/// The engine temporarily plays a throw-away project: the media clip alone (source preview) or a copy of the timeline with
/// the effect / filter / sticker over 3 s at the playhead, looping.
public struct PlayerPreview: Equatable {
    public enum Kind: String, Sendable { case video, image, audio, effect, filter, sticker, text, library, transition }
    public var kind: Kind
    /// What is previewed (media id, effect type id, sticker id…), so a second click on the same card can toggle it off.
    public var itemID: String
    /// The item's span inside the preview project (timecode origin + duration).
    public var range: TimeRange
    /// Frame size of the preview project (a portrait clip previews in portrait).
    public var canvas = Size2.hd1080
    /// Timeline state restored on exit.
    var savedPlayhead: Time
    var savedLoop: TimeRange?

    public var titleKey: String { "player.preview.kind.\(kind.rawValue)" }
}

extension EditorStore {
    /// Seconds of timeline a library effect / filter / sticker preview loops over (CapCut: about 3 s).
    static let libraryPreviewDuration = Time(3)

    public var isPreviewing: Bool { playerUI.preview != nil }

    /// Previews a media item from the bin in the player (single click on a media card).
    public func previewMedia(_ id: MediaID) {
        guard let asset = project.asset(id) else { return }
        if playerUI.preview?.itemID == id.description { return }
        var p = Project()
        p.media = [asset]
        p.settings = project.settings
        if asset.kind != .audio { p.settings.canvasSize = Self.canvasSize(forMedia: asset.pixelSize) }
        var clip = TimelineOps.makeClip(for: asset)
        clip.start = .zero
        guard (try? TimelineOps.insert(clip, into: &p, target: .automatic)) != nil else { return }
        let kind: PlayerPreview.Kind = asset.kind == .audio ? .audio : (asset.kind == .image ? .image : .video)
        startPreview(PlayerPreview(kind: kind, itemID: id.description, range: TimeRange(start: .zero, duration: clip.duration),
                                   savedPlayhead: transport.playhead, savedLoop: engine.loopRange), project: p, autoplay: false)
    }

    /// Previews an effect or filter over the frames under the playhead (3 s loop), without adding it.
    public func previewEffect(_ d: EffectDescriptor) {
        var c = Clip(content: .adjustment, start: .zero, duration: Self.libraryPreviewDuration)
        c.effects = [d.makeInstance()]
        previewOverlay(c, kind: d.category == .filter ? .filter : .effect, itemID: d.id)
    }

    /// Previews a sticker over the frames under the playhead (3 s loop), without adding it.
    public func previewSticker(_ id: String) {
        previewOverlay(Clip(content: .sticker(id: id), start: .zero, duration: Self.libraryPreviewDuration), kind: .sticker, itemID: id)
    }

    private func previewOverlay(_ clip: Clip, kind: PlayerPreview.Kind, itemID: String) {
        if playerUI.preview?.itemID == itemID { return }
        let saved = playerUI.preview?.savedPlayhead ?? transport.playhead
        var p = project
        let d = Self.libraryPreviewDuration
        // an empty timeline previews over a sample gradient (W13), so effects / filters show something
        if p.timeline.allClips.isEmpty, let sample = StockLibrary["gradient.lavender"] {
            for var sc in StockLibrary.project(for: sample).timeline.allClips { sc.duration = d; _ = try? TimelineOps.insert(sc, into: &p) }
        }
        // the 3 s window around the playhead, kept inside the timeline
        let start = p.duration > d ? min(saved, p.duration - d) : .zero
        var c = clip
        c.start = start
        guard (try? TimelineOps.insert(c, into: &p, target: .newTrack)) != nil else { return }
        startPreview(PlayerPreview(kind: kind, itemID: itemID, range: TimeRange(start: start, duration: d), savedPlayhead: saved,
                                   savedLoop: playerUI.preview?.savedLoop ?? engine.loopRange), project: p, autoplay: true)
    }

    /// Media ▸ Library card (W13): the stock recipe rendered live (nothing imported yet); animated items loop.
    func previewStock(_ i: StockItem) {
        let id = "stock.\(i.id)"
        if playerUI.preview?.itemID == id { return }
        let p = StockLibrary.project(for: i)
        startPreview(PlayerPreview(kind: .library, itemID: id, range: TimeRange(start: .zero, duration: p.duration),
                                   savedPlayhead: transport.playhead, savedLoop: engine.loopRange), project: p, autoplay: i.isVideo)
    }

    /// Transition card (W13): the main-track cut nearest the playhead with this transition, looped ±1 s around it.
    public func previewTransition(_ d: TransitionDescriptor) {
        let itemID = "transition.\(d.id)"
        if playerUI.preview?.itemID == itemID { return }
        guard let main = project.timeline.mainTrack, main.clips.count > 1 else { return }
        let ph = playerUI.preview?.savedPlayhead ?? transport.playhead
        guard let cut = main.clips.dropLast().min(by: { abs(($0.end - ph).ticks) < abs(($1.end - ph).ticks) }) else { return }
        var p = project
        guard (try? TimelineOps.setTransition(cut.id, d.makeInstance(), in: &p.timeline)) != nil,
              let end = p.timeline.clip(cut.id)?.end else { return }
        let half = max(Time(1), d.defaultDuration)
        let start = max(.zero, end - half)
        startPreview(PlayerPreview(kind: .transition, itemID: itemID, range: TimeRange(start: start, end: min(p.duration, end + half)),
                                   savedPlayhead: ph, savedLoop: playerUI.preview?.savedLoop ?? engine.loopRange), project: p, autoplay: true)
    }

    private func startPreview(_ preview: PlayerPreview, project p: Project, autoplay: Bool) {
        let previous = playerUI.preview
        engine.pause()
        playerUI.preview = PlayerPreview(kind: preview.kind, itemID: preview.itemID, range: preview.range, canvas: p.settings.canvasSize,
                                         savedPlayhead: previous?.savedPlayhead ?? preview.savedPlayhead,
                                         savedLoop: previous != nil ? previous!.savedLoop : preview.savedLoop)
        playerUI.previewTime = preview.range.start
        engine.update(project: p, force: true)
        engine.loopRange = autoplay ? preview.range : nil
        engine.seek(to: preview.range.start)
        if autoplay { engine.play() }
    }

    /// Back to the timeline (Esc, click elsewhere, seek, edit): restores the project, playhead and loop.
    public func exitPreview() {
        guard let pv = playerUI.preview else { return }
        engine.pause()
        playerUI.preview = nil
        engine.update(project: project, force: true)
        engine.loopRange = pv.savedLoop
        engine.seek(to: pv.savedPlayhead)
    }

    /// Engine clock → timeline playhead, or the preview's own time while previewing.
    func engineTimeDidUpdate(_ t: Time) {
        if isPreviewing { playerUI.previewTime = t } else { transport.playhead = t }
    }
}

/// Click on a registry-grid tile (transitions / stickers / effects without a dedicated tab, W13): preview by id.
@MainActor
enum RegistryGridPreview {
    static func preview(_ id: String, store: EditorStore) {
        if let d = Registries.transitions[id] { store.previewTransition(d) }
        else if let d = Registries.effects[id] { store.previewEffect(d) }
        else if Registries.stickers[id] != nil { store.previewSticker(id) }
    }
}
