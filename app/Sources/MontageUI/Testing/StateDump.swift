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
                "scale": c.transform.scale.x, "rotation": c.transform.rotation,
                "positionX": c.transform.position.x, "positionY": c.transform.position.y,
                "volume": c.audio.volume, "keyframes": Array(c.keyframes.keys).sorted(),
            ]
            if let n = c.name { d["name"] = n }
            if tl.tracks.indices.contains(track) { d["lane"] = tl.tracks[track].kind.rawValue }
            if case .text(let t) = c.content { d["text"] = t.string; if let w = t.boxWidth { d["boxWidth"] = w } }
            if let t = c.transitionOut { d["transition"] = t.typeID; d["transitionDuration"] = t.duration.seconds }
            // W5: animations and keyframe counts per property
            d["animIn"] = c.animations.inAnim?.typeID ?? ""
            d["animOut"] = c.animations.outAnim?.typeID ?? ""
            d["animCombo"] = c.animations.combo?.typeID ?? ""
            d["keyframeCounts"] = Dictionary(uniqueKeysWithValues: c.keyframes.map { ($0.key.replacingOccurrences(of: ".", with: "_"), $0.value.keyframes.count) })   // "transform_position"
            d["keyframeEasings"] = Dictionary(uniqueKeysWithValues: c.keyframes.map { ($0.key.replacingOccurrences(of: ".", with: "_"), $0.value.keyframes.map { Self.easingName($0.easing) }) })
            func maskSummary(_ m: Mask) -> [String: Any] {
                var s: [String: Any] = ["shape": m.shape.rawValue, "centerX": m.center.x, "centerY": m.center.y, "sizeX": m.size.x,
                                        "sizeY": m.size.y, "rotation": m.rotation, "feather": m.feather, "roundness": m.roundness]
                if let t = m.text { s["text"] = t }
                if m.shape == .pen { s["points"] = (m.points ?? Mask.defaultPenPoints).map { [$0.x, $0.y] } }
                return s
            }
            if let m = c.mask { d["mask"] = maskSummary(m) }
            if let m = c.adjustMask { d["adjustMask"] = maskSummary(m) }
            return d
        }
        func trackSummary(_ t: Track, _ i: Int) -> [String: Any] {
            ["index": i, "id": t.id.description, "kind": t.kind.rawValue, "isMain": t.isMain, "locked": t.isLocked,
             "hidden": t.isHidden, "muted": t.isMuted,
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
