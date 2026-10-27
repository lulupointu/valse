import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// JSON state of the editor for UI test assertions (`dump` / `expect` steps). Stable, documented shape (docs/TESTING.md):
///
/// - `playhead`, `duration`, `isPlaying` (seconds / bool)
/// - `selection`: clip ids; `selectedClips`: clip summaries (with `track`, `index`)
/// - `undo`: `{depth, redoDepth, name, redoName, inGesture, revision, dirty}`
/// - `tracks`: model order (bottom → top), each `{index, id, kind, isMain, locked, hidden, muted, clips: [clip]}`;
///   `main`: the main track (same shape)
/// - clip: `{id, track, index, kind, name, start, duration, end, sourceStart, speed, opacity, enabled, effects, transition,
///   blend, selected}`
/// - `ui`: `{inspectorTab, inspectorTabs, assetTab, exportSheet, language, toast, pixelsPerSecond, scrollTime, scrollY,
///   menu: [top-level menu titles], anchors: [testIDs on screen]}`
/// - `app` (when the app shell runs): `{screen, modal, section, scope, search, sort, ascending, viewMode, selected, renaming,
///   projects: [visible names], entries: [{name, folder, trashed}], folders, trashCount, settings, keymap}`
/// - `media`: `[{id, name, kind, duration}]`; `project`: the full `Project` JSON (as saved in project.json)
@MainActor
public enum StateDump {
    /// App-level state (W12 `AppModel`: screen, Home library, modal, settings) → `app` in the dump.
    public static var appHook: (@MainActor () -> [String: Any])?
    public static func make(_ store: EditorStore, includeProject: Bool = true) -> [String: Any] {
        let p = store.project
        let tl = p.timeline
        func clipSummary(_ c: Clip, track: Int, index: Int) -> [String: Any] {
            var d: [String: Any] = [
                "id": c.id.description, "track": track, "index": index, "kind": kind(c.content),
                "start": c.start.seconds, "duration": c.duration.seconds, "end": c.end.seconds, "sourceStart": c.sourceStart.seconds,
                "speed": c.speed.averageRate, "opacity": c.opacity, "enabled": c.isEnabled, "blend": c.blendMode.rawValue,
                "effects": c.effects.map(\.typeID), "selected": store.selection.contains(c.id),
                "scale": c.transform.scale.x, "rotation": c.transform.rotation, "tiltX": c.transform.tilt.x, "tiltY": c.transform.tilt.y,
                "positionX": c.transform.position.x, "positionY": c.transform.position.y,
                "volume": c.audio.volume, "keyframes": Array(c.keyframes.keys).sorted(), "markers": (c.markers ?? []).map(\.time.seconds),
            ]
            if let n = c.name { d["name"] = n }
            if !c.crop.isIdentity { d["crop"] = ["left": c.crop.left, "top": c.crop.top, "right": c.crop.right, "bottom": c.crop.bottom,
                                                 "rotation": c.crop.rotation ?? 0] }   // CV-006 (F3)
            if let mid = c.mediaID, let a = p.asset(mid) { d["mediaName"] = a.name; d["mediaKind"] = a.kind.rawValue }   // F3
            if tl.tracks.indices.contains(track) { d["lane"] = tl.tracks[track].kind.rawValue }
            if case .text(let t) = c.content {
                d["text"] = t.string; if let w = t.boxWidth { d["boxWidth"] = w }
                d["strokeWidth"] = t.strokeWidth; d["strokePosition"] = t.strokePosition.rawValue   // F3 TX-005
                func spoken(_ k: KaraokeStyle) -> [String: Any] {
                    ["mode": k.mode.rawValue, "scale": (k.highlightScale * 100).rounded(), "box": k.boxColor != nil,
                     "outline": k.highlightStroke != nil,
                     "unspokenOpacity": (k.unspokenOpacity * 100).rounded(), "bounce": (k.bounce * 100).rounded()]
                }
                if let k = t.karaoke { d["spokenWord"] = spoken(k) }   // OB-10 Text ▸ Spoken word
                if let k = t.inactiveKaraoke { d["spokenWordOff"] = spoken(k) }   // FB-04: remembered while off
                if t.caption != nil { d["spokenWordOn"] = t.karaoke != nil }
            }
            if let t = c.transitionOut { d["transition"] = t.typeID; d["transitionDuration"] = t.duration.seconds }
            // W5: animations and keyframe counts per property
            d["animIn"] = c.animations.inAnim?.typeID ?? ""
            d["animOut"] = c.animations.outAnim?.typeID ?? ""
            d["animCombo"] = c.animations.combo?.typeID ?? ""
            if let v = c.keyframes[ParamKey.volume.raw] {   // C3b: volume keyframes in dB (0.1 dB)
                d["volumeKeyframesDB"] = v.keyframes.map { k -> Double in
                    let g = k.value.component(0) ?? 1
                    return g <= 0 ? -60 : (AudioProps.decibels(g) * 10).rounded() / 10
                }
                d["volumeKeyframesPct"] = v.keyframes.map { VolumePercent.percent($0.value.component(0) ?? 1) }   // AU-VOL-PCT
            }
            d["keyframeCounts"] = Dictionary(uniqueKeysWithValues: c.keyframes.map { ($0.key.replacingOccurrences(of: ".", with: "_"), $0.value.keyframes.count) })   // "transform_position"
            d["keyframeEasings"] = Dictionary(uniqueKeysWithValues: c.keyframes.map { ($0.key.replacingOccurrences(of: ".", with: "_"), $0.value.keyframes.map { Self.easingName($0.easing) }) })
            func maskSummary(_ m: Mask) -> [String: Any] {
                var s: [String: Any] = ["shape": m.shape.rawValue, "centerX": m.center.x, "centerY": m.center.y, "sizeX": m.size.x,
                                        "sizeY": m.size.y, "rotation": m.rotation, "feather": m.feather, "roundness": m.roundness]
                if let t = m.text { s["text"] = t }
                if m.shape == .pen { s["points"] = (m.points ?? Mask.defaultPenPoints).map { [$0.x, $0.y] } }
                if m.shape == .brush {
                    s["strokes"] = (m.strokes ?? []).map { ["points": $0.points.count, "erase": $0.erase, "region": $0.region?.count ?? 0] as [String: Any] }
                    s["propagation"] = m.propagation?.samples.count ?? 0   // MK-004 tracked shapes
                }
                return s
            }
            if let m = c.mask { d["mask"] = maskSummary(m) }
            if let m = c.adjustMask { d["adjustMask"] = maskSummary(m) }
            if c.content == .adjustment { d["effectScope"] = (c.effectScope ?? .all).rawValue }   // FX-004
            if let m = c.matte { d["matte"] = ["kind": m.kind, "bodyOnly": m.isBodyOnly] as [String: Any] }   // FX-002
            if let st = c.shapeStyle {   // ST-008
                d["shapeStyle"] = ["fill": st.fill != nil, "gradient": st.fillEnd != nil, "stroke": st.stroke != nil,
                                   "strokeWidth": st.strokeWidth, "dash": st.dash.rawValue, "points": st.points?.count ?? 0] as [String: Any]
            }
            return d
        }
        func trackSummary(_ t: Track, _ i: Int) -> [String: Any] {
            ["index": i, "id": t.id.description, "kind": t.kind.rawValue, "isMain": t.isMain, "locked": t.isLocked,
             "hidden": t.isHidden, "muted": t.isMuted, "solo": t.isSolo == true, "audible": tl.isAudible(t), "volume": t.gain,
             "laneHeight": Double(TimelineLayout.height(for: t.kind, isMain: t.isMain, preset: t.heightPreset)),   // TL-IMOVIE-HEIGHT
             "clips": t.clips.enumerated().map { clipSummary($1, track: i, index: $0) }]
        }
        let tracks = tl.tracks.enumerated().map { trackSummary($1, $0) }
        var selected: [[String: Any]] = []
        for id in store.selection {
            if let loc = tl.locate(id) { selected.append(clipSummary(tl.tracks[loc.track].clips[loc.clip], track: loc.track, index: loc.clip)) }
        }
        selected.sort { ($0["track"] as! Int, $0["index"] as! Int) < ($1["track"] as! Int, $1["index"] as! Int) }
        let s = store.session
        let timeline = SnapshotRegistry.shared.timeline
        let tabs = InspectorRegistry.tabs(for: InspectorContext(store: store))
        var ui: [String: Any] = [
            "inspectorTab": store.inspectorTab ?? (tabs.first?.id ?? ""),
            "inspectorTabs": tabs.map(\.id),
            "assetTab": store.activeAssetTab,
            "exportSheet": store.isExportSheetPresented,
            "coverEditor": store.timelineUI.coverEditor != nil,

            "language": L10n.shared.language,
            "pixelsPerSecond": store.pixelsPerSecond,
            "scrollTime": timeline?.scrollTime ?? 0,
            "scrollY": Double(timeline?.scrollY ?? 0),
            "followManual": timeline?.follow.manual ?? false,   // U1-6: user scrolled during playback (no auto follow)
            "rulerLabels": timeline?.visibleRulerLabels ?? [],   // TL-RULER: major tick labels on screen, left to right
            "menu": (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu?.title },
            "firstResponder": (SyntheticEvents.testWindow?.firstResponder).map { String(describing: type(of: $0)) } ?? "",
            "editingText": (SyntheticEvents.testWindow?.firstResponder as? NSText)?.string ?? NSNull(),
            "anchors": TestAnchors.shared.ids,
            "anchorFrames": Dictionary(uniqueKeysWithValues: TestAnchors.shared.ids.compactMap { id in
                TestAnchors.shared.frame(id).map { (id, [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)]) }
            }),
        ]
        if let t = store.toast { ui["toast"] = t.message }
        if let pv = store.playerUI.preview {
            ui["preview"] = ["kind": pv.kind.rawValue, "item": pv.itemID, "duration": pv.range.duration.seconds,
                             "time": (store.playerUI.previewTime - pv.range.start).seconds] as [String: Any]
        }
        ui["export"] = ExportStateDump.make(store.exports)
        if let k = store.timelineUI.selectedKeyframe { ui["selectedKeyframe"] = ["key": k.key, "time": k.time.seconds] as [String: Any] }
        ui["keyframePanel"] = store.keyframeUI.showsPanel
        ui["assets"] = AssetStateDump.make(store)   // W13 asset panel
        ui["guides"] = store.playerUI.guides.map { ["axis": $0.axis == .vertical ? "v" : "h", "position": $0.position] }   // PB-011
        ui["editingGuide"] = store.playerUI.editingGuide != nil
        ui["rulers"] = store.playerUI.showRulers
        ui["tooltipDelayMs"] = Tooltips.currentDelayMilliseconds()   // C3: hover tooltip delay app-wide
        ui["tooltip"] = TooltipCenter.shared.shownText ?? NSNull()          // C6: visible tooltip text
        ui["tooltipPending"] = TooltipCenter.shared.pendingText ?? NSNull()
        ui["modalHoverShield"] = ModalHoverGate.isActive()   // FB-07: an in-window modal owns the pointer
        ui["fit"] = HostWindowSpace.shared.dump()   // BUG-OVERSIZED-SHEETS: fitted cards / buttons inside the window
        // on-screen transition tiles whose still thumbnail has not been rendered yet (snapshots waitFor 0)
        let tiles = TestAnchors.shared.ids.filter { $0.hasPrefix("transition.tile.") }
        ui["transitionThumbsMissing"] = tiles.filter { !TransitionThumbnails.shared.hasStill("montage.transition." + $0.dropFirst("transition.tile.".count)) }.count
        if let plan = timeline?.dropPlan {   // C3-1 media drag placeholder
            var d: [String: Any] = ["start": plan.start.seconds, "duration": plan.duration.seconds]
            switch plan.placement {
            case .main(let i): d["placement"] = "main"; d["index"] = i
            case .lane(let r): d["placement"] = "lane"; d["row"] = r
            case .newLane(let s): d["placement"] = "newLane"; d["slot"] = s
            }
            if let r = timeline.flatMap({ $0.placeholderRect(plan, layout: $0.layoutNow) }) { d["x"] = Double(r.minX); d["width"] = Double(r.width) }
            ui["dropPreview"] = d
        }
        ui["keystrokes"] = ["enabled": KeystrokeFeed.shared.enabled, "items": KeystrokeFeed.shared.items.map(\.text)]   // PB-015
        ui["previewAxis"] = ["on": store.timelineUI.previewAxis, "audio": store.timelineUI.previewAxisAudio]   // TL-031
        ui["playback"] = ["framesSinceSeek": store.engine.framesSinceSeek, "lastFrameTime": store.engine.lastFrameTime.seconds,
                          "rate": Double(store.engine.player.rate)] as [String: Any]   // C3-5 freeze checks
        ui["focusedPanel"] = PanelFocus.shared.current?.rawValue ?? ""   // SE-017
        ui["numericFieldKeys"] = NumericFieldKeys.isActive   // OB-11: a focused numeric field takes ↑ / ↓
        ui["playerDetached"] = store.playerUI.isDetached   // PB-006 (other panels: ui.layout.detached)
        ui["tips"] = Onboarding.shared.dump   // PM-016 {step, whatsNew}
        ui["layout"] = EditorLayout.shared.dump   // SE-005 {preset, top, left, right, custom, activeCustom}
        if let s = SettingsScrollProbe.dump() { ui["settings"] = s }   // U1-2 {overflow, scrollX}
        ui["crop"] = CropDialogState.shared.dump   // CV-006 (F3)
        ui["fontbook"] = ["imported": FontCatalog.importedFamilies, "favorites": TextUIState.shared.favoriteFonts]   // MI-021 / MI-024 (F3)
        // AU-009 (F3): offline audio stage of the selected clip (isolate voice / noise reduction …)
        if let c = store.singleSelectedClip, let a = c.mediaID.flatMap(p.asset) {
            let spec = ClipAudioPlan.make(c.audio).render
            ui["audioStage"] = ["busy": AudioRenderCache.shared.isBusy, "identity": spec.isIdentity, "musicVocals": spec.musicVocals == true,
                                "ready": AudioRenderCache.shared.readyURL(for: a, spec: spec) != nil,
                                "progress": AudioRenderCache.shared.progress(for: a, spec: spec) ?? -1] as [String: Any]
        }
        ui["recorder"] = RecordingUI.shared.dump   // MI-015/017: {open, mode, phase, missing, canStart, permissions…}
        ui["quickCut"] = store.timelineUI.quickCut?.dump ?? ["open": false]   // TL-048 {open, value, count, removed, scope, summary, analysed, total, slices…}
        ui["pilot"] = store.pilotStateDump()   // AI2 EditPilot: {open, messages, busy, previewing, engine, state, steps, results, diff}
        ui["models"] = store.modelsStateDump()   // AI model manager states (download flow)
        ui["relight"] = ["pending": RelightUIState.shared.pendingCount]   // AI2 Relight: depth passes starting / running
        ui["transcript"] = store.transcriptStateDump()   // C4: {open, status, words, language, captionsNav, applyToAllCaptions}
        // background jobs (AI, proxies…): `{"waitFor": {"path": "ui.activeJobs", "equals": 0}}` waits for them
        ui["jobs"] = store.jobs.map { ["title": $0.titleKey, "progress": $0.progress, "state": "\($0.state)"] as [String: Any] }
        ui["activeJobs"] = store.jobs.filter { $0.state == .queued || $0.state == .running }.count
        var d: [String: Any] = [
            "playhead": store.transport.playhead.seconds,
            "duration": p.duration.seconds,
            "isPlaying": store.transport.isPlaying,
            "selection": store.selection.map(\.description).sorted(),
            "selectedClips": selected,
            "undo": ["depth": s.undoStack.count, "redoDepth": s.redoStack.count, "name": s.undoNameKey ?? "",
                     "redoName": s.redoNameKey ?? "", "inGesture": s.isInGesture, "revision": s.revision, "dirty": s.isDirty] as [String: Any],
            "tracks": tracks,
            "media": p.media.map { ["id": $0.id.description, "name": $0.name, "kind": $0.kind.rawValue, "duration": $0.duration.seconds] as [String: Any] },
            "canvas": ["width": p.settings.canvasSize.width, "height": p.settings.canvasSize.height, "aspect": p.settings.aspectPreset] as [String: Any],
            "ui": ui,
        ]
        if let m = tl.mainTrackIndex { d["main"] = tracks[m] }
        if let app = appHook?() { d["app"] = app }
        if includeProject, let data = try? JSONEncoder().encode(p), let obj = try? JSONSerialization.jsonObject(with: data) {
            d["project"] = obj
        }
        return d
    }

    /// Preset id when the easing is a library preset ("easeIn", "quadOut"…), else its case name ("bezier").
    static func easingName(_ e: Easing) -> String {
        if let p = EasingPreset.all.first(where: { $0.easing == e }) { return p.id }
        return String(String(describing: e).prefix { $0.isLetter })
    }

    static func kind(_ c: ClipContent) -> String {
        switch c {
        case .media: return "media"
        case .text: return "text"
        case .solid: return "solid"
        case .sticker: return "sticker"
        case .adjustment: return "adjustment"
        default: return String(String(describing: c).prefix { $0.isLetter })  // newer content kinds
        }
    }

    public static func write(_ obj: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }
}
