import AppKit
import MontageCore
import MontageAI
import MontageEffects

/// Timeline context menus (UX.md §6.5–6.6, [87](../../../../docs/ux/87_ctx_menu_clip.png)): clip, keyframe, marker,
/// transition, gap, track header. Unavailable items are greyed out, not hidden (CapCut).
extension TimelineView {
    private func item(_ key: String, _ equiv: String = "", _ mods: NSEvent.ModifierFlags = [], enabled: Bool = true,
                      checked: Bool = false, _ body: @escaping () -> Void) -> NSMenuItem {
        MenuAction.item(tr(key), key: equiv, mods, enabled: enabled, checked: checked, body)
    }
    private func sub(_ key: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: tr(key), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr(key)); m.autoenablesItems = false
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }
    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        items.forEach(m.addItem)
        return m
    }

    override func rightMouseDown(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        let tl = store.project.timeline
        var m: NSMenu?
        switch l.hitTest(pt, timeline: tl, selection: store.selection) {
        case .clip(let id, _, _):
            if !store.selection.contains(id) { store.select([id]) }
            m = clipMenu()
        case .keyframe(let id, let key, let time, _):
            let ref = KeyframeRef(clip: id, key: key, time: time)
            ui.selectedKeyframe = ref
            m = keyframeMenu(ref)
        case .marker(let id):
            ui.selectedMarker = id
            m = markerMenu(id)
        case .transition(let left, _, _):
            store.selection = []; ui.selectedTransition = left
            m = transitionMenu(left)
        case .track(let ri):
            let row = l.rows[ri]
            let t = l.time(atX: pt.x)
            if TimelineOps.gap(at: t, on: row.trackID, in: tl) != nil { m = gapMenu(at: t, track: row.trackID) }
        case .header(let ri):
            m = trackMenu(tl.tracks[l.rows[ri].trackIndex])
        default: break
        }
        dirty = true
        if let m {
            if let sink = Self.uitestMenuSink { sink(m) } else { NSMenu.popUpContextMenu(m, with: e, for: self) }
        }
    }

    /// UI tests (`{"rightClick": …, "menuItem": "a/b"}`): receives the context menu instead of popping it up (a real
    /// popup runs a modal tracking loop the driver can't reach).
    @MainActor static var uitestMenuSink: ((NSMenu) -> Void)?

    // MARK: Clip

    func clipMenu() -> NSMenu {
        let s = store
        let clips = s.selectedClips
        let single = s.singleSelectedClip
        let kind = single.flatMap { s.trackKind(of: $0) }
        let isMedia = single?.mediaID != nil
        let asset = single?.mediaID.flatMap(s.project.asset)
        let isVideo = asset?.kind == .video && kind != .audio
        let visual = clips.contains { s.trackKind(of: $0)?.isVisual == true }
        let hasExtract = single.map { c in s.project.timeline.allClips.contains { $0.extractedFrom == c.id } } ?? false
        let enabledAll = clips.allSatisfy(\.isEnabled)
        let overlay = single.map { c in kind?.isVisual == true && !(s.project.timeline.locate(c.id).map { s.project.timeline.tracks[$0.track].isMain } ?? true) } ?? false

        var items: [NSMenuItem] = [
            item("tlmenu.copy", "c", .command) { s.copySelection() },
            item("tlmenu.cut", "x", .command) { s.cutSelection() },
            item("tlmenu.paste", "v", .command, enabled: !s.timelineUI.clipboard.isEmpty || NSPasteboard.general.data(forType: ClipboardPayload.type) != nil) { s.paste() },
            item("tlmenu.duplicate", "d", .command) { s.duplicateSelection() },
            item("tlmenu.copyAttributes", "c", [.command, .shift], enabled: single != nil) { s.copyAttributes() },
            item("tlmenu.pasteAttributes", "v", [.command, .shift], enabled: s.timelineUI.attributeSource != nil) { [weak self] in self?.showPasteAttributesDialog() },
            item("tlmenu.delete", "\u{8}", []) { s.deleteSelection() },
            .separator(),
            item("tlmenu.split", "b", .command) { s.split() },
            sub("tlmenu.edit", [
                item("tlmenu.freeze", enabled: isVideo) { s.freezeFrame() },
                item("tlmenu.duplicateFrame", enabled: isVideo) { s.duplicateFrame() },
                item("tlmenu.unlinkFreeze", enabled: single?.freezeSource != nil) { s.unlinkFreezeSelection() },
                item("tlmenu.reverse", enabled: isMedia && !(single?.isFreezeFrame ?? true), checked: single?.reversed ?? false) { s.reverseSelection() },
                item("tlmenu.mirror", enabled: visual) { s.mirrorSelection() },
                item("tlmenu.rotate", enabled: visual) { s.rotateSelection() },
                item("tlmenu.crop", enabled: visual && single != nil) { s.inspectorTab = "video" },
            ]),
            item("tlmenu.matchCut", enabled: !clips.isEmpty) { s.matchCut() },
            item("tlmenu.deleteClipMarkers", enabled: clips.contains { !($0.markers ?? []).isEmpty }) { s.removeClipMarkersSelection() },
            // W10 AI entries
            sub("tlmenu.splitScenes", [
                item("tlmenu.splitScenes.scene", enabled: isVideo && single != nil) { if let c = single { s.splitScenes(c.id, mode: .scene) } },
                item("tlmenu.splitScenes.shot", enabled: isVideo && single != nil) { if let c = single { s.splitScenes(c.id, mode: .shot) } },
            ]),
            item("tlmenu.generateCaptions", enabled: single.map { c in c.mediaID.flatMap(s.project.asset)?.hasAudio ?? false } ?? false) {
                if let c = single { s.ai.captionSource = .clip(c.id); s.generateCaptions() }
            },
            item("tlmenu.transcript", enabled: isMedia) { s.ai.transcriptOpen = true },
            item("tlmenu.clipper", enabled: isVideo && single != nil && asset?.hasAudio == true) { if let c = single { s.ai.clipper = AIClipperState(clipID: c.id) } },
            sub("tlmenu.separateAudio", [
                item("tlmenu.separateAudio.vocals", enabled: asset?.hasAudio == true) { if let c = single { s.separateAudio(c.id, keepVoice: true) } },
                item("tlmenu.separateAudio.music", enabled: asset?.hasAudio == true) { if let c = single { s.separateAudio(c.id, keepVoice: false) } },
            ] + (StemSeparator.availableStems.isEmpty
                 ? [item("tlmenu.separateAudio.getStems") { s.ai.isModelSheetPresented = true; s.activeAssetTab = "text" }]
                 : StemSeparator.availableStems.map { st in
                    item(st.nameKey, enabled: asset?.hasAudio == true) { if let c = single { s.separateAudio(c.id, part: .stem(st)) } }
                 })),
            item(hasExtract ? "tlmenu.restoreAudio" : "tlmenu.extractAudio", "s", [.control, .shift],
                 enabled: hasExtract || (isVideo && asset?.hasAudio == true && single?.audio.isMuted == false)) { s.extractOrRestoreAudio() },
            item("tlmenu.syncAudio", enabled: false) {},
            .separator(),
            item("tlmenu.compound", "g", .option, enabled: !clips.isEmpty) { s.createCompound() },
            item("tlmenu.uncompound", enabled: single.map { if case .compound = $0.content { return true }; return false } ?? false) {
                s.explodeCompound()
            },
            item("tlmenu.editCompound", enabled: single.map { if case .compound = $0.content { return true }; return false } ?? false) {
                if let id = single?.id { s.enterCompound(id) }
            },
            item("tlmenu.multicam", enabled: false) {},
            item("tlmenu.savePreset", enabled: false) {},
            item("tlmenu.group", "g", .command, enabled: clips.count >= 2) { s.groupSelection() },
            item("tlmenu.ungroup", "g", [.command, .shift], enabled: s.selectionIsGrouped) { s.ungroupSelection() },
            .separator(),
            item("tlmenu.exportSelected", enabled: !clips.isEmpty) { s.exportSelectedClips() },
            item(enabledAll ? "tlmenu.deactivate" : "tlmenu.activate", "v", []) { s.toggleEnabledSelection() },
            item("tlmenu.replace", enabled: isMedia) { s.replaceSelectedClip() },
            item("tlmenu.linkMedia", enabled: false) {},
            item("tlmenu.reveal", enabled: clips.contains { $0.mediaID != nil }) { s.revealSelectedInFinder() },
            .separator(),
            item("tlmenu.editEffects", enabled: single.map { !$0.effects.isEmpty } ?? false) { s.inspectorTab = "adjust" },
            item("keyframes.reset", enabled: clips.contains { !$0.keyframes.isEmpty }) { KeyframePanel.confirmReset(s) },
            item("tlmenu.speed", "r", .command, enabled: isMedia && asset?.kind != .image) { s.inspectorTab = "speed" },
            sub("tlmenu.arrange", LayerArrangement.allCases.map { a in item(a.nameKey, enabled: overlay) { s.arrange(a) } }),
            sub("tlmenu.colorLabel", [item("tlmenu.colorLabel.none") { s.setColorLabel(nil) }] +
                Self.labelColors.indices.map { i in item("tlmenu.colorLabel.\(i)") { s.setColorLabel(i) } }),
            sub("tlmenu.range", [
                item("tlmenu.range.byClip", "x", .shift) { s.rangeFromSelection() },
                item("tlmenu.range.in", "i", []) { s.setInPoint() },
                item("tlmenu.range.out", "o", []) { s.setOutPoint() },
                item("tlmenu.range.clear", enabled: s.project.timeline.inPoint != nil || s.project.timeline.outPoint != nil) { s.clearRange() },
                item("export.menu.range", enabled: s.project.timeline.inPoint != nil || s.project.timeline.outPoint != nil) { s.exportInOutRange() },
            ]),
            sub("tlmenu.render", [
                item("tlmenu.render.all") { s.renderPreview(range: nil) },
                item("tlmenu.render.inOut", enabled: s.project.timeline.inPoint != nil || s.project.timeline.outPoint != nil) {
                    s.renderPreview(range: TimeRange(start: s.project.timeline.inPoint ?? .zero,
                                                     end: s.project.timeline.outPoint ?? s.project.duration))
                },
                item("tlmenu.render.selection", enabled: !clips.isEmpty) {
                    s.renderPreview(range: TimeRange(start: clips.map(\.start).min() ?? .zero, end: clips.map(\.end).max() ?? .zero))
                },
                item("tlmenu.render.clear") { s.clearRenderCache() },
            ]),
        ]
        if kind == .audio {
            items.insert(contentsOf: [
                .separator(),
                item("tlmenu.markBeat", "m", []) { s.addMarker() },
                item("tlmenu.clearBeats", enabled: single?.beats != nil) { s.clearBeatsSelection() },
                item("tlmenu.splitAudioTrack", enabled: single?.mediaID != nil && single?.audio.channels == .stereo) { s.splitAudioChannels() },
            ], at: 9)
        }
        return menu(items)
    }

    // MARK: Paste attributes dialog (TL-011)

    func showPasteAttributesDialog() {
        guard store.timelineUI.attributeSource != nil else { return }
        let a = NSAlert()
        a.messageText = tr("attr.title")
        a.informativeText = tr("attr.message")
        a.addButton(withTitle: tr("attr.paste"))
        a.addButton(withTitle: tr("common.cancel"))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        var boxes: [(AttributeGroup, NSButton)] = []
        for g in AttributeGroup.allCases {
            let b = NSButton(checkboxWithTitle: tr(g.nameKey), target: nil, action: nil)
            b.state = store.timelineUI.pasteAttributeGroups.contains(g) ? .on : .off
            boxes.append((g, b)); stack.addArrangedSubview(b)
        }
        let timing = NSPopUpButton(frame: .zero, pullsDown: false)
        timing.addItems(withTitles: KeyframeTiming.allCases.map { tr($0.nameKey) })
        timing.selectItem(at: KeyframeTiming.allCases.firstIndex(of: store.timelineUI.pasteKeyframeTiming) ?? 0)
        let row = NSStackView(views: [NSTextField(labelWithString: tr("attr.timing")), timing])
        stack.addArrangedSubview(row)
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(boxes.count + 1) * 26)
        a.accessoryView = stack
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let groups = Set(boxes.filter { $0.1.state == .on }.map(\.0))
        let t = KeyframeTiming.allCases[max(0, timing.indexOfSelectedItem)]
        store.timelineUI.pasteAttributeGroups = groups
        store.timelineUI.pasteKeyframeTiming = t
        store.pasteAttributes(groups: groups, timing: t)
    }

    // MARK: Keyframe (UX.md §6.5, [101])

    /// Preset curves (Core `EasingPreset.all`, shared with the keyframe panel).
    static let easingPresets: [(key: String, easing: Easing)] = EasingPreset.all.map { ($0.nameKey, $0.easing) }

    func keyframeMenu(_ ref: KeyframeRef) -> NSMenu {
        let s = store
        let current = s.project.timeline.clip(ref.clip)?.keyframes[ref.key]?.keyframes.first { abs(($0.time - ref.time).ticks) < 1000 }?.easing
        func set(_ e: Easing) {
            s.edit("cmd.keyframe") { p in
                guard var track = p.timeline.clip(ref.clip)?.keyframes[ref.key],
                      let i = track.index(near: ref.time, tolerance: Time(ticks: 1000)) else { throw EditError.nothingToDo }
                track.setEasing(e, at: i)
                p.timeline[clip: ref.clip]?.keyframes[ref.key] = track
            }
        }
        return menu([
            item("easing.easeIn", checked: current == .easeIn) { set(.easeIn) },
            item("easing.easeOut", checked: current == .easeOut) { set(.easeOut) },
            item("easing.ease", checked: current == .easeInOut) { set(.easeInOut) },
            item("easing.linear", checked: current == .linear) { set(.linear) },
            sub("easing.presets", Self.easingPresets.map { p in item(p.key, checked: current == p.easing) { set(p.easing) } }),
            item("tlmenu.speed", "k", .option) { if !s.keyframeUI.showsPanel { s.toggleKeyframePanel() } },
            .separator(),
            item("tlmenu.copy", "c", .command) { s.copyKeyframes(ref) },
            item("tlmenu.delete", "\u{8}", []) { s.deleteSmart() },
        ])
    }

    // MARK: Marker

    func markerMenu(_ id: MarkerID) -> NSMenu {
        let s = store
        let colors = TimelineOps.markerColors.enumerated().map { i, col in
            item("marker.color.\(i)", checked: s.project.timeline.markers.first { $0.id == id }?.color == col) {
                s.edit("cmd.marker") { p in try TimelineOps.updateMarker(id, in: &p.timeline) { $0.color = col } }
            }
        }
        return menu([
            item("marker.edit") { [weak self] in self?.editMarker(id) },
            sub("marker.color", colors),
            .separator(),
            item("marker.delete", "\u{8}", []) { s.edit("cmd.marker.delete") { p in try TimelineOps.removeMarkers([id], in: &p.timeline) } },
            item("marker.deleteAll") { s.removeAllMarkers() },
        ])
    }

    /// "Edit marker": name + note.
    func editMarker(_ id: MarkerID) {
        guard let m = store.project.timeline.markers.first(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = tr("marker.edit")
        a.addButton(withTitle: tr("common.ok"))
        a.addButton(withTitle: tr("common.cancel"))
        let name = NSTextField(string: m.label); name.placeholderString = tr("marker.name")
        let note = NSTextField(string: m.note ?? ""); note.placeholderString = tr("marker.note")
        let stack = NSStackView(views: [name, note]); stack.orientation = .vertical; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        a.accessoryView = stack
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let label = name.stringValue, n = note.stringValue
        store.edit("cmd.marker") { p in try TimelineOps.updateMarker(id, in: &p.timeline) { $0.label = label; $0.note = n.isEmpty ? nil : n } }
    }

    // MARK: Transition

    func transitionMenu(_ left: ClipID) -> NSMenu {
        let s = store
        return menu([
            item("transition.applyAll") {
                guard let tr = s.project.timeline.clip(left)?.transitionOut else { return }
                s.edit("cmd.transition") { p in
                    guard let main = p.timeline.mainTrack else { return }
                    for c in main.clips.dropLast() { try TimelineOps.setTransition(c.id, tr, in: &p.timeline) }
                }
            },
            item("tlmenu.delete", "\u{8}", []) { s.perform(SetTransition(left, nil)); s.timelineUI.selectedTransition = nil },
        ])
    }

    // MARK: Gap

    func gapMenu(at t: Time, track: TrackID) -> NSMenu {
        let s = store
        return menu([
            item("gap.close") { s.closeGap(at: t, track: track) },
            item("gap.closeAll") { s.closeAllGaps(track: track) },
        ])
    }

    // MARK: Track volume (TL-018)

    /// "Track volume ▸" submenu: a dB slider (−30…+6 dB, release = one undo step) plus quick presets.
    func trackVolumeMenu(_ t: Track) -> NSMenuItem {
        let s = store, id = t.id
        let current = TrackVolumeMath.db(t.gain)
        let slider = TrackVolumeSliderView(db: current) { db in s.setTrackVolume(id, TrackVolumeMath.gain(db)) }
        let sliderItem = NSMenuItem(); sliderItem.view = slider
        var items: [NSMenuItem] = [sliderItem, .separator()]
        for db in [-12.0, -6.0, 0.0, 3.0, 6.0] {
            items.append(MenuAction.item(TrackVolumeMath.label(db), key: "", [], checked: abs(current - db) < 0.05) {
                s.setTrackVolume(id, TrackVolumeMath.gain(db))
            })
        }
        items.append(MenuAction.item(tr("track.volume.mute"), key: "", [], checked: t.gain == 0) { s.setTrackVolume(id, 0) })
        let i = sub("track.volume", items)
        i.title = tr("track.volume.title", TrackVolumeMath.label(current))
        return i
    }

    // MARK: Track header ⋯ (UX.md §6.3, [90])

    func trackMenu(_ t: Track) -> NSMenu {
        let s = store
        let id = t.id
        var items: [NSMenuItem] = [
            item(t.isLocked ? "track.unlock" : "track.lock") { s.toggleTrack(id, \.isLocked, key: "cmd.trackLock") },
        ]
        if t.kind.isVisual { items.append(item(t.isHidden ? "track.show" : "track.hide") { s.toggleTrack(id, \.isHidden, key: "cmd.trackHide") }) }
        if t.kind == .audio || t.kind == .video {
            items.append(item(t.isMuted ? "track.unmute" : "track.mute") { s.toggleTrack(id, \.isMuted, key: "cmd.trackMute") })
            items.append(item(t.isSolo == true ? "track.unsolo" : "track.solo") { s.toggleSolo(id) })
        }
        items.append(.separator())
        items.append(sub("track.height", TrackHeight.allCases.map { h in
            item(h.nameKey, checked: (t.heightPreset ?? .standard) == h) { s.setTrackHeight(id, h) }
        }))
        if t.kind == .audio || t.kind == .video {
            items.append(trackVolumeMenu(t))
            items.append(sub("track.waveform", [0.3, 0.6, 1.0].map { v in
                MenuAction.item("\(Int(v * 100)) %", key: "", [], checked: abs((t.waveformScale ?? 0.3) - v) < 0.01) { s.setWaveformScale(id, v) }
            }))
        }
        if !t.isMain, t.kind.isVisual {
            items.append(.separator())
            items.append(item("gap.closeAll") { s.closeAllGaps(track: id) })
        } else if t.isMain, !s.project.timeline.mainTrackMagnet {
            items.append(.separator())
            items.append(item("gap.closeAll") { s.closeAllGaps(track: id) })
        }
        return menu(items)
    }

}

extension EditorStore {
    /// TL-040 colour label for the selected clips (nil = default kind colour).
    public func setColorLabel(_ i: Int?) {
        let ids = selection
        edit("cmd.colorLabel") { p in for id in ids { p.timeline[clip: id]?.colorLabel = i } }
    }
}

/// dB ↔ linear gain for the track volume (−∞ dB = 0).
enum TrackVolumeMath {
    static let minDB = -30.0, maxDB = 6.0
    static func db(_ g: Double) -> Double { g <= 0 ? -.infinity : 20 * log10(g) }
    static func gain(_ db: Double) -> Double { db <= minDB - 0.01 || db == -.infinity ? 0 : pow(10, min(db, maxDB) / 20) }
    static func label(_ db: Double) -> String {
        guard db.isFinite else { return "−∞ dB" }
        let r = (db * 10).rounded() / 10
        let v = r == 0 ? "0" : String(format: r > 0 ? "+%.1f" : "%.1f", r).replacingOccurrences(of: "-", with: "−")
        return L10n.shared.language.hasPrefix("fr") ? v.replacingOccurrences(of: ".", with: ",") + "\u{202F}dB" : v + " dB"
    }
}

/// The slider row inside the "Track volume" submenu.
final class TrackVolumeSliderView: NSView {
    private let slider: NSSlider
    private let value = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(db: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: db.isFinite ? max(db, TrackVolumeMath.minDB) : TrackVolumeMath.minDB,
                          minValue: TrackVolumeMath.minDB, maxValue: TrackVolumeMath.maxDB, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        slider.frame = NSRect(x: 16, y: 5, width: 150, height: 20)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityIdentifier("track.volume.slider")
        value.frame = NSRect(x: 172, y: 7, width: 64, height: 16)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.stringValue = TrackVolumeMath.label(db)
        addSubview(slider); addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let db = slider.doubleValue <= TrackVolumeMath.minDB + 0.05 ? -Double.infinity : slider.doubleValue
        value.stringValue = TrackVolumeMath.label(db)
        // one undo step per release: commit when the mouse goes up
        if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent == nil { onChange(db) }
    }
}
