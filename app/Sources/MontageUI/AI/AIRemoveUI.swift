import SwiftUI
import AppKit
import Perception
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ AI remove (UX_AI, AI-041): brush over objects on the canvas (red), [Remove] → LaMa inpaints the
// image or every frame of a short video (≤ 30 s, static area) in the background; the clip then plays the result.
// Unticking restores the original. Needs the LaMa model (AI models list).
enum AIRemoveInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.aiRemove", tab: "video", subTab: "basic", order: 51, titleKey: "remove.title",
                         appliesTo: { ctx in
            guard let c = ctx.clip, let a = (c.removal?.original ?? c.mediaID).flatMap(ctx.store.project.asset) else { return false }
            return ObjectRemover.canProcess(a, clipSource: c.sourceRange)   // AI-041: the clip's used part ≤ 30 s
        }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                guard let c = ctx.clip else { return false }
                return c.removal != nil || ctx.store.ai.removeTool?.clipID == c.id || ctx.store.ai.removeJobs[c.id] != nil
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.beginRemoveBrush(id) } else { ctx.store.endRemoveBrush(); ctx.store.runRemoval(id, strokes: []) }
            }))
        }) { AnyView(AIRemoveSection(ctx: $0)) },
    ]
}

struct AIRemoveSection: View {
    let ctx: InspectorContext
    var isVideo: Bool {
        guard let c = ctx.clip else { return false }
        return (c.removal?.original ?? c.mediaID).flatMap(ctx.store.project.asset)?.kind == .video
    }
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let _ = ModelManager.shared.states   // re-render when the LaMa download finishes (`isAvailable` is a disk check)
            VStack(alignment: .leading, spacing: 8) {
                if !LaMaInpainter.isAvailable {
                    HintText(text: tr("remove.needsModel")).testID("remove.needsModel")
                    ModelStateControls(spec: ModelCatalog.lama)
                }
                if let id = ctx.clip?.id, let job = store.ai.removeJobs[id] {
                    let p = store.jobProgress(job) ?? 0
                    JobProgressLine(text: tr("remove.applying", JobInfo.percent(p)), progress: p) { store.cancelRemoval(id) }.testID("remove.progress")
                }
                if let tool = store.ai.removeTool, tool.clipID == ctx.clip?.id {
                    SliderRowView(label: tr("cutout.size"), unit: (tool.size - 1) / 99, originUnit: 0, gradient: nil, ticks: [],
                                  display: Fmt.int(tool.size), enabled: true, labelAccessory: nil, parse: NumberParse.number,
                                  onBegin: {}, onChange: { tool.size = 1 + $0 * 99 }, onEnd: {},
                                  commit: { tool.size = min(max($0, 1), 100) }, step: { tool.size = min(max(tool.size + Double($0), 1), 100) },
                                  triplet: nil)
                    HintText(text: tr("remove.hint"))
                    if isVideo {   // AI2 AI-041: the mask follows a moving object
                        ToggleLine(label: tr("remove.track"), detail: tr("remove.track.hint"),
                                   isOn: Binding(get: { tool.track }, set: { tool.track = $0 }))
                            .testID("remove.track")
                    }
                    HStack {
                        Spacer()
                        PillButton(title: tr("remove.clear"), enabled: !tool.strokes.isEmpty) { tool.clear() }
                        PillButton(title: tr("remove.apply"), accent: true, enabled: !tool.strokes.isEmpty && LaMaInpainter.isAvailable) { store.applyRemoveBrush() }
                            .testID("remove.apply")
                    }
                } else if ctx.clip?.removal != nil {
                    PillButton(title: tr("remove.edit"), symbol: "paintbrush.pointed") { if let id = ctx.clip?.id { store.beginRemoveBrush(id) } }
                }
            }
        }
    }
}

/// Red brush on the canvas; strokes in raw source coordinates of the clip's layer.
@MainActor @Perceptible
public final class RemoveBrushTool: CanvasTool {
    public let clipID: ClipID
    public var size: Double = 25
    /// Track object (AI-041): move the mask with the object brushed on this frame.
    public var track = false
    public private(set) var strokes: [RemovalStroke] = []
    public private(set) var revision = 0
    @PerceptionIgnored weak var store: EditorStore?
    @PerceptionIgnored private var current: [Vec2] = []
    @PerceptionIgnored private var currentCanvas: [Vec2] = []
    @PerceptionIgnored private var painted: [(pts: [Vec2], radius: Double)] = []

    init(clipID: ClipID, store: EditorStore) {
        self.clipID = clipID; self.store = store
        strokes = store.project.timeline.clip(clipID)?.removal?.strokes ?? []
        track = store.project.timeline.clip(clipID)?.removal?.tracking != nil
    }

    public func clear() { strokes = []; painted = []; revision += 1 }

    private var layer: LayerDescription? {
        guard let store else { return nil }
        return MotionTracking.layer(of: clipID, in: store.project, at: store.transport.playhead)
    }
    private var rotation: Int {
        guard let store, let c = store.project.timeline.clip(clipID) else { return 0 }
        return (c.removal?.original ?? c.mediaID).flatMap(store.project.asset)?.sourceRotation ?? 0
    }

    public func mouseDown(at p: Vec2) { current = []; currentCanvas = []; mouseDragged(at: p) }
    public func mouseDragged(at p: Vec2) {
        currentCanvas.append(p)
        if let l = layer, let store, let s = MotionTracking.sourcePoint(p, layer: l, canvas: store.project.settings.canvasSize, rotation: rotation) { current.append(s) }
        revision += 1
    }
    public func mouseUp(at p: Vec2) {
        if !current.isEmpty { strokes.append(RemovalStroke(points: current, radius: size / 400)); painted.append((currentCanvas, size)) }
        current = []; currentCanvas = []
        revision += 1
    }

    public func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        guard let l = layer, let store else { return }
        let g = l.geometry(canvasSize: store.project.settings.canvasSize)
        let layerW = abs(g.halfSize.x) * 2
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.5).cgColor)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // existing strokes, redrawn from source coordinates
        for s in strokes {
            let pts = s.points.map { MotionTracking.canvasPoint(MotionTracking.rawToDisplay($0, rotation: rotation), layer: l, canvas: store.project.settings.canvasSize) }
            ctx.setLineWidth(s.radius * layerW * 2 * scale)
            ctx.addLines(between: pts.map(toView)); if pts.count == 1 { ctx.addLine(to: toView(pts[0])) }
            ctx.strokePath()
        }
        if !currentCanvas.isEmpty {
            ctx.setLineWidth(size / 400 * layerW * 2 * scale)
            ctx.addLines(between: currentCanvas.map(toView)); if currentCanvas.count == 1 { ctx.addLine(to: toView(currentCanvas[0])) }
            ctx.strokePath()
        }
    }
}

extension EditorStore {
    public func beginRemoveBrush(_ clipID: ClipID) {
        endCutoutBrush(); endTrackingBox()
        let t = RemoveBrushTool(clipID: clipID, store: self)
        ai.removeTool = t
        playerUI.canvasTool = t
        engine.pause()
    }

    public func endRemoveBrush() {
        if playerUI.canvasTool === ai.removeTool { playerUI.canvasTool = nil }
        ai.removeTool = nil
    }

    public func applyRemoveBrush() {
        guard let t = ai.removeTool, !t.strokes.isEmpty else { return }
        let strokes = t.strokes
        // media time of the brushed frame (the strokes' reference for Track object)
        let tracking: RemovalTracking? = t.track ? project.timeline.clip(t.clipID).map { c in
            RemovalTracking(time: c.sourceTime(at: transport.playhead.clamped(c.start, c.end)).seconds)
        } : nil
        endRemoveBrush()
        runRemoval(t.clipID, strokes: strokes, tracking: tracking)
    }

    public func runRemoval(_ clipID: ClipID, strokes: [RemovalStroke], tracking: RemovalTracking? = nil) {
        cancelRemoval(clipID)
        guard !strokes.isEmpty || project.timeline.clip(clipID)?.removal != nil else { return }
        let project = self.project
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "remove.job", priority: 1, heavy: true, subject: clipID.description) { progress in
                box.command = try await ObjectRemovalJob.run(project: project, clipID: clipID, strokes: strokes, tracking: tracking) { progress.report($0) }
            }
            ai.removeJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.removeJobs[clipID] == id { ai.removeJobs[clipID] = nil }
            switch st {
            case .done: if let cmd = box.command, perform(cmd), !strokes.isEmpty { showToast(tr("remove.done")) }
            case .failed: showToast(tr("remove.failed"), error: true)
            case .cancelled: showToast(tr("remove.cancelled"))
            default: break
            }
        }
    }

    public func cancelRemoval(_ clipID: ClipID) {
        if let j = ai.removeJobs[clipID] { ai.removeJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
    }
}
