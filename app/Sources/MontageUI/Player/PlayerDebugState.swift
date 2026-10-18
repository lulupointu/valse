import Foundation
import MontageCore
import MontageEngine

/// `--player-state <spec>`: puts the player in a given state for screenshots / visual checks, without input events.
/// Comma-separated: `seek=<s>`, `select=text|sticker|overlay|main`, `rulers`, `guide=h:<0…1>` / `guide=v:<0…1>`,
/// `safe=<SafeZone raw>`, `zoom=<k>`, `zoombar`, `loop`, `canvas=blur|color`, `ratio=<id>`, `edit` (inline text editing),
/// `fullscreen`, `quality=<PreviewQuality raw>`.
public enum PlayerDebugState {
    public static func apply(_ spec: String, to store: EditorStore) {
        let ui = store.playerUI
        for part in spec.split(separator: ",").map(String.init) {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            let key = kv[0], value = kv.count > 1 ? kv[1] : ""
            switch key {
            case "seek": store.seek(to: Time(Double(value) ?? 0))
            case "select":
                let t = store.transport.playhead
                let tl = store.project.timeline
                let pick = tl.tracks.first { tr in
                    switch value {
                    case "text": return tr.kind == .text
                    case "sticker": return tr.kind == .sticker
                    case "main": return tr.isMain
                    default: return tr.kind == .video && !tr.isMain
                    }
                }?.clips.first { $0.range.contains(t) } ?? tl.tracks.first { $0.isMain }?.clips.first
                store.selection = pick.map { [$0.id] } ?? []
            case "rulers": ui.showRulers = true
            case "guide":
                let g = value.split(separator: ":")
                if g.count == 2, let pos = Double(g[1]) {
                    ui.guides.append(CanvasGuide(axis: g[0] == "h" ? .horizontal : .vertical, position: pos)); ui.showGuides = true
                }
            case "safe": ui.safeZone = SafeZone(rawValue: value) ?? .none
            case "zoom": ui.zoom = Double(value) ?? 1
            case "zoombar": ui.isZoomBarVisible = true
            case "loop": store.toggleLoop()
            case "ratio": store.setRatio(value)
            case "quality": store.previewQuality = PreviewQuality(rawValue: value) ?? store.previewQuality
            case "fullscreen": ui.isFullscreen = true
            case "edit": if let id = store.selection.first { ui.editingTextClip = id }
            case "canvas":
                guard let main = store.project.timeline.mainTrack else { break }
                let bg: CanvasBackground = value == "color" ? .color(RGBA(hex: 0x57BECB)) : .blur(level: 3)
                let ids = main.clips.map(\.id)
                store.perform(Edit("cmd.canvas") { p in for id in ids { p.timeline[clip: id]?.canvas = bg } })
            default: break
            }
        }
    }
}
