import Foundation
import AppKit
import Perception
import MontageCore
import MontageEngine

/// Where the caret goes when a caption row takes keyboard focus.
enum CaptionCaret: Equatable {
    case offset(Int)
    case end
    /// Keep the horizontal position (↑ / ↓ between captions): x in text-view points, on the first or last visual line.
    case x(CGFloat, lastLine: Bool)
}

/// A pending "put the caret in this caption" (split, merge, insert, undo, Tab…). The row's text view applies it once
/// it is on screen and clears it.
struct CaptionFocusRequest: Equatable {
    let id: ClipID
    let caret: CaptionCaret
    let token = UUID()
}

/// A pending "scroll the caption list to this row" (minimal scroll).
struct CaptionRevealRequest: Equatable {
    let id: ClipID
    let token = UUID()
}

/// Inspector ▸ Captions editor state (CAP-EDITOR-UX). One per store; survives inspector re-renders.
@Perceptible
public final class CaptionEditorState {
    /// Language tab = caption track being edited (nil = the selected caption's track, else the first one).
    public var activeTrackID: TrackID?
    /// Caption whose text has keyboard focus.
    public internal(set) var editingID: ClipID?
    /// Keyboard focus is on the caption list itself (after Esc): ↑ ↓ move the active row, ↩ edits, ⌫ deletes.
    public internal(set) var listFocused = false
    var focus: CaptionFocusRequest?
    var reveal: CaptionRevealRequest?
    // Search & replace (pinned above the list)
    public var findText = "" { didSet { if findText != oldValue { matchIndex = 0 } } }
    public var replaceText = ""
    public var caseSensitive = false { didSet { matchIndex = 0 } }
    public var showReplace = false
    /// Current match (0-based) of the counter "3/12".
    public var matchIndex = 0
    var searchFocusToken = 0
    /// The user scrolled the list during playback: auto-follow is off until playback starts again or the pill is clicked.
    public internal(set) var followSuspended = false
    /// Split options disclosure (remembered per user).
    public var splitOpen: Bool = !HomeSandbox.isActive && UserDefaults.standard.bool(forKey: "captionEditor.splitOpen") {
        didSet { if !HomeSandbox.isActive { UserDefaults.standard.set(splitOpen, forKey: "captionEditor.splitOpen") } }
    }
    /// Custom split rule being edited (Split options ▸ Custom…).
    public var customRule = CaptionSplitRule(charsPerLine: 32, lines: 2)
    public var showCustomRule = false
    /// Split rule chosen, waiting for the inline confirmation (re-split warns, then applies to the whole language).
    public var pendingRule: CaptionSplitRule?
    /// Top bar ▸ Delete all: inline confirmation shown.
    public var confirmDeleteAll = false
    /// Top bar ▸ + Add (language) popover.
    public var showAddLanguage = false

    // Not observed
    /// Caption of the running typing burst (one undo step "Edit caption" per burst).
    @PerceptionIgnored var typingID: ClipID?
    @PerceptionIgnored var typingIdle: Task<Void, Never>?
    /// Empty caption added with + : removed again when the user leaves it empty.
    @PerceptionIgnored var insertedEmptyID: ClipID?
    /// Selection changes made by the editor itself (no list reveal).
    @PerceptionIgnored var selectingFromEditor = false
    /// ↻ Replay line: pause when the playhead reaches this time.
    @PerceptionIgnored var replayEnd: Time?
    @PerceptionIgnored var lastUserScroll: Double = -.infinity
    @PerceptionIgnored var lastNowPlaying: ClipID?
    /// Scroll moves of the list nobody asked for (UI tests: must stay 0 while clicking / editing captions).
    @PerceptionIgnored public private(set) var unrequestedScrolls = 0
    @PerceptionIgnored var scrollAllowedUntil: Double = -.infinity

    /// The next list scroll is expected (a reveal, a wheel scroll, the keep-in-place correction).
    func allowListScroll() { scrollAllowedUntil = ProcessInfo.processInfo.systemUptime + 0.6 }
    func noteListScroll() {
        if ProcessInfo.processInfo.systemUptime > scrollAllowedUntil { unrequestedScrolls += 1 }
    }

    /// Pause after which a typing burst ends (one undo step per burst).
    static let typingIdle: Double = 1.5

    public init() {}
}

/// Caption under the playhead (`EditorStore.captionNowPlaying`): only the two rows whose state changes re-render.
@Perceptible
public final class CaptionNowPlaying {
    public internal(set) var id: ClipID?
    public init() {}
}

/// What `undo` / `redo` need to put the caret back (CAP-EDITOR-UX).
struct CaptionHistorySnapshot {
    let editingID: ClipID
    let start: Time
    let trackID: TrackID
    let texts: [ClipID: String]
}

// MARK: - Store: caption editing (CAP-EDITOR-UX)

extension EditorStore {
    /// Caption track the caption editor shows: the chosen language tab, else the selected caption's track, else the first.
    var captionEditorTrackIndex: Int? {
        let tl = project.timeline
        if let id = captionEditor.activeTrackID, let i = tl.trackIndex(id), CaptionOps.isCaptionTrack(tl.tracks[i]) { return i }
        if let c = singleSelectedClip, let ti = CaptionOps.trackIndex(of: c.id, in: tl) { return ti }
        return CaptionOps.captionTracks(tl).first
    }

    /// The active row: the single selected caption, when it is on the editor's track.
    var captionActiveID: ClipID? {
        guard selection.count == 1, let id = selection.first, let ti = captionEditorTrackIndex,
              project.timeline.tracks[ti].clipIndex(id) != nil else { return nil }
        return id
    }

    // MARK: Activation, seek, reveal

    /// Makes `id` the active row (selection = [id]). Paused + `seek`: the playhead jumps to the caption start and the
    /// timeline scrolls to show it (only when off-screen).
    func captionActivate(_ id: ClipID, seek: Bool) {
        if selection != [id] {
            captionEditor.selectingFromEditor = true
            selection = [id]
            captionEditor.selectingFromEditor = false
        }
        if seek, !transport.isPlaying, let c = project.timeline.clip(id) { captionSeekPaused(to: c.start) }
    }

    func captionSeekPaused(to t: Time) {
        seek(to: t)
        transport.playhead = t
        revealPlayheadInTimeline(t)
        captionPlayheadDidChange(t)
    }

    /// Paused seek from the caption editor: scrolls the timeline so `t` is visible (40 pt padding), never while playing
    /// (playback follow does that).
    func revealPlayheadInTimeline(_ t: Time) {
        let width = timelineUI.viewWidth - Double(TimelineLayout.headerWidth)
        if let s = PlayheadFollow.reveal(playhead: t.seconds, scrollTime: timelineUI.scrollTime, pixelsPerSecond: pixelsPerSecond,
                                         visibleWidth: width) {
            timelineUI.scrollTime = s
        }
    }

    /// Selection changed (any source): follow the caption's language tab; a caption selected elsewhere (timeline) is
    /// revealed in the list.
    func captionSelectionDidChange() {
        guard selection.count == 1, let id = selection.first, let ti = CaptionOps.trackIndex(of: id, in: project.timeline) else { return }
        let tid = project.timeline.tracks[ti].id
        if captionEditor.activeTrackID != tid { captionEditor.activeTrackID = tid }
        if !captionEditor.selectingFromEditor, captionEditor.editingID != id { captionEditor.reveal = CaptionRevealRequest(id: id) }
    }

    /// Puts the caret into a caption (the row's text view takes focus when it is on screen).
    func captionFocus(_ id: ClipID, caret: CaptionCaret) {
        captionEditor.reveal = CaptionRevealRequest(id: id)
        captionEditor.focus = CaptionFocusRequest(id: id, caret: caret)
        captionActivate(id, seek: false)
    }

    // MARK: Typing (live, one undo step per burst)

    /// One keystroke in a caption: the model is updated at once (the player re-renders); a burst is one undo step.
    /// Paused: the first keystroke of a burst seeks to the caption when the playhead is outside it.
    func captionTyped(_ id: ClipID, _ text: String) {
        let ed = captionEditor
        if ed.typingID != id || !session.isInGesture {
            endCaptionTyping()
            if !transport.isPlaying, let c = project.timeline.clip(id), !(transport.playhead >= c.start && transport.playhead < c.end) {
                captionSeekPaused(to: c.start)
            }
            beginInspectorGesture("cmd.captionText")
            ed.typingID = id
        }
        updateGesture { p in try CaptionOps.setText(id, text, in: &p) }
        ed.typingIdle?.cancel()
        ed.typingIdle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CaptionEditorState.typingIdle))
            guard !Task.isCancelled else { return }
            self?.endCaptionTyping()
        }
    }

    /// Ends the running typing burst (commits its undo step). Safe to call any time.
    func endCaptionTyping() {
        let ed = captionEditor
        ed.typingIdle?.cancel(); ed.typingIdle = nil
        guard ed.typingID != nil else { return }
        ed.typingID = nil
        if session.isInGesture { endGesture() }
    }

    /// The caption text view took / lost keyboard focus.
    func captionEditingBegan(_ id: ClipID) {
        let ed = captionEditor
        if ed.editingID != id { ed.editingID = id }
        if ed.listFocused { ed.listFocused = false }
        if let e = ed.insertedEmptyID, e != id { dropEmptyInserted(e) }
    }

    func captionEditingEnded(_ id: ClipID) {
        endCaptionTyping()
        let ed = captionEditor
        if ed.editingID == id { ed.editingID = nil }
        if ed.insertedEmptyID == id { dropEmptyInserted(id) }
    }

    /// The empty caption added with + is removed when left empty (undoing its insertion, so no trace in the history).
    private func dropEmptyInserted(_ id: ClipID) {
        captionEditor.insertedEmptyID = nil
        guard let c = project.timeline.clip(id), let t = CaptionOps.text(c),
              t.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if session.undoNameKey == "cmd.captionAdd", session.undoStack.last.map({ $0.after == project }) == true {
            undoQuietly()
        } else {
            _ = perform(Edit("cmd.captionDelete") { p in try CaptionOps.delete(id, in: &p) })
        }
    }

    // MARK: Structure edits (focus stays in the editor)

    /// ↩: split at the caret, caret at the start of the new second caption. At the very end: next caption (or a new
    /// empty one after the last). At the very start: nothing.
    func captionReturn(_ id: ClipID, caret: Int) {
        guard let c = project.timeline.clip(id), let t = CaptionOps.text(c) else { return }
        let len = (t.string as NSString).length
        let trimmedTail = (t.string as NSString).substring(from: min(caret, len)).trimmingCharacters(in: .whitespacesAndNewlines)
        if caret >= len || trimmedTail.isEmpty {
            if let next = CaptionOps.neighbour(of: id, 1, in: project.timeline) { captionFocus(next, caret: .offset(0)) }
            else { captionInsertAfter(id) }
            return
        }
        guard caret > 0 else { return }
        endCaptionTyping()
        let ok = perform(Edit("cmd.captionSplit") { p in _ = try CaptionOps.split(id, at: caret, in: &p) })
        if ok, let n = CaptionOps.neighbour(of: id, 1, in: project.timeline) { captionFocus(n, caret: .offset(0)) }
        else { showToast(tr("captions.error.cantSplit"), error: true) }
    }

    /// ⌫ at the start: merge into the previous caption, caret at the join.
    func captionMergeIntoPrevious(_ id: ClipID) {
        guard let prev = CaptionOps.neighbour(of: id, -1, in: project.timeline),
              let a = project.timeline.clip(prev).flatMap(CaptionOps.text), let b = project.timeline.clip(id).flatMap(CaptionOps.text) else { return }
        endCaptionTyping()
        let caret = CaptionOps.mergeCaret(previousText: a.string, text: b.string)
        if perform(Edit("cmd.captionMerge") { p in try CaptionOps.mergeWithNext(prev, in: &p) }) {
            captionFocus(prev, caret: .offset(caret))
        } else { showToast(tr("captions.error.cantMerge"), error: true) }
    }

    /// ⌦ at the end: merge the next caption into this one, caret stays.
    func captionMergeNext(_ id: ClipID, caret: Int) {
        guard CaptionOps.neighbour(of: id, 1, in: project.timeline) != nil else { return }
        endCaptionTyping()
        if perform(Edit("cmd.captionMerge") { p in try CaptionOps.mergeWithNext(id, in: &p) }) {
            captionFocus(id, caret: .offset(caret))
        } else { showToast(tr("captions.error.cantMerge"), error: true) }
    }

    /// +: an EMPTY caption after this one (placeholder "Type a caption…"), caret in it.
    func captionInsertAfter(_ id: ClipID) {
        endCaptionTyping()
        let newID = ClipID()
        if perform(Edit("cmd.captionAdd") { p in _ = try CaptionOps.insertAfter(id, text: "", newID: newID, in: &p) }) {
            captionEditor.insertedEmptyID = newID
            captionFocus(newID, caret: .offset(0))
            if !transport.isPlaying, let c = project.timeline.clip(newID) { captionSeekPaused(to: c.start) }
        } else { showToast(tr("captions.error.cantDoHere"), error: true) }
    }

    /// 🗑 / ⇧⌘⌫: deletes the caption; the next row becomes active (caret at its start when editing).
    func captionDelete(_ id: ClipID, focusNext: Bool) {
        endCaptionTyping()
        let tl = project.timeline
        let next = CaptionOps.neighbour(of: id, 1, in: tl) ?? CaptionOps.neighbour(of: id, -1, in: tl)
        if captionEditor.insertedEmptyID == id { captionEditor.insertedEmptyID = nil }
        guard perform(Edit("cmd.captionDelete") { p in try CaptionOps.delete(id, in: &p) }) else { return }
        if let n = next {
            if focusNext { captionFocus(n, caret: .offset(0)) } else { captionActivate(n, seek: false); captionEditor.reveal = CaptionRevealRequest(id: n) }
        } else { selection = [] }
    }

    /// Tab / arrows across captions (continuous document).
    func captionMove(from id: ClipID, _ delta: Int, caret: CaptionCaret) {
        guard let n = CaptionOps.neighbour(of: id, delta, in: project.timeline) else { return }
        endCaptionTyping()
        captionFocus(n, caret: caret)
        if !transport.isPlaying, let c = project.timeline.clip(n) { captionSeekPaused(to: c.start) }
    }

    // MARK: Timing

    /// ⌥⌘I / ⌥⌘O: caption start / end to the playhead (clamped to the neighbours).
    func captionSetEdgeToPlayhead(_ id: ClipID, start: Bool) {
        endCaptionTyping()
        let t = transport.playhead
        if !perform(Edit("cmd.captionTiming") { p in try CaptionOps.setEdge(id, start: start, to: t, in: &p) }) {
            showToast(tr("captions.error.cantDoHere"), error: true)
        }
    }

    /// Timing strip ‹ ›: one frame per click (10 with ⇧).
    func captionNudge(_ id: ClipID, startFrames: Int = 0, endFrames: Int = 0) {
        endCaptionTyping()
        let f = projectSettings.frameRate.frameDuration
        _ = perform(Edit("cmd.captionTiming") { p in
            try CaptionOps.nudge(id, start: f * Double(startFrames), end: f * Double(endFrames), in: &p)
        })
    }

    // MARK: Playback

    /// ↻ Replay line: plays the caption then pauses at its end (playing: restarts it). ⌥: plays on without stopping.
    func captionReplay(_ id: ClipID, keepPlaying: Bool = false) {
        guard let c = project.timeline.clip(id) else { return }
        endCaptionTyping()
        captionEditor.replayEnd = keepPlaying ? nil : c.end
        seek(to: c.start)
        if !transport.isPlaying { togglePlay() }
    }

    /// Every playhead tick: now-playing row, replay stop, auto-follow.
    func captionPlayheadDidChange(_ t: Time) {
        let ed = captionEditor
        if let end = ed.replayEnd, transport.isPlaying, t >= end {
            ed.replayEnd = nil
            engine.pause()
            let back = max(end - projectSettings.frameRate.frameDuration, .zero)
            seek(to: back)
            transport.playhead = back
            captionPlayheadDidChange(back)
            return
        }
        guard let ti = captionEditorTrackIndex else {
            if captionNowPlaying.id != nil { captionNowPlaying.id = nil }
            return
        }
        let clips = project.timeline.tracks[ti].clips
        let id = CaptionOps.clipIndex(at: t, in: clips).map { clips[$0].id }
        if captionNowPlaying.id != id { captionNowPlaying.id = id }
        // auto-follow: playing, nothing being edited, the user hasn't scrolled the list lately
        if let id, id != ed.lastNowPlaying, transport.isPlaying, ed.editingID == nil, !ed.followSuspended {
            ed.reveal = CaptionRevealRequest(id: id)
        }
        ed.lastNowPlaying = id
    }

    func captionPlayStateDidChange(_ playing: Bool) {
        if playing, captionEditor.followSuspended { captionEditor.followSuspended = false }
        if !playing { captionEditor.replayEnd = nil }
    }

    /// The user scrolled the caption list (wheel / trackpad): during playback, auto-follow stops until resumed.
    func captionListUserScrolled() {
        captionEditor.lastUserScroll = ProcessInfo.processInfo.systemUptime
        if transport.isPlaying, !captionEditor.followSuspended { captionEditor.followSuspended = true }
    }

    func captionResumeFollow() {
        captionEditor.followSuspended = false
        if let id = captionNowPlaying.id { captionEditor.reveal = CaptionRevealRequest(id: id) }
    }

    // MARK: Undo / redo caret

    /// Before undo / redo: ends a typing burst (so ⌘Z undoes it) and remembers the edited caption.
    func captionHistoryWillChange() -> CaptionHistorySnapshot? {
        endCaptionTyping()
        guard let id = captionEditor.editingID ?? captionActiveID, let loc = project.timeline.locate(id) else { return nil }
        let track = project.timeline.tracks[loc.track]
        var texts: [ClipID: String] = [:]
        for c in track.clips { texts[c.id] = CaptionOps.text(c)?.string }
        return CaptionHistorySnapshot(editingID: id, start: track.clips[loc.clip].start, trackID: track.id, texts: texts)
    }

    /// After undo / redo: the caret goes to the first changed character of the caption it affected (undoing a split
    /// leaves it at the split point).
    func captionHistoryDidChange(_ snap: CaptionHistorySnapshot?) {
        guard let snap else { return }
        let wasEditing = captionEditor.editingID != nil
        let tl = project.timeline
        guard let ti = tl.trackIndex(snap.trackID) else { return }
        let clips = tl.tracks[ti].clips
        // the caption that changed: the edited one when it still exists and changed, else the one now at its start
        var target: Clip?
        var changed: [Clip] = clips.filter { c in snap.texts[c.id].map { $0 != CaptionOps.text(c)?.string } ?? true }
        if let c = clips.first(where: { $0.id == snap.editingID }), changed.contains(where: { $0.id == c.id }) || changed.isEmpty { target = c }
        if target == nil, tl.clip(snap.editingID) == nil {
            target = clips.first { $0.start <= snap.start && snap.start < $0.end } ?? clips.last { $0.start <= snap.start }
        }
        if target == nil { changed.sort { $0.start < $1.start }; target = changed.first }
        guard let c = target, let now = CaptionOps.text(c)?.string else { return }
        let caret = snap.texts[c.id].map { CaptionOps.firstDifference($0, now) } ?? (now as NSString).length
        if wasEditing { captionFocus(c.id, caret: .offset(min(caret, (now as NSString).length))) }
        else { captionActivate(c.id, seek: false); captionEditor.reveal = CaptionRevealRequest(id: c.id) }
    }

    // MARK: List keyboard (after Esc)

    func captionListFocusChanged(_ focused: Bool) {
        if captionEditor.listFocused != focused { captionEditor.listFocused = focused }
    }

    /// ↑ / ↓ on the focused list: previous / next row becomes active (paused: the playhead follows).
    func captionListStep(_ delta: Int) {
        guard let ti = captionEditorTrackIndex else { return }
        let clips = project.timeline.tracks[ti].clips
        guard !clips.isEmpty else { return }
        let i = captionActiveID.flatMap { project.timeline.tracks[ti].clipIndex($0) }.map { $0 + delta } ?? 0
        let id = clips[min(max(i, 0), clips.count - 1)].id
        captionActivate(id, seek: true)
        captionEditor.reveal = CaptionRevealRequest(id: id)
    }

    // MARK: Search

    /// Matches of the search field on the active track.
    func captionMatches() -> [CaptionMatch] {
        let ed = captionEditor
        guard !ed.findText.isEmpty, let ti = captionEditorTrackIndex else { return [] }
        return CaptionOps.find(ed.findText, in: project.timeline.tracks[ti], caseSensitive: ed.caseSensitive)
    }

    /// ⌃ / ⌄, Enter / ⇧Enter, ⌘G / ⇧⌘G: steps through the matches (row active and revealed, paused: seek).
    func captionStepMatch(_ delta: Int) {
        let ms = captionMatches()
        guard !ms.isEmpty else { return }
        let ed = captionEditor
        ed.matchIndex = ((ed.matchIndex + delta) % ms.count + ms.count) % ms.count
        let m = ms[ed.matchIndex]
        captionActivate(m.clipID, seek: true)
        ed.reveal = CaptionRevealRequest(id: m.clipID)
    }

    /// Replace: the current match, then the next one.
    func captionReplaceCurrent() {
        let ms = captionMatches()
        let ed = captionEditor
        guard !ms.isEmpty else { return }
        endCaptionTyping()
        let m = ms[min(ed.matchIndex, ms.count - 1)]
        guard let t = project.timeline.clip(m.clipID).flatMap(CaptionOps.text) else { return }
        let ns = NSMutableString(string: t.string)
        ns.replaceCharacters(in: NSRange(location: m.range.location, length: m.range.length), with: ed.replaceText)
        let s = ns as String, id = m.clipID
        perform(Edit("cmd.captionReplace") { p in try CaptionOps.setText(id, s, in: &p) })
        let left = captionMatches()
        if !left.isEmpty { ed.matchIndex = min(ed.matchIndex, left.count - 1); captionStepMatch(0) }
    }

    func captionReplaceAll() {
        let ed = captionEditor
        endCaptionTyping()
        replaceAllInCaptions(ed.findText, with: ed.replaceText, caseSensitive: ed.caseSensitive)
    }

    // MARK: Split options

    /// Re-splits the active language with `rule` (one undo step + toast with Undo).
    func captionResplit(_ rule: CaptionSplitRule) {
        guard let ti = captionEditorTrackIndex else { return }
        endCaptionTyping()
        let tid = project.timeline.tracks[ti].id
        let ok = perform(Edit("cmd.captionWrap") { p in _ = try CaptionOps.resplit(trackID: tid, rule: rule, in: &p) })
        let count = project.timeline.trackIndex(tid).map { project.timeline.tracks[$0].clips.count } ?? 0
        if ok { showToast(tr("capedit.resplit.done", count), actionTitle: tr("capedit.undo")) { [weak self] in self?.undo() } }
    }

    // MARK: State dump (UI tests)

    func captionEditorStateDump() -> [String: Any] {
        let ed = captionEditor
        var d: [String: Any] = ["editing": ed.editingID?.description ?? "", "listFocused": ed.listFocused,
                                "typing": ed.typingID != nil, "followSuspended": ed.followSuspended,
                                "matches": captionMatches().count, "matchIndex": ed.matchIndex,
                                "nowPlaying": captionNowPlaying.id?.description ?? "", "splitOpen": ed.splitOpen,
                                "showReplace": ed.showReplace, "unrequestedScrolls": ed.unrequestedScrolls,
                                "listScrollY": Double(CaptionTextRegistry.listClip?.bounds.origin.y ?? -1)]
        if let ti = captionEditorTrackIndex {
            let track = project.timeline.tracks[ti]
            d["track"] = ti
            d["language"] = track.captionLanguage ?? ""
            d["count"] = track.clips.count
            d["active"] = captionActiveID.flatMap { track.clipIndex($0) } ?? -1
            d["editingIndex"] = ed.editingID.flatMap { track.clipIndex($0) } ?? -1
            d["nowPlayingIndex"] = captionNowPlaying.id.flatMap { track.clipIndex($0) } ?? -1
            d["texts"] = track.clips.map { CaptionOps.text($0)?.string ?? "" }
            if let r = track.captionSplit { d["split"] = "\(r.lines)x\(r.charsPerLine)" }
            if let id = captionActiveID, let c = project.timeline.clip(id) {
                d["playheadAtActiveStart"] = abs((transport.playhead - c.start).seconds) < 0.02
                d["activeStart"] = c.start.seconds; d["activeEnd"] = c.end.seconds
            }
        }
        d["caret"] = CaptionTextRegistry.caret ?? -1
        d["languages"] = CaptionOps.captionTracks(project.timeline).map { project.timeline.tracks[$0].captionLanguage ?? "" }
        d["shown"] = CaptionOps.captionTracks(project.timeline).map { !project.timeline.tracks[$0].isHidden }
        return d
    }
}
