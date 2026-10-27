import AppKit
import ValseCore

/// Motion path on the player canvas (FEATURES KF-007): for the single selected clip with ≥ 2 position keyframes, the
/// path its centre travels (sampled with the same easing as the renderer), a diamond per keyframe (accent = the
/// selected keyframe) and a dot at the current position. Drawn by `CanvasOverlayView` under the selection box.
enum MotionPathDrawing {
    static let accent = NSColor(srgbRed: 0x57 / 255.0, green: 0xBE / 255.0, blue: 0xCB / 255.0, alpha: 1)

    /// Above this many position keyframes the diamonds are dropped (path + current dot only): they would pile up into
    /// an unreadable band over the subject.
    static let maxDiamonds = 24

    /// Camera tracking / auto reframe / AI movement write dense generated keyframes that follow the subject; their path
    /// sat right on the face (AI QA on real footage), and CapCut shows none for them. Only hand-made paths are drawn.
    static func showsPath(_ clip: Clip) -> Bool {
        clip.cameraLock == nil && clip.reframe == nil && clip.aiMovement == nil
    }

    static func showsDiamonds(_ clip: Clip) -> Bool {
        (clip.keyframes[ParamKey.position.raw]?.keyframes.count ?? 0) <= maxDiamonds
    }

    @MainActor
    static func draw(_ ctx: CGContext, viewport vp: PlayerViewport, store: EditorStore) {
        guard store.selection.count == 1, let clip = store.singleSelectedClip, showsPath(clip),
              let path = MotionPath.path(for: clip, canvas: store.project.settings.canvasSize) else { return }
        let pts = path.points.map(vp.toView)
        guard pts.count >= 2 else { return }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.addLines(between: pts)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let sel = store.timelineUI.selectedKeyframe
        let times = clip.keyframes[ParamKey.position.raw]?.keyframes.map(\.time) ?? []
        for (i, k) in path.keyframes.enumerated() where showsDiamonds(clip) {
            let p = vp.toView(k)
            let isSel = sel.map { $0.clip == clip.id && $0.key == ParamKey.position.raw && i < times.count
                && abs(($0.time - times[i]).ticks) <= keyframeRefTolerance.ticks } ?? false
            let d = CGMutablePath()
            d.move(to: CGPoint(x: p.x, y: p.y - 6)); d.addLine(to: CGPoint(x: p.x + 6, y: p.y))
            d.addLine(to: CGPoint(x: p.x, y: p.y + 6)); d.addLine(to: CGPoint(x: p.x - 6, y: p.y)); d.closeSubpath()
            ctx.setFillColor((isSel ? accent : NSColor.white).cgColor)
            ctx.addPath(d); ctx.fillPath()
        }
        // current position
        let local = (store.transport.playhead - clip.start).clamped(.zero, clip.duration)
        if let v = clip.value(.position, at: local)?.vec2 {
            let canvas = store.project.settings.canvasSize
            let c = vp.toView(Vec2(canvas.width / 2 + v.x * canvas.width, canvas.height / 2 + v.y * canvas.height))
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
        }
        ctx.restoreGState()
    }
}
