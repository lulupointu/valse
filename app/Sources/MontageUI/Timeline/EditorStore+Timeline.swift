import AppKit
import MontageCore
import MontageEngine

/// Clipboard payload on the general pasteboard (clips + the media they reference, so paste works across projects).
struct ClipboardPayload: Codable {
    var items: [ClipboardItem]
    var assets: [MediaAsset]
    static let type = NSPasteboard.PasteboardType("com.montage.clips")
}

/// Timeline commands (W1): every toolbar button, shortcut and context-menu item of the timeline calls one of these.
extension EditorStore {
    var ui: TimelineUIState { timelineUI }
    var playhead: Time { transport.playhead }

    /// Runs a timeline edit as one undo step.
    @discardableResult
    func edit(_ key: String, _ body: @escaping @Sendable (inout Project) throws -> Void) -> Bool {
        perform(Edit(key, body))
    }

    // MARK: Selection

    /// Selects clips (expanded to their groups).
    public func select(_ ids: Set<ClipID>, adding: Bool = false) {
        let full = TimelineOps.expandGroups(ids, in: project.timeline)
        selection = adding ? selection.union(full) : full
        ui.selectedTransition = nil
        ui.selectedMarker = nil
        if !adding { ui.selectedKeyframe = nil }
    }

    public func selectAll() { select(Set(project.timeline.tracks.filter { !$0.isLocked }.flatMap(\.clips).map(\.id))) }
    public func deselectAll() { selection = []; ui.selectedTransition = nil; ui.selectedMarker = nil; ui.selectedKeyframe = nil }
    public func selectLeftOfPlayhead() { select(TimelineOps.clips(leftOf: playhead, in: project.timeline)) }
    public func selectRightOfPlayhead() { select(TimelineOps.clips(rightOf: playhead, in: project.timeline)) }

    /// The clip a playhead command acts on: the single selection, else the main-track clip under the playhead,
    /// else any clip under the playhead.
    var targetClip: Clip? {
        if let c = singleSelectedClip { return c }
        if let m = TimelineOps.mainClip(at: playhead, in: project.timeline) { return m }
        return project.timeline.tracks.filter { !$0.isLocked }.flatMap { $0.clips(at: playhead) }.first
    }

    // MARK: Split / delete

    /// ⌘B: splits the selection at the playhead, or the main-track clip under it when nothing is selected.
    public func split() {
        let ids = selection.isEmpty ? (TimelineOps.mainClip(at: playhead, in: project.timeline).map { [$0.id] } ?? [])
                                    : Array(selection)
        if ids.isEmpty { splitAll(); return }
        perform(SplitClips(ids, at: playhead))
    }

    /// ⇧⌘B: splits every unlocked track at the playhead.
    public func splitAll() { perform(SplitClips([], at: playhead)) }

    /// Split (blade) mode click.
    public func blade(_ id: ClipID, at t: Time) {
        let full = TimelineOps.expandGroups([id], in: project.timeline)
        perform(SplitClips(Array(full), at: t))
    }

    /// ⌫: deletes the selected transition, marker, keyframe or clips (in that priority).
    public func deleteSmart() {
        if let k = ui.selectedKeyframe {
            ui.selectedKeyframe = nil
            edit("cmd.keyframe") { p in p.timeline[clip: k.clip]?.keyframes[k.key]?.remove(near: k.time, tolerance: Time(ticks: 1000)) }
            return
        }
        if let t = ui.selectedTransition {
            ui.selectedTransition = nil
            perform(SetTransition(t, nil)); return
        }
        if let m = ui.selectedMarker {
            ui.selectedMarker = nil
            edit("cmd.marker.delete") { p in try TimelineOps.removeMarkers([m], in: &p.timeline) }; return
        }
        deleteSelection()
    }

    /// Q / W: trims the target clip(s) start / end to the playhead.
    public func deleteLeftRight(_ edge: TrimEdge) {
        let ids: [ClipID] = selection.count > 1 ? Array(selection) : (targetClip.map { [$0.id] } ?? [])
        guard !ids.isEmpty else { return }
        let t = playhead
        edit(edge == .head ? "cmd.deleteLeft" : "cmd.deleteRight") { p in
            var did = false
            for id in ids {
                guard let c = p.timeline.clip(id), t > c.start, t < c.end else { continue }
                try TimelineOps.trim(id, edge: edge, to: t, in: &p); did = true
            }
            if !did { throw EditError.invalidTime }
        }
        if edge == .head, let c = ids.first.flatMap({ project.timeline.clip($0) }) { seek(to: c.start) }
    }

    // MARK: Clipboard

    public func copySelection() {
        if let k = ui.selectedKeyframe { copyKeyframes(k); return }   // W5: keyframe copy
        guard !selection.isEmpty else { return }
        keyframeUI.clipboardActive = false
        let items = TimelineOps.copyItems(selection, from: project.timeline)
        ui.clipboard = items
        let media = Set(items.compactMap(\.clip.mediaID))
        let payload = ClipboardPayload(items: items, assets: project.media.filter { media.contains($0.id) })
        if let data = try? JSONEncoder().encode(payload) {
            let pb = AppPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: ClipboardPayload.type)
        }
    }

    public func cutSelection() {
        guard !selection.isEmpty else { return }
        copySelection()
        perform(DeleteClips(selection))
        selection = []
    }

    public func paste() {
        if keyframeUI.clipboardActive, pasteKeyframes() { return }   // W5: keyframes copied last
        var items = ui.clipboard
        var assets: [MediaAsset] = []
        if let data = AppPasteboard.general.data(forType: ClipboardPayload.type),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
            items = payload.items; assets = payload.assets
        }
        pasteItems(items, assets: assets, at: playhead)
    }

    /// Pastes clipboard items so the earliest starts at `t` (one undo step); the pasted clips become the selection.
    func pasteItems(_ items: [ClipboardItem], assets: [MediaAsset], at t: Time) {
        guard !items.isEmpty else { return }
        let box = ResultBox([ClipID]())
        let (items0, assets0) = (items, assets)
        let ok = edit("cmd.paste") { p in
            let items = items0, assets = assets0
            for a in assets where p.asset(a.id) == nil { p.media.append(a) }
            box.value = try TimelineOps.paste(items, at: t, in: &p)
        }
        if ok { selection = Set(box.value) }
    }

    public func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        let box = ResultBox([ClipID]())
        if edit("cmd.duplicate", { p in box.value = try TimelineOps.duplicate(ids, in: &p) }) { selection = Set(box.value) }
    }

    public func copyAttributes() {
        guard let c = singleSelectedClip else { return }
        ui.attributeSource = c
        showToast(tr("toast.attributesCopied"))
    }

    public func pasteAttributes(groups: Set<AttributeGroup>? = nil, timing: KeyframeTiming? = nil) {
        guard let src = ui.attributeSource, !selection.isEmpty else { return }
        let g = groups ?? ui.pasteAttributeGroups, k = timing ?? ui.pasteKeyframeTiming
        let ids = selection
        edit("cmd.pasteAttributes") { p in try TimelineOps.pasteAttributes(from: src, groups: g, timing: k, to: ids, in: &p.timeline) }
    }

    // MARK: Groups

    public func groupSelection() { let ids = selection; edit("cmd.group") { p in try TimelineOps.group(ids, in: &p.timeline) } }
    public func ungroupSelection() { let ids = selection; edit("cmd.ungroup") { p in try TimelineOps.ungroup(ids, in: &p.timeline) } }
    var selectionIsGrouped: Bool { selectedClips.contains { $0.groupID != nil } }

    // MARK: Clip edits

    public func freezeFrame() {
        guard let c = targetClip else { return }
        let t = playhead.clamped(c.start, c.end)
        let box = ResultBox(ClipID())
        if edit("cmd.freeze", { p in box.value = try TimelineOps.freezeFrame(c.id, at: t, in: &p) }) { selection = [box.value] }
    }

    /// "Duplicate frame" (TL-015): repeats the frame under the playhead for one frame (≥ the minimum clip length),
    /// inserted in place like a freeze; the playhead moves past it so repeated use stutters successive frames.
    public func duplicateFrame() {
        guard let c = targetClip else { return }
        let t = playhead.clamped(c.start, c.end)
        let d = max(project.settings.frameRate.frameDuration, TimelineOps.minimumClipDuration)
        let box = ResultBox(ClipID())
        if edit("cmd.duplicateFrame", { p in box.value = try TimelineOps.freezeFrame(c.id, at: t, duration: d, in: &p) }) {
            selection = [box.value]
            if let f = project.timeline.clip(box.value) { seek(to: f.end) }
        }
    }

    /// Freeze frames stop following their original clip (TL-013).
    public func unlinkFreezeSelection() {
        let ids = selection
        edit("cmd.unlinkFreeze") { p in
            var did = false
            for id in ids where p.timeline.clip(id)?.freezeSource != nil { p.timeline[clip: id]?.freezeSource = nil; did = true }
            if !did { throw EditError.nothingToDo }
        }
    }

    /// "Match cut" (TL-036): split the selected clips on the marked beats of the music.
    public func matchCut() {
        let ids = selection.isEmpty ? Set(targetClip.map { [$0.id] } ?? []) : selection
        guard !ids.isEmpty else { return }
        guard !TimelineOps.beatTimes(project.timeline, excluding: ids).isEmpty else { showToast(tr("matchCut.noBeats")); return }
        let box = ResultBox(0)
        if edit("cmd.matchCut", { p in box.value = try TimelineOps.matchCut(ids, in: &p.timeline) }) {
            showToast(tr("matchCut.done", box.value))
        }
    }

    /// "Split audio track" (AU-018): a stereo (dual-mono) audio clip becomes its left channel here and its right
    /// channel on a new audio track, grouped so they move together.
    public func splitAudioChannels() {
        guard let c = singleSelectedClip else { return }
        let box = ResultBox(ClipID())
        if edit("cmd.splitAudioTrack", { p in box.value = try TimelineOps.splitAudioChannels(c.id, in: &p.timeline) }) {
            selection = [c.id, box.value]
        }
    }

    public func reverseSelection() {
        let ids = selection.isEmpty ? Set(targetClip.map { [$0.id] } ?? []) : selection
        edit("cmd.reverse") { p in try TimelineOps.toggleReverse(ids, in: &p.timeline) }
    }

    public func mirrorSelection() { updateVisual("cmd.mirror") { $0.transform.flipH.toggle() } }
    public func rotateSelection() { updateVisual("cmd.rotate") { $0.transform.rotation = ($0.transform.rotation + 90).truncatingRemainder(dividingBy: 360) } }

    private func updateVisual(_ key: String, _ body: @escaping @Sendable (inout Clip) -> Void) {
        let ids = selectedClips.filter { trackKind(of: $0)?.isVisual == true }.map(\.id)
        guard !ids.isEmpty else { return }
        edit(key) { p in for id in ids { if var c = p.timeline.clip(id) { body(&c); p.timeline[clip: id] = c } } }
    }

    public func toggleEnabledSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        edit("cmd.toggleClip") { p in try TimelineOps.toggleEnabled(ids, in: &p.timeline) }
    }

    public func extractOrRestoreAudio() {
        guard let c = singleSelectedClip else { return }
        if c.audio.isMuted, project.timeline.allClips.contains(where: { $0.extractedFrom == c.id }) {
            edit("cmd.restoreAudio") { p in try TimelineOps.restoreAudio(c.id, in: &p.timeline) }
        } else {
            edit("cmd.extractAudio") { p in try TimelineOps.extractAudio(c.id, in: &p) }
        }
    }

    public func arrange(_ how: LayerArrangement) {
        guard let c = singleSelectedClip else { return }
        edit("cmd.arrange") { p in try TimelineOps.arrange(c.id, how, in: &p.timeline) }
    }

    /// "Replace clip": pick a file, import it and swap the selected clip's media.
    public func replaceSelectedClip() {
        guard let c = singleSelectedClip else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .image, .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let (assets, _) = await MediaProbe.probeAll([url])
            guard let a0 = assets.first else { showToast(tr("toast.importFailed", 1), error: true); return }
            let a = project.media.first { $0.contentHash == a0.contentHash } ?? a0
            edit("cmd.replace") { p in try TimelineOps.replaceMedia(c.id, with: a, in: &p) }
            await ProxyManager.shared.request([a])
        }
    }

    public func revealSelectedInFinder() {
        let urls = selectedClips.compactMap { $0.mediaID.flatMap(project.asset)?.url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: Gaps

    public func closeGap(at t: Time, track: TrackID) { edit("cmd.closeGap") { p in try TimelineOps.closeGap(at: t, on: track, in: &p.timeline) } }
    public func closeAllGaps(track: TrackID) { edit("cmd.closeGap") { p in try TimelineOps.closeAllGaps(on: track, in: &p.timeline) } }

    // MARK: Markers & beats

    public func addMarker(newColor: Bool = false) {
        if newColor { ui.markerColorIndex = (ui.markerColorIndex + 1) % TimelineOps.markerColors.count }
        let color = TimelineOps.markerColors[ui.markerColorIndex]
        let t = playhead
        // An audio clip selected: M marks a beat on it (CapCut "Mark beats").
        if let c = singleSelectedClip, trackKind(of: c) == .audio, t >= c.start, t <= c.end {
            edit("cmd.beat") { p in try TimelineOps.toggleBeat(c.id, at: t, in: &p.timeline) }; return
        }
        // Any other clip selected: M marks the clip (CapCut clip markers, TL-025); they move with the clip.
        if let c = singleSelectedClip, t >= c.start, t <= c.end {
            edit("cmd.clipMarker") { p in try TimelineOps.addClipMarker(c.id, at: t, color: color, in: &p.timeline) }; return
        }
        let box = ResultBox<MarkerID?>(nil)
        if edit("cmd.marker", { p in box.value = try TimelineOps.addMarker(at: t, color: color, in: &p.timeline) }) {
            ui.selectedMarker = box.value
        }
    }

    public func goToMarker(next: Bool) {
        let times = TimelineOps.allMarkerTimes(project.timeline)   // timeline + clip markers
        let eps = Time(ticks: 1)
        if let t = next ? times.first(where: { $0 > playhead + eps }) : times.last(where: { $0 < playhead - eps }) { seek(to: t) }
    }

    public func goToCut(next: Bool) {
        let cuts = TimelineOps.cutPoints(project.timeline)
        let eps = Time(ticks: 1000)
        if let t = next ? cuts.first(where: { $0 > playhead + eps }) : cuts.last(where: { $0 < playhead - eps }) { seek(to: t) }
    }

    public func removeAllMarkers() {
        let ids = Set(project.timeline.markers.map(\.id))
        edit("cmd.marker.delete") { p in try TimelineOps.removeMarkers(ids, in: &p.timeline) }
    }

    /// "Delete all markers in clip" (TL-025).
    public func removeClipMarkersSelection() {
        let ids = selection
        edit("cmd.marker.delete") { p in try TimelineOps.removeClipMarkers(ids, in: &p.timeline) }
    }

    public func clearBeatsSelection() {
        let ids = selection
        edit("cmd.beat") { p in try TimelineOps.clearBeats(ids, in: &p.timeline) }
    }

    // MARK: Range

    public func setInPoint() { let t = playhead; edit("cmd.range") { p in TimelineOps.setRangePoint(in: true, at: t, in: &p.timeline) } }
    public func setOutPoint() { let t = playhead; edit("cmd.range") { p in TimelineOps.setRangePoint(in: false, at: t, in: &p.timeline) } }
    public func clearRange() { edit("cmd.range") { p in p.timeline.inPoint = nil; p.timeline.outPoint = nil } }
    /// ⇧X "Select by clip": in/out = the selection's extent.
    public func rangeFromSelection() {
        let cs = selectedClips.isEmpty ? (targetClip.map { [$0] } ?? []) : selectedClips
        guard let s = cs.map(\.start).min(), let e = cs.map(\.end).max() else { return }
        edit("cmd.range") { p in p.timeline.inPoint = s; p.timeline.outPoint = e }
    }

    // MARK: Tracks

    public func toggleTrack(_ id: TrackID, _ flag: WritableKeyPath<Track, Bool> & Sendable, key: String) {
        edit(key) { p in if let i = p.timeline.trackIndex(id) { p.timeline.tracks[i][keyPath: flag].toggle() } }
    }

    /// Solo / unsolo a track (AU-029). Soloing also unmutes it so it is heard.
    public func toggleSolo(_ id: TrackID) {
        edit("cmd.trackSolo") { p in
            guard let i = p.timeline.trackIndex(id) else { return }
            let on = p.timeline.tracks[i].isSolo != true
            p.timeline.tracks[i].isSolo = on ? true : nil
            if on { p.timeline.tracks[i].isMuted = false }
        }
    }

    /// Track volume (TL-018): linear gain 0…2 on top of the clips' own volume (nil = 0 dB). One undo step.
    public func setTrackVolume(_ id: TrackID, _ gain: Double) {
        let g = min(max(gain, 0), 2)
        edit("cmd.trackVolume") { p in
            guard let i = p.timeline.trackIndex(id) else { return }
            p.timeline.tracks[i].volume = abs(g - 1) < 1e-6 ? nil : g
        }
    }

    public func setTrackHeight(_ id: TrackID, _ h: TrackHeight) {
        edit("cmd.trackHeight") { p in if let i = p.timeline.trackIndex(id) { p.timeline.tracks[i].heightPreset = h == .standard ? nil : h } }
    }

    public func setWaveformScale(_ id: TrackID, _ v: Double) {
        edit("cmd.trackHeight") { p in if let i = p.timeline.trackIndex(id) { p.timeline.tracks[i].waveformScale = v } }
    }

    public func setLinkage(_ cat: LinkageCategory, enabled: Bool) {
        edit("cmd.timelineOption") { p in
            var ex = Set(p.timeline.linkageExcluded ?? [])
            if enabled { ex.remove(cat) } else { ex.insert(cat) }
            p.timeline.linkageExcluded = ex.isEmpty ? nil : LinkageCategory.allCases.filter(ex.contains)
        }
    }

    // MARK: Zoom & scroll

    /// Zooms keeping the playhead fixed on screen (or the left edge when the playhead is off-screen).
    public func zoomTimeline(by k: Double) {
        let pps0 = pixelsPerSecond
        let width = ui.viewWidth - Double(TimelineLayout.headerWidth)
        let px = (playhead.seconds - ui.scrollTime) * pps0
        zoom(by: k)
        if px >= 0 && px <= width {
            ui.scrollTime = max(0, playhead.seconds - px / pixelsPerSecond)
        }
    }

    /// ⇧Z: fits the whole timeline in the view.
    public func zoomTimelineToFit() {
        zoomToFit(width: ui.viewWidth - 40)
        ui.scrollTime = 0
    }

    public func toggleTool(_ t: TimelineUIState.Tool) { ui.tool = t }
}

/// Carries a value out of a `@Sendable` edit closure (edits run synchronously on the main actor).
nonisolated final class ResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
