import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine
import Perception

/// UI state of the text engine that must survive re-renders: inline canvas editing, the rich-text selection, caption
/// editor search, font favourites / recents.
@MainActor @Perceptible
final class TextUIState {
    static let shared = TextUIState()
    /// UTF-16 selection in the inspector text editor (styles apply to it when non-empty, CapCut "multiple values").
    var selection: [ClipID: TextSpan] = [:]
    var findText = ""
    var replaceText = ""
    var caseSensitive = false
    var showReplace = false
    var effectSearch = ""
    var fontSearch = ""
    /// MI-024 (F3): font favourites live in the shared asset favourites store (namespace "fonts"), like every other ☆.
    var favoriteFonts: [String] {
        get { _ = Self.migrated; return AssetLibraryStore.shared.favoriteIDs(AssetLibraryStore.fontsNamespace) }
        set {
            let lib = AssetLibraryStore.shared, ns = AssetLibraryStore.fontsNamespace
            let cur = Set(lib.favoriteIDs(ns)), next = Set(newValue)
            for n in newValue where !cur.contains(n) { lib.toggleFavorite(ns, n) }
            for n in cur where !next.contains(n) { lib.toggleFavorite(ns, n) }
        }
    }
    /// One-time move of the pre-F3 favourites list into the shared store.
    private static let migrated: Bool = {
        let d = AppDefaults.store, key = "MontageFavoriteFonts"
        guard !TestAnchors.isEnabled, let old = d.stringArray(forKey: key), !old.isEmpty else { return true }
        for n in old.reversed() where !AssetLibraryStore.shared.isFavorite(AssetLibraryStore.fontsNamespace, n) {
            AssetLibraryStore.shared.toggleFavorite(AssetLibraryStore.fontsNamespace, n)
        }
        d.removeObject(forKey: key)
        return true
    }()
    var recentFonts: [String] = AppDefaults.store.stringArray(forKey: "MontageRecentFonts") ?? [] {
        didSet { AppDefaults.store.set(recentFonts, forKey: "MontageRecentFonts") }
    }
    /// Bumped when imported fonts change.
    var fontsRevision = 0
    var presetsExpanded = false
    /// C4 Text ▸ Basic "Apply to all main captions" (CapCut, on by default): style edits on a caption restyle its track.
    var applyToAllCaptions: Bool = TestAnchors.isEnabled ? true : (AppDefaults.store.object(forKey: "MontageApplyToAllCaptions") as? Bool ?? true) {
        didSet { if !TestAnchors.isEnabled { AppDefaults.store.set(applyToAllCaptions, forKey: "MontageApplyToAllCaptions") } }
    }

    func noteRecent(_ font: String) {
        guard !font.isEmpty else { return }
        recentFonts = [font] + recentFonts.filter { $0 != font }.prefix(11)
    }
}

/// Text presets saved by the user ("Save as preset", Text tab ▸ Yours). JSON in Application Support.
@MainActor @Perceptible
final class TextPresetStore {
    static let shared = TextPresetStore()
    struct Preset: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var content: TextContent; var animations: ClipAnimations? }
    private(set) var presets: [Preset] = []
    nonisolated static var url: URL { MontagePaths.supportDirectory.appendingPathComponent("text-presets.json") }

    init() {
        if let d = try? Data(contentsOf: Self.url), let p = try? JSONDecoder().decode([Preset].self, from: d) { presets = p }
    }

    func add(_ p: Preset) { presets.insert(p, at: 0); save() }
    func remove(_ id: UUID) { presets.removeAll { $0.id == id }; save() }

    private func save() {
        let snapshot = presets
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: MontagePaths.supportDirectory, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: TextPresetStore.url, options: .atomic) }
        }
    }
}

@MainActor
extension EditorStore {
    // MARK: Selection

    /// The selected clip when it is a text clip.
    var selectedTextClip: (clip: Clip, text: TextContent)? {
        guard let c = singleSelectedClip, case .text(let t) = c.content else { return nil }
        return (c, t)
    }

    /// Edits the text of a clip (gesture-aware: inside a slider drag it updates live, otherwise one undo step).
    func updateText(_ id: ClipID, nameKey: String = "cmd.text", _ body: @escaping (inout TextContent) -> Void) {
        Bind.apply(self, id, nameKey) { c in
            guard case .text(var t) = c.content else { return }
            body(&t)
            c.content = .text(t)
            if t.template == nil, t.caption == nil || c.name == nil { c.name = t.string.replacingOccurrences(of: "\n", with: " ") }
        }
    }

    /// Applies a style change to the editor's selected range (rich text), or to the whole text when nothing is selected.
    func applyTextRunStyle(_ id: ClipID, _ style: TextRunStyle, nameKey: String = "cmd.text") {
        let sel = inspectorTargets(id).count > 1 ? nil : TextUIState.shared.selection[id]   // C2: whole texts when several
        updateText(id, nameKey: nameKey) { t in
            let r = sel.flatMap { $0.length > 0 ? $0 : nil } ?? TextSpan(0, t.utf16Count)
            t.applyStyle(style, to: r)
        }
    }

    // MARK: Adding

    /// "Add text" (Text tab ▸ Default text): 3 s text clip at the playhead on a new track, selected.
    @discardableResult
    func addTextClip(_ content: TextContent, duration: Time = Time(3), animations: ClipAnimations? = nil,
                     nameKey: String = "cmd.text") -> ClipID? {
        let id = addGeneratorClip(.text(content), duration: duration, nameKey: nameKey)
        if let id, let animations { perform(UpdateClip(id, nameKey: nameKey) { $0.animations = animations }) }
        if id != nil { inspectorTab = "text" }
        return id
    }

    func addDefaultText() {
        var t = TextContent(string: tr("text.default"))
        BuiltinTextStyles.basics.first?.apply(&t)
        addTextClip(t)
    }

    func addTextTemplate(_ d: TextTemplateDescriptor) {
        addTextClip(d.makeContent(), duration: d.defaultDuration, nameKey: "cmd.textTemplate")
    }

    /// Text effect / preset click: restyles the selected text clips (keeping their text), else adds a new styled text.
    func applyTextStyle(_ d: TextStyleDescriptor) {
        // TX-040 (F3): with part of the text selected, a text effect applies to that range only
        if d.kind == .effect, let c = singleSelectedClip, case .text = c.content,
           let sel = TextUIState.shared.selection[c.id], sel.length > 0 {
            applyTextRunStyle(c.id, TextRunStyle(effectID: d.id), nameKey: "cmd.textStyle")
            return
        }
        let ids = selectedClips.filter { if case .text = $0.content { return true }; return false }.map(\.id)
        guard !ids.isEmpty else {
            var t = TextContent(string: tr("text.default"))
            d.restyle(&t)
            addTextClip(t)
            return
        }
        perform(Edit("cmd.textStyle") { p in
            for id in ids {
                guard var c = p.timeline.clip(id), case .text(var t) = c.content else { continue }
                d.restyle(&t)
                c.content = .text(t)
                p.timeline[clip: id] = c
            }
        })
    }

    func applyBubble(_ d: TextBubbleDescriptor?) {
        guard let (c, _) = selectedTextClip else { return }
        updateText(c.id, nameKey: "cmd.textBubble") { t in
            t.bubbleID = d?.id
            t.bubbleColor = nil
            if let d { t.color = d.textColor; t.runs = t.runs.map { var r = $0; r.style.color = nil; return r } }
        }
    }

    /// Switches a template clip to another template, keeping its texts (TX-041).
    func changeTemplate(_ id: ClipID, to d: TextTemplateDescriptor) {
        updateText(id, nameKey: "cmd.textTemplate") { t in
            let texts = [t.string] + (t.template?.texts ?? [])
            var n = d.makeContent()
            for i in 0..<min(texts.count, d.slotKeys.count) {
                if i == 0 { n.string = texts[0] } else if i - 1 < (n.template?.texts.count ?? 0) { n.template?.texts[i - 1] = texts[i] }
            }
            t = n
        }
    }

    // MARK: Inline editing (canvas)

    /// Starts in-place editing of a text clip on the canvas (the player canvas's inline editor, W2).
    public func beginInlineTextEdit(_ id: ClipID) {
        guard let c = project.timeline.clip(id), case .text = c.content else { return }
        selection = [id]
        if !(c.range.contains(transport.playhead)) { seek(to: c.start + c.duration / 2) }
        playerUI.editingTextClip = id
    }

    public func endInlineTextEdit() { playerUI.editingTextClip = nil }

    // MARK: Presets

    func saveTextPreset() {
        guard let (c, t) = selectedTextClip else { return }
        var look = t
        look.caption = nil; look.runs = []
        let n = TextPresetStore.shared.presets.count + 1
        TextPresetStore.shared.add(.init(name: tr("text.preset.name", n), content: look, animations: c.animations))
        showToast(tr("text.preset.saved"))
    }

    func applySavedPreset(_ p: TextPresetStore.Preset) {
        guard let (c, _) = selectedTextClip else {
            var t = p.content
            t.string = tr("text.default")
            addTextClip(t, animations: p.animations)
            return
        }
        let anims = p.animations
        perform(UpdateClip(c.id, nameKey: "cmd.textStyle") { clip in
            guard case .text(var t) = clip.content else { return }
            t.adoptLook(of: p.content)
            clip.content = .text(t)
            if let anims { clip.animations = anims }
        })
    }

    // MARK: Captions

    /// Caption track the inspector's caption editor works on (its language tab, see `captionEditorTrackIndex`).
    var activeCaptionTrackIndex: Int? { captionEditorTrackIndex }

    func captionEdit(_ nameKey: String, _ body: @escaping @Sendable (inout Project) throws -> Void) {
        if !perform(Edit(nameKey, body)) { showToast(tr("captions.error.cantDoHere"), error: true) }
    }

    func splitCaption(_ id: ClipID, at offset: Int) {
        let ok = perform(Edit("cmd.captionSplit") { p in _ = try CaptionOps.split(id, at: offset, in: &p) })
        if !ok { showToast(tr("captions.error.cantSplit"), error: true) }
    }

    func mergeCaptionWithNext(_ id: ClipID) {
        let ok = perform(Edit("cmd.captionMerge") { p in try CaptionOps.mergeWithNext(id, in: &p) })
        if !ok { showToast(tr("captions.error.cantMerge"), error: true) }
    }

    func setCaptionText(_ id: ClipID, _ s: String) {
        _ = perform(Edit("cmd.captionText") { p in try CaptionOps.setText(id, s, in: &p) })
    }

    /// A new EMPTY caption after this one, selected (the editor's + is `captionInsertAfter`).
    func addCaption(after id: ClipID) {
        let newID = ClipID()
        if perform(Edit("cmd.captionAdd") { p in _ = try CaptionOps.insertAfter(id, text: "", newID: newID, in: &p) }) {
            selection = [newID]
            seek(to: project.timeline.clip(newID)?.start ?? transport.playhead)
        }
    }

    /// Caption list 🗑 (C4): deletes one caption, the others keep their timing.
    func deleteCaption(_ id: ClipID) {
        let tl = project.timeline
        let next = tl.locate(id).flatMap { loc -> ClipID? in
            let clips = tl.tracks[loc.track].clips
            return loc.clip + 1 < clips.count ? clips[loc.clip + 1].id : (loc.clip > 0 ? clips[loc.clip - 1].id : nil)
        }
        if perform(Edit("cmd.captionDelete") { p in try CaptionOps.delete(id, in: &p) }) {
            selection = next.map { [$0] } ?? []
        }
    }

    func nudgeCaption(_ id: ClipID, start: Time = .zero, end: Time = .zero) {
        _ = perform(Edit("cmd.captionTiming") { p in try CaptionOps.nudge(id, start: start, end: end, in: &p) })
    }

    func replaceAllInCaptions(_ q: String, with r: String, caseSensitive: Bool) {
        guard let ti = activeCaptionTrackIndex, !q.isEmpty else { return }
        let n = CaptionOps.find(q, in: project.timeline.tracks[ti], caseSensitive: caseSensitive).count
        guard n > 0 else { showToast(tr("captions.find.none")); return }
        perform(Edit("cmd.captionReplace") { p in CaptionOps.replaceAll(q, with: r, trackIndex: ti, in: &p, caseSensitive: caseSensitive) })
        showToast(tr("captions.replaced", n))
    }

    func applyCaptionLookToAll() {
        guard let c = singleSelectedClip, CaptionOps.isCaption(c) else { return }
        let id = c.id
        perform(Edit("cmd.captionApplyAll") { p in CaptionOps.applyLookToAll(from: id, in: &p) })
        showToast(tr("captions.updated"))
    }

    /// Caption template click: applied to every caption of the active caption track (CapCut "apply to all captions").
    func applyCaptionTemplate(_ d: CaptionTemplateDescriptor) {
        // C4: with "Apply to all main captions" off, only the selected caption
        if !TextUIState.shared.applyToAllCaptions, let c = singleSelectedClip, CaptionOps.isCaption(c) {
            let anim = d.inAnim
            perform(UpdateClip(c.id, nameKey: "cmd.captionTemplate") { clip in
                guard case .text(var t) = clip.content else { return }
                var look = t
                d.apply(&look)
                t.adoptLook(of: look)
                clip.content = .text(t)
                if let a = anim { clip.animations.inAnim = AnimationInstance(typeID: a, duration: min(Time(0.4), clip.duration * 0.5)) }
            })
            return
        }
        guard let ti = activeCaptionTrackIndex else {
            if let (c, _) = selectedTextClip { updateText(c.id, nameKey: "cmd.captionTemplate") { d.apply(&$0) } }
            return
        }
        perform(Edit("cmd.captionTemplate") { p in
            for i in p.timeline.tracks[ti].clips.indices {
                guard case .text(var t) = p.timeline.tracks[ti].clips[i].content else { continue }
                var look = t
                d.apply(&look)
                t.adoptLook(of: look)
                p.timeline.tracks[ti].clips[i].content = .text(t)
                if let a = d.inAnim {
                    let dur = min(Time(0.4), p.timeline.tracks[ti].clips[i].duration * 0.5)
                    p.timeline.tracks[ti].clips[i].animations.inAnim = AnimationInstance(typeID: a, duration: dur)
                }
            }
        })
    }

    func wrapCaptions(maxChars: Int, maxLines: Int) {
        guard let ti = activeCaptionTrackIndex else { return }
        perform(Edit("cmd.captionWrap") { p in CaptionOps.wrap(trackIndex: ti, maxCharsPerLine: maxChars, maxLines: maxLines, in: &p) })
    }

    /// "Local captions": import SRT / VTT / ASS / LRC / TXT as a new caption track (≤ 3 MB, like CapCut).
    func importCaptions(from url: URL, language: String? = nil) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CaptionFiles.maxImportBytes else { showToast(tr("captions.import.tooLarge"), error: true); return }
        guard let data = try? Data(contentsOf: url),
              let text = CaptionEncoding.current.decode(data),   // MI-020: Character encoding (auto = BOM / UTF-8 / CP1252)
              let fmt = CaptionFormat.detect(fileExtension: url.pathExtension, content: text),
              let segs = try? CaptionFiles.parse(text, format: fmt) else {
            showToast(tr("captions.import.failed"), error: true); return
        }
        let origin: CaptionOrigin = fmt == .lrc ? .lyrics : .imported
        // CAP-LANG-TRACKS: the new track's language (chosen in + Add, else detected from the text)
        let lang = CaptionLanguageTracks.normalized(language ?? CaptionLanguages.detect(segs.prefix(30).map(\.text).joined(separator: " ")))
        let box = UncheckedSendableBox<TrackID?>(nil)
        perform(Edit("cmd.captionImport") { p in
            box.value = CaptionOps.addCaptionTrack(segs, to: &p, origin: origin)
            if let id = box.value, let ti = p.timeline.trackIndex(id) { p.timeline.tracks[ti].captionLanguage = lang }
        })
        if let id = box.value { captionEditor.activeTrackID = id }
        showToast(tr("captions.import.done", segs.count))
    }

    func chooseCaptionFileToImport(language: String? = nil) {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["srt", "vtt", "ass", "ssa", "lrc", "txt"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in self?.importCaptions(from: url, language: language) }
        }
    }

    /// Export captions (TX-025): the active caption track (or every text clip when there is none) to SRT/VTT/ASS/LRC/TXT.
    func exportCaptions(format: CaptionFormat, to url: URL) {
        let tl = project.timeline
        let segs: [CaptionSegment]
        if let ti = activeCaptionTrackIndex { segs = CaptionOps.segments(of: tl.tracks[ti]) }
        else { segs = tl.tracks.filter { $0.kind == .text }.flatMap { CaptionOps.segments(of: $0) }.sorted { $0.start < $1.start } }
        guard !segs.isEmpty else { showToast(tr("captions.export.failed"), error: true); return }
        let style = activeCaptionTrackIndex.flatMap { tl.tracks[$0].clips.first }.flatMap(CaptionOps.text)
        let text = CaptionFiles.serialize(segs, format: format, style: style, canvas: project.settings.canvasSize)
        do { try text.write(to: url, atomically: true, encoding: .utf8); showToast(tr("captions.export.done")) }
        catch { showToast(tr("captions.export.failed"), error: true) }
    }

    func chooseCaptionExport(format: CaptionFormat) {
        let p = NSSavePanel()
        p.allowedContentTypes = UTType(filenameExtension: format.fileExtension).map { [$0] } ?? []
        p.nameFieldStringValue = "\(projectName).\(format.fileExtension)"
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in self?.exportCaptions(format: format, to: url) }
        }
    }

    /// "Enter scripts → Split into captions" (TX-029): captions laid back to back from the playhead.
    func addScriptCaptions(_ script: String, split: Bool) {
        let start = transport.playhead.seconds
        let segs = split ? CaptionOps.scriptSegments(script, start: start)
            : [CaptionSegment(text: script.trimmingCharacters(in: .whitespacesAndNewlines), start: start,
                              end: start + max(2, Double(script.count) / 14))]
        guard !segs.isEmpty, !segs[0].text.isEmpty else { showToast(tr("captions.script.failed"), error: true); return }
        perform(Edit("cmd.captionScript") { p in CaptionOps.addCaptionTrack(segs, to: &p, origin: .script) })
        showToast(tr("captions.added"))
    }
}
