import Foundation
import MontageCore
import MontageEngine
import MontageEffects

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
                    case "audio": return tr.kind == .audio
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
            // inspector (screenshots): tab=<id>, sub=<tab>:<subTab>, voice=<voice preset id suffix>
            case "tab": store.inspectorTab = value
            case "assets": store.activeAssetTab = value
            case "audiolib": AudioLibraryUIState.shared.section = value
            case "sub":
                let p = value.split(separator: ":").map(String.init)
                if p.count == 2 { InspectorUIState.shared.subTab[p[0]] = p[1] }
            case "voice": if let d = VoiceEffects.descriptor("montage.voice.\(value)") { store.applyVoice(d.makeEffect(), toAll: false) }
            case "expand": InspectorUIState.shared.expanded[value] = true
            // W5: transition=<name> (at the playhead's cut, selected), anim=in|out|combo:<name> on the selection,
            // kfdemo (position keyframes + curve on the selected clip → motion path), kfpanel (keyframe panel)
            case "transition": if let d = Registries.transitions["montage.transition.\(value)"] { store.applyTransition(d) }
            case "anim":
                let p = value.split(separator: ":").map(String.init)
                guard p.count == 2, let c = store.singleSelectedClip, let d = Registries.animations["montage.anim.\(p[0]).\(p[1])"] else { break }
                let id = c.id, phase = p[0]
                store.perform(UpdateClip(id, nameKey: "cmd.animation") { c in
                    let inst = AnimationInstance(typeID: d.id, duration: min(d.defaultDuration, c.duration * 0.5))
                    if phase == "in" { c.animations.inAnim = inst } else if phase == "out" { c.animations.outAnim = inst } else { c.animations.combo = inst }
                })
            case "kfdemo":
                guard let c = store.singleSelectedClip else { break }
                let id = c.id, d = c.duration
                store.perform(UpdateClip(id, nameKey: "cmd.keyframe") { c in
                    c.toggleKeyframes(ParamKey.transformGroup, at: .zero, tolerance: Time(ticks: 1))
                    c.setValue(.scale, .vec2(Vec2(0.6, 0.6)), at: .zero)
                    c.setValue(.position, .vec2(Vec2(-0.25, 0.2)), at: .zero)
                    c.setValue(.position, .vec2(Vec2(0.0, -0.18)), at: d * 0.5)
                    c.setValue(.position, .vec2(Vec2(0.25, 0.2)), at: d * 0.95)
                    c.setEasing(.easeInOut, key: ParamKey.position.raw, at: .zero, tolerance: Time(ticks: 1), allSegments: true)
                })
                store.timelineUI.selectedKeyframe = KeyframeRef(clip: id, key: ParamKey.position.raw, time: .zero)
            case "kfpanel": if !store.keyframeUI.showsPanel { store.toggleKeyframePanel() }
            default: break
            }
        }
    }
}
