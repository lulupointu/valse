import SwiftUI
import AppKit
import Observation
@preconcurrency import AVFoundation
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Cutout ▸ ☐ Auto cutout / ☐ Customized (UX_AI §3, CK-002/003/004). Ticking runs the matte job in the
// background (progress on the clip in the timeline + in the section); the result is `Clip.matte`, composited by the
// render engine through `MatteStore`.

enum CutoutInspector {
    static func autoKinds(_ c: Clip?) -> Bool { c?.matte.map { $0.kind == "person" || $0.kind == "subject" } ?? false }
    static func isCustom(_ c: Clip?) -> Bool { c?.matte?.kind.hasPrefix("custom.") ?? false }

    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "cutout.auto", tab: "video", subTab: "cutout", order: 0, titleKey: "inspector.cutout.auto",
                         appliesTo: { $0.clip?.mediaID != nil }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: { autoKinds(ctx.clip) }, set: { on in
                guard let id = ctx.clip?.id else { return }
                ctx.store.setCutout(id, mode: on ? (CutoutUIState.shared.subject ? .subject : .person) : nil)
            }))
        }) { AnyView(AutoCutoutSection(ctx: $0)) },
        InspectorSection(id: "cutout.custom", tab: "video", subTab: "cutout", order: 1, titleKey: "inspector.cutout.custom",
                         appliesTo: { $0.clip?.mediaID != nil }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: { isCustom(ctx.clip) || ctx.store.ai.brush?.clipID == ctx.clip?.id && ctx.clip != nil },
                                                      set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.beginCutoutBrush(id) } else { ctx.store.endCutoutBrush(); if isCustom(ctx.clip) { ctx.store.setCutout(id, mode: nil) } }
            }), reset: { ctx.store.ai.brush?.clear() })
        }) { AnyView(CustomCutoutSection(ctx: $0)) },
    ]
}

/// Session-only UI choice of the auto cutout detector.
@MainActor @Observable final class CutoutUIState {
    static let shared = CutoutUIState()
    var subject = false
}

struct AutoCutoutSection: View {
    let ctx: InspectorContext
    var body: some View {
        let clip = ctx.clip
        VStack(alignment: .leading, spacing: 4) {
            if let id = clip?.id, let p = ctx.store.cutoutProgress(id) {
                JobProgressLine(text: tr("cutout.applying", JobInfo.percent(p)), progress: p) { ctx.store.setCutout(id, mode: nil) }
            }
            InlineRow(label: tr("cutout.detect")) {
                Dropdown(items: [(false, tr("cutout.detect.people")), (true, tr("cutout.detect.subject"))],
                         selection: clip?.matte?.kind == "subject") { subj in
                    CutoutUIState.shared.subject = subj
                    if let id = clip?.id { ctx.store.setCutout(id, mode: subj ? .subject : .person) }
                }
            }
            MatteRefineRows(ctx: ctx)
        }
    }
}

/// Feather edge / Expand (dilate-erode) / Invert, shared by auto and customized cutout.
struct MatteRefineRows: View {
    let ctx: InspectorContext
    var body: some View {
        ClipParamRow(ctx: ctx, label: tr("cutout.feather"), spec: RowSpec(range: 0...100, step: 1, format: Fmt.int),
                     get: { c, _ in (c.matte?.feather ?? 0) * 100 }, set: { c, v, _ in c.matte?.feather = v / 100 }, gestureName: "cmd.cutout")
        ClipParamRow(ctx: ctx, label: tr("cutout.expand"), spec: RowSpec(range: -100...100, origin: 0, step: 1, format: Fmt.int),
                     get: { c, _ in (c.matte?.expand ?? 0) * 100 }, set: { c, v, _ in c.matte?.expand = v / 100 }, gestureName: "cmd.cutout")
        // Matting blend (CK-008): smooths the cut-out edge along image edges and removes background colour spill.
        ClipParamRow(ctx: ctx, label: tr("cutout.edgeBlend"), spec: RowSpec(range: 0...100, step: 1, format: Fmt.int),
                     get: { c, _ in (c.matte?.edgeBlend ?? 0) * 100 }, set: { c, v, _ in c.matte?.edgeBlend = v > 0 ? v / 100 : nil },
                     gestureName: "cmd.cutout")
        ToggleLine(label: tr("cutout.invert"), isOn: Bind.binding(ctx, "cmd.cutout", get: { $0.matte?.inverted ?? false },
                                                                  set: { $0.matte?.inverted = $1 }, default: false))
    }
}

/// "Applying auto cutout... 37%" + cancel ✕.
struct JobProgressLine: View {
    let text: String
    let progress: Double
    var cancel: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: text).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                if let cancel { SmallIconButton(symbol: "xmark.circle.fill", help: tr("ai.cancel"), size: 13, action: cancel).testID("job.cancel") }
            }
            ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
        }
        .padding(.vertical, 6)
    }
}

struct CustomCutoutSection: View {
    let ctx: InspectorContext
    var body: some View {
        let store = ctx.store
        VStack(alignment: .leading, spacing: 10) {
            if let id = ctx.clip?.id, let p = store.cutoutProgress(id) {
                JobProgressLine(text: tr("cutout.applyingCustom", JobInfo.percent(p)), progress: p) { store.setCutout(id, mode: nil) }
            }
            if let brush = store.ai.brush, brush.clipID == ctx.clip?.id {
                HStack(spacing: 10) {
                    toolButton(brush, .quickBrush, "paintbrush.pointed.fill", tr("cutout.quickBrush"))
                    toolButton(brush, .quickEraser, "eraser.fill", tr("cutout.quickEraser"))
                    Spacer()
                }
                SliderRowView(label: tr("cutout.size"), unit: (brush.size - 1) / 99, originUnit: 0, gradient: nil, ticks: [],
                              display: Fmt.int(brush.size), enabled: true, labelAccessory: nil, parse: NumberParse.number,
                              onBegin: {}, onChange: { brush.size = 1 + $0 * 99 }, onEnd: {},
                              commit: { brush.size = min(max($0, 1), 100) }, step: { brush.size = min(max(brush.size + Double($0), 1), 100) },
                              triplet: nil)
                HintText(text: tr(brush.strokes.isEmpty ? "cutout.brushHint" : (brush.previewing ? "cutout.previewing" : "cutout.brushReady")))
                HStack {
                    Spacer()
                    PillButton(title: tr("ai.cancel")) { store.endCutoutBrush() }
                    PillButton(title: tr("cutout.apply"), accent: true, enabled: !brush.strokes.isEmpty) { store.applyCutoutBrush() }
                        .testID("cutout.apply")
                }
            } else if CutoutInspector.isCustom(ctx.clip) {
                MatteRefineRows(ctx: ctx)
                PillButton(title: tr("cutout.editSelection"), symbol: "paintbrush.pointed") { if let id = ctx.clip?.id { store.beginCutoutBrush(id) } }
            }
        }
    }

    func toolButton(_ b: CutoutBrushTool, _ t: CutoutBrushTool.Tool, _ symbol: String, _ help: String) -> some View {
        Button { b.tool = t } label: {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(b.tool == t ? Theme.accentDim : IStyle.tile, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(b.tool == t ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Brush tool on the canvas

/// Customized cutout brush (canvas tool): paint over objects on the current frame (Quick brush selects whole objects,
/// Quick eraser deselects), see the selection tinted live, then Apply → the selection is propagated through the clip.
@MainActor @Observable
public final class CutoutBrushTool: CanvasTool {
    public enum Tool: Sendable { case quickBrush, quickEraser }
    public let clipID: ClipID
    public var tool: Tool = .quickBrush
    /// CapCut "Size" 1…100.
    public var size: Double = 20
    public private(set) var strokes: [BrushStroke] = []
    public private(set) var revision = 0
    public private(set) var previewing = false
    @ObservationIgnored weak var store: EditorStore?
    @ObservationIgnored private var current: [Vec2] = []
    @ObservationIgnored private var currentCanvas: [Vec2] = []
    @ObservationIgnored private var preview: CGImage?
    @ObservationIgnored private var frame: CGImage?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    let mediaTime: Time

    init(clipID: ClipID, store: EditorStore) {
        self.clipID = clipID
        self.store = store
        let c = store.project.timeline.clip(clipID)
        mediaTime = c.map { $0.sourceTime(at: store.transport.playhead.clamped($0.start, $0.end - Time(ticks: 1))) } ?? .zero
        loadFrame()
    }

    public func clear() { strokes = []; preview = nil; revision += 1 }

    var selection: CutoutSelection { CutoutSelection(time: mediaTime, strokes: strokes) }

    // geometry of the clip's layer at the playhead
    private var layer: (geo: LayerGeometry, clip: Clip, asset: MediaAsset)? {
        guard let store, let clip = store.project.timeline.clip(clipID), let asset = clip.mediaID.flatMap(store.project.asset),
              let l = CanvasLayers.at(store.transport.playhead, project: store.project).first(where: { $0.clipID == clipID }) else { return nil }
        return (l.geometry, clip, asset)
    }

    /// Canvas pixel → normalised raw source coordinates (undoes transform, flip, crop and the media's rotation).
    func toSource(_ p: Vec2) -> Vec2? {
        guard let (g, clip, asset) = layer else { return nil }
        let c = cos(-g.rotation), s = sin(-g.rotation)
        let d = p - g.center
        let x = (d.x * c - d.y * s) / max(abs(g.halfSize.x), 1e-6), y = (d.x * s + d.y * c) / max(abs(g.halfSize.y), 1e-6)
        guard abs(x) <= 1.05, abs(y) <= 1.05 else { return nil }
        var u = (x + 1) / 2, v = (y + 1) / 2
        if clip.transform.flipH { u = 1 - u }
        if clip.transform.flipV { v = 1 - v }
        let cr = clip.crop
        u = cr.left + u * (1 - cr.left - cr.right); v = cr.top + v * (1 - cr.top - cr.bottom)
        switch (asset.sourceRotation % 360 + 360) % 360 {
        case 90: return Vec2(v, 1 - u)
        case 180: return Vec2(1 - u, 1 - v)
        case 270: return Vec2(1 - v, u)
        default: return Vec2(u, v)
        }
    }

    public func mouseDown(at p: Vec2) { current = []; currentCanvas = []; mouseDragged(at: p) }
    public func mouseDragged(at p: Vec2) {
        currentCanvas.append(p)
        if let s = toSource(p) { current.append(s) }
        revision += 1
    }
    public func mouseUp(at p: Vec2) {
        if !current.isEmpty { strokes.append(BrushStroke(points: current, radius: size / 400, erase: tool == .quickEraser)) }
        current = []; currentCanvas = []
        revision += 1
        updatePreview()
    }

    private func loadFrame() {
        guard let store, let clip = store.project.timeline.clip(clipID), let asset = clip.mediaID.flatMap(store.project.asset) else { return }
        let t = mediaTime, url = asset.url, isImage = asset.kind == .image
        Task { [weak self] in
            let img: CGImage? = await Task.detached {
                if isImage {
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceThumbnailMaxPixelSize: 960,
                                                                        kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
                }
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                g.appliesPreferredTrackTransform = false
                g.maximumSize = CGSize(width: 960, height: 960)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                return try? await g.image(at: t.cmTime).image
            }.value
            self?.frame = img
            self?.updatePreview()
        }
    }

    private func updatePreview() {
        guard let frame, !strokes.isEmpty else { preview = nil; revision += 1; return }
        previewTask?.cancel()
        previewing = true
        let sel = selection
        let box = UncheckedSendable(frame)
        previewTask = Task { [weak self] in
            let m = await Task.detached { try? MatteGenerator.still(box.value, mode: .custom(sel)) }.value
            guard !Task.isCancelled else { return }
            self?.preview = m
            self?.previewing = false
            self?.revision += 1
        }
    }

    public func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        guard let (g, clip, asset) = layer else { return }
        // tinted selection preview inside the layer quad (unrotated media only; rotated media show strokes only)
        if let preview, asset.sourceRotation % 360 == 0, clip.crop.isIdentity {
            ctx.saveGState()
            let center = toView(g.center)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: g.rotation)
            let w = g.halfSize.x * 2 * scale, h = g.halfSize.y * 2 * scale
            ctx.scaleBy(x: clip.transform.flipH ? -1 : 1, y: clip.transform.flipV ? 1 : -1)   // CG images draw bottom-up
            let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            ctx.clip(to: r, mask: preview)
            ctx.setFillColor(NSColor(srgbRed: 0.34, green: 0.75, blue: 0.80, alpha: 0.45).cgColor)
            ctx.fill(r)
            ctx.restoreGState()
        }
        // outline of the layer
        let pts = g.corners.map(toView)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor); ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [pts[0], pts[1], pts[1], pts[3], pts[3], pts[2], pts[2], pts[0]])
        // the stroke being painted
        if !currentCanvas.isEmpty {
            let radius = size / 400 * g.halfSize.x * 2 * scale
            ctx.setStrokeColor((tool == .quickEraser ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(radius * 2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addLines(between: currentCanvas.map(toView))
            if currentCanvas.count == 1 { ctx.addLine(to: toView(currentCanvas[0])) }
            ctx.strokePath()
        }
    }
}

extension EditorStore {
    public func beginCutoutBrush(_ clipID: ClipID) {
        let tool = CutoutBrushTool(clipID: clipID, store: self)
        ai.brush = tool
        playerUI.canvasTool = tool
        engine.pause()
    }

    public func endCutoutBrush() {
        ai.brush = nil
        playerUI.canvasTool = nil
    }

    public func applyCutoutBrush() {
        guard let b = ai.brush, !b.strokes.isEmpty else { return }
        let sel = b.selection
        endCutoutBrush()
        setCutout(b.clipID, mode: .custom(sel))
    }
}
