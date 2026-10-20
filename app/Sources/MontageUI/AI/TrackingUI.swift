import SwiftUI
import AppKit
import Perception
import MontageCore
import MontageEngine
import MontageAI

// Text / Sticker ▸ Tracking (UX.md §5.2–5.3, AI-014 / ST-005): tiles ⊘ None · Motion tracking. Motion
// tracking shows a yellow box on the canvas (drag to move, corners to resize, drag outside to draw a new one) over
// the video below; [Start tracking] runs Vision object tracking forward and backward in the background (progress on
// the clip), then writes the clip's position (+ scale) keyframes as one undo step.

enum TrackingInspector {
    @MainActor static let tabs: [InspectorTab] = [
        InspectorTab(id: "tracking", titleKey: "inspector.tab.tracking", order: 7, appliesTo: { ctx in
            guard ctx.store.selection.count == 1, let c = ctx.clip else { return false }
            switch c.content {
            case .text, .sticker: return !TextInspector.isCaption(ctx)
            default: return false
            }
        }),
    ]
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "tracking.mode", tab: "tracking", order: 0, titleKey: nil) { AnyView(TrackingSection(ctx: $0)) },
    ]
}

/// Session-only "Scale with object" choice.
@MainActor @Perceptible final class TrackingUIState {
    static let shared = TrackingUIState()
    var scaleWithObject = false
}

struct TrackingSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let clip = ctx.clip
            let tool = store.ai.trackTool.flatMap { $0.clipID == clip?.id ? $0 : nil }
            let on = tool != nil || clip?.tracking != nil || clip.map { store.ai.trackingJobs[$0.id] != nil } ?? false
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    tile(symbol: "nosign", title: tr("tracking.none"), selected: !on, id: "tracking.none") {
                        if let id = clip?.id { store.removeTracking(id) }
                    }
                    tile(symbol: "scope", title: tr("tracking.motion"), selected: on, id: "tracking.motion") {
                        if let id = clip?.id, tool == nil { store.beginTrackingBox(id) }
                    }
                    Spacer()
                }
                if let id = clip?.id, let job = store.ai.trackingJobs[id] {
                    let p = store.jobProgress(job) ?? 0
                    JobProgressLine(text: tr("tracking.applying", JobInfo.percent(p)), progress: p) { store.cancelTracking(id) }
                }
                if on {
                    ToggleLine(label: tr("tracking.scale"), isOn: Binding(get: { TrackingUIState.shared.scaleWithObject },
                                                                          set: { TrackingUIState.shared.scaleWithObject = $0 }))
                    if let tool {
                        HintText(text: tr(tool.referenceAvailable ? "tracking.hint" : "tracking.noVideo"))
                        HStack {
                            Spacer()
                            PillButton(title: tr("ai.cancel")) { store.endTrackingBox() }
                            PillButton(title: tr("tracking.start"), accent: true, enabled: tool.referenceAvailable) { store.startTracking() }
                                .testID("tracking.start")
                        }
                    } else if clip?.tracking != nil {
                        HintText(text: tr("tracking.applied"))
                        PillButton(title: tr("tracking.again"), symbol: "scope") { if let id = clip?.id { store.beginTrackingBox(id) } }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    func tile(symbol: String, title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white)
                Text(verbatim: title).font(.system(size: 11)).foregroundStyle(IStyle.caption).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4).frame(width: 104, height: 70)
            .background(IStyle.tile, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testID(id)
    }
}

// MARK: - Box tool on the canvas

/// Yellow tracking box (canvas pixels). Drag inside = move, near a corner = resize, outside = draw a new box.
@MainActor @Perceptible
public final class MotionTrackBoxTool: CanvasTool {
    public let clipID: ClipID
    public private(set) var revision = 0
    /// Box in canvas pixels.
    public var rect: CGRect
    @PerceptionIgnored weak var store: EditorStore?
    @PerceptionIgnored private var mode: Mode = .none
    @PerceptionIgnored private var anchor = Vec2.zero
    @PerceptionIgnored private var startRect = CGRect.zero
    enum Mode { case none, move, resize(Int), draw }

    init(clipID: ClipID, store: EditorStore) {
        self.clipID = clipID
        self.store = store
        let canvas = store.project.settings.canvasSize
        let side = min(canvas.width, canvas.height) * 0.25
        var c = Vec2(canvas.width / 2, canvas.height / 2)
        if let l = CanvasLayers.at(store.transport.playhead, project: store.project).first(where: { $0.clipID == clipID }) { c = l.geometry.center }
        rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        // when re-tracking, start from the previous box
        if let info = store.project.timeline.clip(clipID)?.tracking, let r = canvasRect(of: info) { rect = r }
    }

    /// The video layer under the box centre at the playhead (topmost, not the follower itself).
    var reference: (layer: LayerDescription, clip: Clip, asset: MediaAsset)? {
        guard let store else { return nil }
        let p = store.project, t = store.transport.playhead
        let canvas = p.settings.canvasSize
        let center = Vec2(rect.midX, rect.midY)
        let layers = FrameEvaluator.evaluate(p, at: t).items.compactMap { item -> LayerDescription? in
            switch item { case .layer(let l): return l; case .transition(_, let to, _, _, _): return to; default: return nil }
        }
        for l in layers.reversed() where l.clipID != clipID {
            guard let c = p.timeline.clip(l.clipID), let a = c.mediaID.flatMap(p.asset), a.kind == .video,
                  l.geometry(canvasSize: canvas).contains(center) else { continue }
            return (l, c, a)
        }
        return nil
    }
    var referenceAvailable: Bool { reference != nil }

    func canvasRect(of info: MotionTrackInfo) -> CGRect? {
        guard let store, let l = MotionTracking.layer(of: info.referenceClipID, in: store.project, at: store.transport.playhead),
              let a = store.project.timeline.clip(info.referenceClipID)?.mediaID.flatMap(store.project.asset) else { return nil }
        let canvas = store.project.settings.canvasSize
        let p0 = MotionTracking.canvasPoint(MotionTracking.rawToDisplay(Vec2(info.box.x, info.box.y), rotation: a.sourceRotation), layer: l, canvas: canvas)
        let p1 = MotionTracking.canvasPoint(MotionTracking.rawToDisplay(Vec2(info.box.x + info.box.width, info.box.y + info.box.height), rotation: a.sourceRotation), layer: l, canvas: canvas)
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    /// The tracking request for the current box (nil without a video under it).
    func info(scaleWithObject: Bool) -> MotionTrackInfo? {
        guard let (l, c, a) = reference, let store, case .media(_, let mediaTime) = l.source else { return nil }
        let canvas = store.project.settings.canvasSize
        let pts = [Vec2(rect.minX, rect.minY), Vec2(rect.maxX, rect.maxY), Vec2(rect.minX, rect.maxY), Vec2(rect.maxX, rect.minY)]
            .compactMap { MotionTracking.sourcePoint(clampInside($0, l, canvas), layer: l, canvas: canvas, rotation: a.sourceRotation) }
        guard pts.count == 4 else { return nil }
        let x0 = pts.map(\.x).min()!, x1 = pts.map(\.x).max()!, y0 = pts.map(\.y).min()!, y1 = pts.map(\.y).max()!
        let box = NormRect(x: max(0, x0), y: max(0, y0), width: min(1, x1) - max(0, x0), height: min(1, y1) - max(0, y0))
        guard !box.isEmpty else { return nil }
        return MotionTrackInfo(referenceClipID: c.id, startTime: mediaTime.seconds, box: box, scaleWithObject: scaleWithObject)
    }

    /// Pulls a canvas point inside the layer so a box overlapping its edge still maps.
    private func clampInside(_ p: Vec2, _ l: LayerDescription, _ canvas: Size2) -> Vec2 {
        let g = l.geometry(canvasSize: canvas)
        if g.contains(p) { return p }
        let d = p - g.center
        let c = cos(-g.rotation), s = sin(-g.rotation)
        let x = min(max(d.x * c - d.y * s, -abs(g.halfSize.x)), abs(g.halfSize.x)), y = min(max(d.x * s + d.y * c, -abs(g.halfSize.y)), abs(g.halfSize.y))
        let c2 = cos(g.rotation), s2 = sin(g.rotation)
        return Vec2(g.center.x + x * c2 - y * s2, g.center.y + x * s2 + y * c2)
    }

    private var handleRadius: Double { (store.map { min($0.project.settings.canvasSize.width, $0.project.settings.canvasSize.height) } ?? 1080) * 0.03 }

    private var corners: [Vec2] { [Vec2(rect.minX, rect.minY), Vec2(rect.maxX, rect.minY), Vec2(rect.minX, rect.maxY), Vec2(rect.maxX, rect.maxY)] }

    public func mouseDown(at p: Vec2) {
        anchor = p; startRect = rect
        if let i = corners.firstIndex(where: { ($0 - p).length <= handleRadius * 1.5 }) { mode = .resize(i) }
        else if rect.contains(CGPoint(x: p.x, y: p.y)) { mode = .move }
        else { mode = .draw; rect = CGRect(x: p.x, y: p.y, width: 0, height: 0) }
        revision += 1
    }

    public func mouseDragged(at p: Vec2) {
        let d = p - anchor
        switch mode {
        case .move: rect = startRect.offsetBy(dx: d.x, dy: d.y)
        case .resize(let i):
            // the opposite corner stays fixed
            let fixed = [Vec2(startRect.maxX, startRect.maxY), Vec2(startRect.minX, startRect.maxY),
                         Vec2(startRect.maxX, startRect.minY), Vec2(startRect.minX, startRect.minY)][i]
            rect = Self.rect(fixed, p)
        case .draw: rect = Self.rect(anchor, p)
        case .none: break
        }
        revision += 1
    }

    public func mouseUp(at p: Vec2) {
        mouseDragged(at: p)
        if rect.width < 8 || rect.height < 8 { rect = startRect.width >= 8 ? startRect : rect.insetBy(dx: -40, dy: -40) }
        mode = .none
        revision += 1
    }

    static func rect(_ a: Vec2, _ b: Vec2) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    public func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        let a = toView(Vec2(rect.minX, rect.minY)), b = toView(Vec2(rect.maxX, rect.maxY))
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let yellow = NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 1).cgColor
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 0.12).cgColor); ctx.fill(r)
        ctx.setStrokeColor(yellow); ctx.setLineWidth(2); ctx.stroke(r)
        // centre cross + corner handles
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: r.midX - 6, y: r.midY), CGPoint(x: r.midX + 6, y: r.midY),
                                         CGPoint(x: r.midX, y: r.midY - 6), CGPoint(x: r.midX, y: r.midY + 6)])
        ctx.setFillColor(yellow)
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        }
    }
}

extension EditorStore {
    public func beginTrackingBox(_ clipID: ClipID) {
        endCutoutBrush()
        let tool = MotionTrackBoxTool(clipID: clipID, store: self)
        ai.trackTool = tool
        playerUI.canvasTool = tool
        engine.pause()
    }

    public func endTrackingBox() {
        if playerUI.canvasTool === ai.trackTool { playerUI.canvasTool = nil }
        ai.trackTool = nil
    }

    /// Starts tracking the box of the active tool (background job, progress on the clip).
    public func startTracking() {
        guard let tool = ai.trackTool, let info = tool.info(scaleWithObject: TrackingUIState.shared.scaleWithObject) else {
            showToast(tr("tracking.noVideo"), error: true); return
        }
        endTrackingBox()
        track(tool.clipID, info: info)
    }

    public func track(_ clipID: ClipID, info: MotionTrackInfo) {
        if let j = ai.trackingJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        let project = self.project
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "tracking.job", priority: 1, heavy: true, subject: clipID.description) { progress in
                box.command = try await MotionTrackingJob.run(project: project, follower: clipID, info: info) { progress.report($0) }
            }
            ai.trackingJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.trackingJobs[clipID] == id { ai.trackingJobs[clipID] = nil }
            switch st {
            case .done:
                guard let cmd = box.command else { return }
                if perform(cmd) { showToast(tr("tracking.done")) }
            case .failed: showToast(tr("tracking.failed"), error: true)
            case .cancelled: showToast(tr("tracking.cancelled"))
            default: break
            }
        }
    }

    public func cancelTracking(_ clipID: ClipID) {
        if let j = ai.trackingJobs[clipID] { ai.trackingJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
    }

    /// ⊘ None: stops the box tool / job and removes the tracking keyframes.
    public func removeTracking(_ clipID: ClipID) {
        if ai.trackTool?.clipID == clipID { endTrackingBox() }
        cancelTracking(clipID)
        guard project.timeline.clip(clipID)?.tracking != nil else { return }
        perform(Edit("cmd.tracking") { p in try MotionTracking.remove(from: clipID, in: &p) })
    }
}
