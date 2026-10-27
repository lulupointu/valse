import SwiftUI
import ValseCore
import ValseEngine
import ValseAI
import Perception

// Video ▸ Basic ▸ ☐ Camera tracking (UX_AI §4.8, AI-013): target Face / Body, ☐ Keep face size, canvas Fit / Blur.
// Ticking (or changing an option) runs the analysis in the background (progress on the clip); the result is the clip's
// position (+ scale) keyframes, one undo step. Excludes auto reframe.
enum CameraLockInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.cameraLock", tab: "video", subTab: "basic", order: 44, titleKey: "cameraLock.title",
                         appliesTo: { $0.isMediaVideo }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding.perceived(get: {
                ctx.clip?.cameraLock != nil || ctx.clip.map { ctx.store.ai.cameraJobs[$0.id] != nil || CameraLockUIState.shared.boxTool?.clipID == $0.id } ?? false
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on {
                    let o = CameraLockUIState.shared.options
                    if o.target == .custom && o.customBox == nil { ctx.store.beginLockBox(id) } else { ctx.store.cameraLock(id, options: o) }
                } else { ctx.store.endLockBox(); ctx.store.removeCameraLock(id) }
            }))
        }) { AnyView(CameraLockSection(ctx: $0)) },
    ]
}

@MainActor @Perceptible final class CameraLockUIState {
    static let shared = CameraLockUIState()
    var options = CameraLockOptions()
    /// Custom box target: the box being drawn on the canvas.
    var boxTool: LockBoxTool?
}

struct CameraLockSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let o = ctx.clip?.cameraLock ?? CameraLockUIState.shared.options
            VStack(alignment: .leading, spacing: 4) {
                if let id = ctx.clip?.id, let job = ctx.store.ai.cameraJobs[id] {
                    let p = ctx.store.jobProgress(job) ?? 0
                    JobProgressLine(text: tr("cameraLock.applying", JobInfo.percent(p)), progress: p) { ctx.store.removeCameraLock(id) }
                }
                InlineRow(label: tr("cameraLock.target")) {
                    Dropdown(items: CameraLockOptions.Target.allCases.map { ($0, tr($0.nameKey)) }, selection: o.target) { v in update { $0.target = v } }
                }
                if o.target == .custom || (ctx.clip.map { CameraLockUIState.shared.boxTool?.clipID == $0.id } ?? false), let id = ctx.clip?.id {   // AI2: custom box
                    if CameraLockUIState.shared.boxTool?.clipID == id {
                        HintText(text: tr("cameraLock.box.hint"))
                        HStack {
                            Spacer()
                            PillButton(title: tr("cameraLock.box.track"), accent: true) { ctx.store.trackLockBox() }.testID("cameraLock.track")
                        }
                    } else {
                        PillButton(title: tr("cameraLock.box.edit"), symbol: "viewfinder") { ctx.store.beginLockBox(id) }.testID("cameraLock.editBox")
                    }
                } else if let id = ctx.clip?.id {
                    // UX_AI §4.8 "(+ a custom box)": one click to draw a box instead of a detected subject
                    PillButton(title: tr("cameraLock.target.custom"), symbol: "viewfinder") {
                        CameraLockUIState.shared.options.target = .custom
                        CameraLockUIState.shared.options.customBox = nil
                        ctx.store.beginLockBox(id)
                    }.testID("cameraLock.customBox")
                }
                ToggleLine(label: tr(o.target.keepSizeKey),
                           isOn: Binding.perceived(get: { o.keepSize }, set: { v in update { $0.keepSize = v } }))
                InlineRow(label: tr("cameraLock.fill")) {
                    Dropdown(items: CameraLockOptions.Fill.allCases.map { ($0, tr($0.nameKey)) }, selection: o.fill) { v in update { $0.fill = v } }
                }
                HintText(text: tr("cameraLock.hint"))
            }
        }
    }

    func update(_ body: (inout CameraLockOptions) -> Void) {
        var o = ctx.clip?.cameraLock ?? CameraLockUIState.shared.options
        body(&o)
        CameraLockUIState.shared.options = o
        guard let id = ctx.clip?.id else { return }
        if o.target == .custom && o.customBox == nil { ctx.store.beginLockBox(id); return }
        if o.target != .custom { ctx.store.endLockBox() }
        if ctx.clip?.cameraLock != nil { ctx.store.cameraLock(id, options: o) }
    }
}

extension EditorStore {
    public func cameraLock(_ clipID: ClipID, options: CameraLockOptions) {
        if let j = ai.cameraJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        let project = self.project
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "cameraLock.job", priority: 1, heavy: true, subject: clipID.description) { progress in
                box.command = try await CameraLockJob.run(project: project, clipID: clipID, options: options) { progress.report($0) }
            }
            ai.cameraJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.cameraJobs[clipID] == id { ai.cameraJobs[clipID] = nil }
            switch st {
            case .done: if let cmd = box.command, perform(cmd) { showToast(tr("cameraLock.done")) }
            case .failed: showToast(tr("cameraLock.failed"), error: true)
            case .cancelled: showToast(tr("cameraLock.cancelled"))
            default: break
            }
        }
    }

    public func removeCameraLock(_ clipID: ClipID) {
        if let j = ai.cameraJobs[clipID] { ai.cameraJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard project.timeline.clip(clipID)?.cameraLock != nil else { return }
        perform(UpdateClip(clipID, nameKey: "cmd.cameraLock") { CameraLock.remove(&$0) })
    }
}


/// Custom box target (AI-013): the yellow box tool of motion tracking, drawn over the clip's own layer; Track converts
/// it to raw source coordinates at the playhead's media time.
@MainActor @Perceptible
public final class LockBoxTool: CanvasTool {
    public let clipID: ClipID
    let box: MotionTrackBoxTool
    @PerceptionIgnored weak var store: EditorStore?
    init(clipID: ClipID, store: EditorStore) {
        self.clipID = clipID; self.store = store
        box = MotionTrackBoxTool(clipID: clipID, store: store)
    }
    public var revision: Int { box.revision }
    public func mouseDown(at p: Vec2) { box.mouseDown(at: p) }
    public func mouseDragged(at p: Vec2) { box.mouseDragged(at: p) }
    public func mouseUp(at p: Vec2) { box.mouseUp(at: p) }
    public func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) { box.draw(in: ctx, toView: toView, scale: scale) }

    /// (box in raw source coords, media time) for the current rect; nil when it doesn't cover the clip.
    func target() -> (NormRect, Double)? {
        guard let store, let c = store.project.timeline.clip(clipID), let a = c.mediaID.flatMap(store.project.asset),
              let l = MotionTracking.layer(of: clipID, in: store.project, at: store.transport.playhead),
              case .media(_, let mediaTime) = l.source else { return nil }
        let canvas = store.project.settings.canvasSize, r = box.rect
        // corners outside the layer are pulled onto its edge (a box overlapping the frame still maps)
        let g = l.geometry(canvasSize: canvas)
        func inside(_ p: Vec2) -> Vec2 {
            let d = p - g.center, c = cos(-g.rotation), sn = sin(-g.rotation)
            let x = min(max(d.x * c - d.y * sn, -abs(g.halfSize.x)), abs(g.halfSize.x))
            let y = min(max(d.x * sn + d.y * c, -abs(g.halfSize.y)), abs(g.halfSize.y))
            let c2 = cos(g.rotation), s2 = sin(g.rotation)
            return Vec2(g.center.x + x * c2 - y * s2, g.center.y + x * s2 + y * c2)
        }
        let pts = [Vec2(r.minX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY), Vec2(r.maxX, r.minY)]
            .compactMap { MotionTracking.sourcePoint(inside($0), layer: l, canvas: canvas, rotation: a.sourceRotation) }
        guard pts.count >= 2 else { return nil }
        let x0 = max(0, pts.map(\.x).min()!), x1 = min(1, pts.map(\.x).max()!)
        let y0 = max(0, pts.map(\.y).min()!), y1 = min(1, pts.map(\.y).max()!)
        let b = NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return b.isEmpty ? nil : (b, mediaTime.seconds)
    }
}

extension EditorStore {
    public func beginLockBox(_ clipID: ClipID) {
        endCutoutBrush(); endTrackingBox(); endRemoveBrush()
        // drawing a box replaces a detection that is still running
        if let j = ai.cameraJobs[clipID] { ai.cameraJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        let t = LockBoxTool(clipID: clipID, store: self)
        CameraLockUIState.shared.boxTool = t
        playerUI.canvasTool = t
        engine.pause()
    }

    public func endLockBox() {
        if let t = CameraLockUIState.shared.boxTool, playerUI.canvasTool === t { playerUI.canvasTool = nil }
        CameraLockUIState.shared.boxTool = nil
    }

    /// Track ▸ runs camera tracking on the drawn box.
    public func trackLockBox() {
        guard let t = CameraLockUIState.shared.boxTool, let (box, time) = t.target() else { showToast(tr("tracking.noVideo"), error: true); return }
        var o = CameraLockUIState.shared.options
        o.target = .custom; o.customBox = box; o.customTime = time
        CameraLockUIState.shared.options = o
        endLockBox()
        cameraLock(t.clipID, options: o)
    }
}
