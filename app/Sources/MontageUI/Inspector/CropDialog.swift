import SwiftUI
import AppKit
import MontageCore
import MontageEngine

// Crop dialog (CV-006, CapCut toolbar ▸ Crop): the clip's uncropped frame with a crop box (8 handles + drag inside),
// ratio presets (Free, Original, 16:9 …), Rotate inside the crop (−45…45°, the window zooms in to stay inside the
// image), Reset / Cancel / Confirm. Confirm writes crop L/T/R/B (keyframe-aware at the playhead) + rotation in one undo step.

@MainActor @Observable
final class CropDialogModel {
    let clipID: ClipID
    let local: Time
    /// Source display aspect (width / height).
    let aspect: Double
    var crop: CropRect
    var ratio: String
    var preview: CGImage?

    init(clip: Clip, local: Time, aspect: Double, ratio: String?) {
        clipID = clip.id; self.local = local; self.aspect = aspect
        let r = clip.resolved(at: local)
        crop = r.crop
        self.ratio = ratio ?? "free"
    }

    /// Pixel ratio of the window for `ratio` (nil = free).
    func targetRatio(_ id: String) -> Double? {
        guard let r = CropSection.ratios.first(where: { $0.id == id }), r.w != 0 else { return nil }
        return r.w < 0 ? aspect : r.w / r.h
    }

    /// Centred, largest window of the chosen ratio (keeps the rotation).
    func applyRatio(_ id: String) {
        ratio = id
        guard let r = targetRatio(id) else { return }
        var c = CropRect(rotation: crop.rotation)
        if aspect > r { let keep = r / aspect; c.left = (1 - keep) / 2; c.right = c.left }
        else { let keep = aspect / r; c.top = (1 - keep) / 2; c.bottom = c.top }
        crop = c
    }

    func reset() { crop = CropRect(); ratio = "free" }

    static let minSize = 0.05

    enum Handle: Int, CaseIterable { case tl, t, tr, r, br, b, bl, l, body }

    /// Crop after dragging `h` by (dx, dy) normalized source units, from `start`.
    func dragged(_ h: Handle, from start: CropRect, dx: Double, dy: Double) -> CropRect {
        var c = start
        let m = Self.minSize
        func clampL(_ v: Double) -> Double { min(max(v, 0), 1 - c.right - m) }
        func clampR(_ v: Double) -> Double { min(max(v, 0), 1 - c.left - m) }
        func clampT(_ v: Double) -> Double { min(max(v, 0), 1 - c.bottom - m) }
        func clampB(_ v: Double) -> Double { min(max(v, 0), 1 - c.top - m) }
        if h == .body {
            let w = 1 - start.left - start.right, ht = 1 - start.top - start.bottom
            let nl = min(max(start.left + dx, 0), 1 - w), nt = min(max(start.top + dy, 0), 1 - ht)
            c.left = nl; c.right = 1 - w - nl; c.top = nt; c.bottom = 1 - ht - nt
            return c
        }
        if [.tl, .l, .bl].contains(h) { c.left = clampL(start.left + dx) }
        if [.tr, .r, .br].contains(h) { c.right = clampR(start.right - dx) }
        if [.tl, .t, .tr].contains(h) { c.top = clampT(start.top + dy) }
        if [.bl, .b, .br].contains(h) { c.bottom = clampB(start.bottom - dy) }
        // ratio lock (corners only): height follows the width, anchored at the opposite corner
        if let r = targetRatio(ratio), [.tl, .tr, .bl, .br].contains(h) {
            var w = 1 - c.left - c.right
            var ht = w * aspect / r
            let anchoredTop = h == .bl || h == .br   // dragging a bottom corner keeps the top
            let room = anchoredTop ? 1 - c.top : 1 - c.bottom
            if ht > room { ht = room; w = ht * r / aspect }
            if h == .tl || h == .bl { c.left = 1 - c.right - w } else { c.right = 1 - c.left - w }
            if anchoredTop { c.bottom = 1 - c.top - ht } else { c.top = 1 - c.bottom - ht }
        }
        return c
    }

    var dump: [String: Any] {
        ["open": true, "left": crop.left, "top": crop.top, "right": crop.right, "bottom": crop.bottom,
         "rotation": crop.rotation ?? 0, "ratio": ratio, "zoom": CropGeometry.fitZoom(crop, aspect: aspect), "preview": preview != nil]
    }

    /// Uncropped frame of the clip at the playhead (same look otherwise: effects / filters stay).
    func loadPreview(project: Project) {
        guard let clip = project.timeline.clip(clipID), let mid = clip.mediaID, let asset = project.asset(mid) else { return }
        var p = Project(name: "crop", settings: ProjectSettings(canvasSize: asset.pixelSize, frameRate: project.settings.frameRate,
                                                                backgroundColor: .black))
        p.media = [asset]
        var c = clip
        c.start = .zero; c.crop = CropRect(); c.transform = Transform(); c.mask = nil; c.keyframes = [:]
        c.animations = ClipAnimations(); c.transitionOut = nil; c.opacity = 1; c.blendMode = .normal
        guard (try? TimelineOps.insert(c, into: &p)) != nil else { return }
        let t = local, snapshot = p
        Task { [weak self] in
            let img = try? await Task.detached(priority: .userInitiated) { try await StillFrameExporter.image(project: snapshot, at: t, shortSide: 540) }.value
            self?.preview = img
        }
    }
}

@MainActor @Observable
public final class CropDialogState {
    public static let shared = CropDialogState()
    var model: CropDialogModel?
    var dump: [String: Any] { model?.dump ?? ["open": false] }
}

extension EditorStore {
    /// Toolbar / right-click ▸ Crop: opens the crop dialog on the selected video or image clip.
    public func openCropDialog() {
        guard let c = singleSelectedClip, let mid = c.mediaID, let a = project.asset(mid), a.hasVideo || a.kind == .image else { return }
        let local = min(max(playhead - c.start, .zero), c.duration)
        let aspect = a.pixelSize.height > 0 ? a.pixelSize.width / a.pixelSize.height : 16.0 / 9
        let m = CropDialogModel(clip: c, local: local, aspect: aspect, ratio: InspectorUIState.shared.cropRatio[c.id])
        m.loadPreview(project: project)
        CropDialogState.shared.model = m
    }

    func closeCropDialog() { CropDialogState.shared.model = nil }

    func confirmCropDialog() {
        guard let m = CropDialogState.shared.model else { return }
        let crop = m.crop, local = m.local
        InspectorUIState.shared.cropRatio[m.clipID] = m.ratio
        perform(UpdateClip(m.clipID, nameKey: "cmd.crop") { c in
            c.setValue(.cropLeft, .scalar(crop.left), at: local)
            c.setValue(.cropRight, .scalar(crop.right), at: local)
            c.setValue(.cropTop, .scalar(crop.top), at: local)
            c.setValue(.cropBottom, .scalar(crop.bottom), at: local)
            c.crop.rotation = (crop.rotation ?? 0) == 0 ? nil : crop.rotation
        })
        closeCropDialog()
    }
}

struct CropDialogModal: View {
    let store: EditorStore
    @Bindable var model: CropDialogModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture {}
            CropDialogView(store: store, model: model)
                .frame(width: 780, height: 600)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { SnapshotRegistry.shared.modalFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in SnapshotRegistry.shared.modalFrame = f }
                })
                .shadow(color: .black.opacity(0.5), radius: 20)
                .testID("crop.dialog")
        }
        .onDisappear { SnapshotRegistry.shared.modalFrame = nil }
        .onExitCommand { store.closeCropDialog() }
    }
}

struct CropDialogView: View {
    let store: EditorStore
    @Bindable var model: CropDialogModel
    @State private var dragStart: CropRect?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc: "crop.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button { store.closeCropDialog() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).testID("crop.close")
            }
            .padding(.horizontal, 16).frame(height: 40)
            Rectangle().fill(Theme.separator).frame(height: 1)
            GeometryReader { g in stage(in: g.size) }
                .padding(20)
                .background(Color.black.opacity(0.35))
                .testID("crop.stage")
            Rectangle().fill(Theme.separator).frame(height: 1)
            controls.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Stage

    private func imageRect(in size: CGSize) -> CGRect {
        let a = CGFloat(model.aspect)
        var w = size.width, h = w / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder private func stage(in size: CGSize) -> some View {
        let img = imageRect(in: size)
        let c = model.crop
        let box = CGRect(x: img.minX + c.left * img.width, y: img.minY + c.top * img.height,
                         width: (1 - c.left - c.right) * img.width, height: (1 - c.top - c.bottom) * img.height)
        let zoom = CropGeometry.fitZoom(c, aspect: model.aspect)
        let anchor = UnitPoint(x: (box.midX - img.minX) / max(img.width, 1), y: (box.midY - img.minY) / max(img.height, 1))
        ZStack(alignment: .topLeading) {
            // the image turns under the fixed crop window (and zooms just enough to fill it)
            Group {
                if let p = model.preview {
                    Image(decorative: p, scale: 1).resizable().interpolation(.medium)
                } else {
                    Rectangle().fill(Color(white: 0.15))
                }
            }
            .frame(width: img.width, height: img.height)
            .scaleEffect(1 / zoom, anchor: anchor)
            .rotationEffect(.degrees(c.rotation ?? 0), anchor: anchor)
            .offset(x: img.minX, y: img.minY)
            // dim outside the window
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(box) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            // thirds grid + border
            Path { p in
                for k in 1...2 {
                    let x = box.minX + box.width * CGFloat(k) / 3, y = box.minY + box.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
            Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY).allowsHitTesting(false)
            // body drag
            // .position (not .offset) so hit testing and test-ID frames follow the box
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: max(box.width - 24, 1), height: max(box.height - 24, 1))
                .contentShape(Rectangle())
                .gesture(drag(.body, img: img))
                .testID("crop.box")
                .position(x: box.midX, y: box.midY)
            ForEach(CropDialogModel.Handle.allCases.filter { $0 != .body && (model.targetRatio(model.ratio) == nil || [.tl, .tr, .bl, .br].contains($0)) }, id: \.self) { h in
                handle(h, box: box, img: img)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func handle(_ h: CropDialogModel.Handle, box: CGRect, img: CGRect) -> some View {
        let pt: CGPoint
        switch h {
        case .tl: pt = CGPoint(x: box.minX, y: box.minY)
        case .t: pt = CGPoint(x: box.midX, y: box.minY)
        case .tr: pt = CGPoint(x: box.maxX, y: box.minY)
        case .r: pt = CGPoint(x: box.maxX, y: box.midY)
        case .br: pt = CGPoint(x: box.maxX, y: box.maxY)
        case .b: pt = CGPoint(x: box.midX, y: box.maxY)
        case .bl: pt = CGPoint(x: box.minX, y: box.maxY)
        case .l: pt = CGPoint(x: box.minX, y: box.midY)
        case .body: pt = CGPoint(x: box.midX, y: box.midY)
        }
        let corner = [.tl, .tr, .bl, .br].contains(h)
        let horizontalBar = h == .t || h == .b
        return ZStack {
            Color.white.opacity(0.001).frame(width: 24, height: 24)
            RoundedRectangle(cornerRadius: 2).fill(Color.white)
                .frame(width: corner ? 12 : (horizontalBar ? 18 : 5), height: corner ? 12 : (horizontalBar ? 5 : 18))
        }
        .contentShape(Rectangle())
        .gesture(drag(h, img: img))
        .testID("crop.handle.\(h)")
        .position(x: pt.x, y: pt.y)
    }

    private func drag(_ h: CropDialogModel.Handle, img: CGRect) -> some Gesture {
        // U1: window space — the handle moves with the crop, so its local space would shrink every next translation
        // by the last move (handle lagging half the mouse and jittering, like the panel splitters did).
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                let start = dragStart ?? model.crop
                if dragStart == nil { dragStart = start }
                model.crop = model.dragged(h, from: start, dx: v.translation.width / max(img.width, 1), dy: v.translation.height / max(img.height, 1))
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(CropSection.ratios, id: \.id) { r in
                    let title = r.id == "free" ? tr("inspector.crop.free") : (r.id == "original" ? tr("player.ratio.original") : r.id)
                    Button { model.applyRatio(r.id) } label: {
                        Text(verbatim: title).font(.system(size: 12, weight: model.ratio == r.id ? .semibold : .regular))
                            .foregroundStyle(model.ratio == r.id ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(model.ratio == r.id ? Theme.segmentSelected : Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.ratio == r.id ? Theme.accent : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain).testID("crop.ratio.\(r.id)")
                }
            }
            HStack(spacing: 10) {
                Text(loc: "crop.rotate").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { model.crop.rotation ?? 0 }, set: { model.crop.rotation = ($0 * 10).rounded() / 10 }), in: -45...45)
                    .frame(width: 300).testID("crop.rotate")
                Text(verbatim: String(format: "%.1f°", model.crop.rotation ?? 0)).font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary).frame(width: 52, alignment: .trailing)
                Button { model.crop.rotation = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("inspector.reset")).testID("crop.rotate.reset")
                Spacer()
            }
            HStack {
                Button(tr("crop.reset")) { model.reset() }.buttonStyle(SecondaryButtonStyle()).testID("crop.reset")
                Spacer()
                Button(tr("common.cancel")) { store.closeCropDialog() }.buttonStyle(SecondaryButtonStyle()).testID("crop.cancel")
                Button(tr("crop.confirm")) { store.confirmCropDialog() }.buttonStyle(AccentButtonStyle()).testID("crop.confirm")
            }
        }
    }
}
