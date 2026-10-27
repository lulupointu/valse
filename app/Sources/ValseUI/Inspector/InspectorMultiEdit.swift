import SwiftUI
import ValseCore

/// C2 multi-select editing (CapCut): with 2+ clips of the same kind selected (media/media, text/text, audio/audio,
/// sticker/sticker) the inspector shows that kind's full tabs for the first clip in timeline order (`ctx.clip`), every
/// inspector edit applies to all selected clips as one undo step, and a value the clips disagree on reads "-"
/// (Rotate "-"). Mixed kinds keep the "Properties" tab (relative scale / position).
///
/// How a control joins in: write through `Bind.apply` / `Bind.binding` / `ClipParamRow` / `ClipNumberField` (fan out
/// automatically) or `store.performInspector(UpdateClip(…))` / `performInspector(SetSpeed(…))` instead of `perform`.
/// Edits that can't be shared (AI jobs on one clip, canvas-drawn masks, the text box) are hidden while several
/// clips are edited: list the section here.
@MainActor
enum InspectorMultiEdit {
    /// Kinds that get the full inspector when several clips of that kind are selected.
    static let kinds: Set<InspectorSelectionKind> = [.video, .image, .audio, .text, .sticker]

    /// Sections that act on one clip (background jobs, per-clip analysis, canvas tools).
    static let singleOnlyIDs: Set<String> = [
        "cutout.auto", "cutout.custom", "video.cameraLock", "video.reframe", "video.aiMovement", "video.enhanceQuality",
        "video.aiRemove", "video.faceCover", "video.relight", "video.denoise", "video.deflicker",
        "adjust.auto", "adjust.colorMatch", "adjust.colorCorrect", "adjust.presets",
        "text.template", "text.template.tools", "text.counter", "speed.velocity",
    ]
    /// Id prefixes / parts of single-clip sections (masks are edited with canvas handles on one clip).
    static let singleOnlyPrefixes = ["mask.", "tracking.", "tts."]   // the caption editor works with any selection
    static let singleOnlyParts = [".mask."]

    static func shows(_ section: InspectorSection, _ ctx: InspectorContext) -> Bool {
        guard ctx.isMulti else { return true }
        let id = section.id
        if singleOnlyIDs.contains(id) { return false }
        if singleOnlyPrefixes.contains(where: { id.hasPrefix($0) }) { return false }
        return !singleOnlyParts.contains { id.contains($0) }
    }

    /// The "-" CapCut shows for a value the selected clips disagree on.
    static let mixedText = "-"

    /// True when the values differ (beyond float noise).
    static func isMixed(_ values: [Double]) -> Bool {
        guard let first = values.first else { return false }
        return values.contains { abs($0 - first) > 1e-6 * max(1, abs(first)) }
    }
}

extension EditorStore {
    /// The multi-selection when every selected clip has the same inspector kind (video + image count as media → image
    /// tabs), timeline order (start, then track); empty otherwise.
    func multiEditSelection() -> (clips: [Clip], kind: InspectorSelectionKind?) {
        let tl = session.project.timeline
        var located: [(clip: Clip, track: Int)] = []
        for id in selection {
            guard let loc = tl.locate(id) else { return ([], nil) }
            located.append((tl.tracks[loc.track].clips[loc.clip], loc.track))
        }
        guard located.count > 1 else { return ([], nil) }
        let kinds = Set(located.map { InspectorContext.kind(of: $0.clip, asset: $0.clip.mediaID.flatMap(session.project.asset)) })
        let kind: InspectorSelectionKind? = kinds.count == 1 ? kinds.first : (kinds == [.video, .image] ? .image : nil)
        guard let kind, InspectorMultiEdit.kinds.contains(kind) else { return ([], nil) }
        let clips = located.sorted { ($0.clip.start, $0.track) < ($1.clip.start, $1.track) }.map(\.clip)
        return (clips, kind)
    }

    /// Clips an inspector edit of `id` applies to: the whole same-kind multi-selection when `id` is part of it.
    func inspectorTargets(_ id: ClipID) -> [ClipID] {
        let m = selectedClipsSlice.map(\.id)
        return m.count > 1 && m.contains(id) ? m : [id]
    }

    /// `perform` for inspector edits: during a same-kind multi-selection the edit runs on every selected clip (one undo step).
    @discardableResult
    func performInspector(_ cmd: UpdateClip) -> Bool {
        let ids = inspectorTargets(cmd.clipID)
        guard ids.count > 1 else { return perform(cmd) }
        let cmds = ids.map { cmd.retargeted($0) }
        return perform(Edit(cmd.nameKey) { p in for c in cmds { try? c.apply(to: &p) } })
    }

    @discardableResult
    func performInspector(_ cmd: SetSpeed) -> Bool {
        let ids = inspectorTargets(cmd.clipID)
        guard ids.count > 1 else { return perform(cmd) }
        let speed = cmd.speed
        return perform(Edit(cmd.nameKey) { p in for id in ids { try? TimelineOps.setSpeed(id, speed, in: &p.timeline) } })
    }
}
