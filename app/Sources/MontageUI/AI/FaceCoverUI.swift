import SwiftUI
import MontageCore
import MontageEngine
import MontageEffects
import MontageAI

// Video ▸ Basic ▸ ☐ Face cover (AI-051 / ST-006): detects and follows faces in the background, then covers them with
// Mosaic or Blur (a linked copy of the clip with a faces matte one track above) or with a sticker per face — white
// circle, white heart or any sticker — whose position / size keyframes follow that face. One undo step; unticking
// removes the cover.
enum FaceCoverInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.faceCover", tab: "video", subTab: "basic", order: 49, titleKey: "faceCover.title",
                         appliesTo: { ctx in (ctx.isMediaVideo || ctx.asset?.kind == .image) && ctx.clip?.matte?.kind != CutoutMode.faces.kind },
                         chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                guard let c = ctx.clip else { return false }
                return ctx.store.hasFaceCover(c.id) || ctx.store.ai.faceJobs[c.id] != nil
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.applyFaceCover(id, choice: FaceCoverUI.shared.choice) } else { ctx.store.removeFaceCover(id) }
            }))
        }) { AnyView(FaceCoverSection(ctx: $0)) },
    ]
}

/// What covers the faces: an effect on a matted copy (mosaic, blur) or one sticker per face.
enum FaceCoverChoice: String, CaseIterable, Sendable {
    case mosaic, blur, circle, heart, sticker
    var nameKey: String { "faceCover.\(rawValue)" }
    var effectStyle: FaceCover.Style? { self == .mosaic ? .mosaic : (self == .blur ? .blur : nil) }
    @MainActor func stickerID(_ ui: FaceCoverUI) -> String? {
        switch self {
        case .circle: return FaceStickers.circleID
        case .heart: return FaceStickers.heartID
        case .sticker: return ui.stickerID
        default: return nil
        }
    }
}

@MainActor @Observable final class FaceCoverUI {
    static let shared = FaceCoverUI()
    var choice: FaceCoverChoice = .mosaic
    /// Custom face sticker (ST-006 "custom sticker").
    var stickerID = "montage.sticker.smile"
    /// Sticker side / face height.
    var size: Double = 1.6
    var opacity: Double = 1
    /// Quick picks for the custom sticker row (emoji stickers + imported ones from Stickers ▸ Yours).
    static let quickStickers = ["smile", "cool", "starStruck", "heartEyes", "partyFace", "laugh", "wink", "alien"]
        .map { "montage.sticker.\($0)" }
}

struct FaceCoverSection: View {
    let ctx: InspectorContext
    @State private var sizeDraft: Double?
    @State private var opacityDraft: Double?

    var body: some View {
        let ui = FaceCoverUI.shared
        let current = ctx.clip.map { ctx.store.faceCoverChoice($0.id) } ?? nil
        let choice = current ?? ui.choice
        let active = current != nil
        VStack(alignment: .leading, spacing: 4) {
            if let id = ctx.clip?.id, let job = ctx.store.ai.faceJobs[id] {
                let p = ctx.store.jobProgress(job) ?? 0
                JobProgressLine(text: tr("faceCover.applying", JobInfo.percent(p)), progress: p) { ctx.store.removeFaceCover(id) }
            }
            InlineRow(label: tr("faceCover.style")) {
                Dropdown(items: FaceCoverChoice.allCases.map { ($0, tr($0.nameKey)) }, selection: choice) { s in
                    ui.choice = s
                    if let id = ctx.clip?.id, active { ctx.store.applyFaceCover(id, choice: s) }
                }
                .testID("faceCover.style")
            }
            if choice == .sticker {
                let picks = FaceCoverUI.quickStickers.filter { Registries.stickers[$0] != nil }
                    + StickerCatalog.available.filter { $0.groupKey == StickerCatalog.yoursNav }.map(\.id)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(picks, id: \.self) { sid in
                            stickerTile(sid, selected: ui.stickerID == sid) {
                                ui.stickerID = sid
                                if let id = ctx.clip?.id, active { ctx.store.applyFaceCover(id, choice: .sticker) }
                            }
                        }
                    }
                }
                .frame(height: 44)
            }
            if choice.stickerID(ui) != nil {
                SliderRowView(label: tr("faceCover.size"), unit: ((sizeDraft ?? ui.size) - 0.8) / 2.4, originUnit: 0, display: "\(Int(((sizeDraft ?? ui.size) / 1.6 * 100).rounded()))%",
                              parse: NumberParse.number, onBegin: {}, onChange: { sizeDraft = 0.8 + $0 * 2.4 },
                              onEnd: { commitSize(sizeDraft ?? ui.size) },
                              commit: { commitSize(min(max($0, 50), 200) / 100 * 1.6) },
                              step: { commitSize(min(max(ui.size + Double($0) * 0.016, 0.8), 3.2)) }, testID: "faceCover.size")
                SliderRowView(label: tr("faceCover.opacity"), unit: opacityDraft ?? ui.opacity, display: "\(Int(((opacityDraft ?? ui.opacity) * 100).rounded()))%",
                              parse: NumberParse.number, onBegin: {}, onChange: { opacityDraft = $0 },
                              onEnd: { commitOpacity(opacityDraft ?? ui.opacity) },
                              commit: { commitOpacity(min(max($0, 0), 100) / 100) },
                              step: { commitOpacity(min(max(ui.opacity + Double($0) * 0.01, 0), 1)) }, testID: "faceCover.opacity")
            }
            HintText(text: tr(choice.stickerID(ui) != nil ? "faceCover.stickerHint" : "faceCover.hint"))
        }
    }

    func stickerTile(_ sid: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let d = Registries.stickers[sid], case .emoji(let e) = d.source { Text(verbatim: e).font(.system(size: 24)) }
                else if let d = Registries.stickers[sid], let img = StickerThumbnails.image(d) { Image(decorative: img, scale: 2).resizable().scaledToFit().padding(4) }
                else { Image(systemName: "face.smiling") }
            }
            .frame(width: 40, height: 40)
            .background(IStyle.tile, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .testID("faceCover.sticker.\(sid)")
    }

    func commitSize(_ v: Double) {
        sizeDraft = nil
        FaceCoverUI.shared.size = v
        if let id = ctx.clip?.id, let c = ctx.store.faceCoverChoice(id), c.stickerID(FaceCoverUI.shared) != nil {
            ctx.store.applyFaceCover(id, choice: c)
        }
    }

    func commitOpacity(_ v: Double) {
        opacityDraft = nil
        FaceCoverUI.shared.opacity = v
        guard let id = ctx.clip?.id, !FaceStickers.covers(of: id, in: ctx.store.project.timeline).isEmpty else { return }
        ctx.store.perform(Edit("cmd.faceCover") { p in FaceStickers.setOpacity(v, of: id, in: &p) })
    }
}

extension EditorStore {
    func hasFaceCover(_ clipID: ClipID) -> Bool {
        FaceCover.cover(of: clipID, in: project.timeline) != nil || !FaceStickers.covers(of: clipID, in: project.timeline).isEmpty
    }

    /// The cover applied to `clipID` (nil = none).
    func faceCoverChoice(_ clipID: ClipID) -> FaceCoverChoice? {
        if let c = FaceCover.cover(of: clipID, in: project.timeline) { return FaceCover.style(of: c) == .blur ? .blur : .mosaic }
        guard let s = FaceStickers.covers(of: clipID, in: project.timeline).first, case .sticker(let sid) = s.content else { return nil }
        return sid == FaceStickers.circleID ? .circle : (sid == FaceStickers.heartID ? .heart : .sticker)
    }

    /// Back-compat entry point (Mosaic / Blur).
    public func applyFaceCover(_ clipID: ClipID, style: FaceCover.Style) {
        applyFaceCover(clipID, choice: style == .blur ? .blur : .mosaic)
    }

    func applyFaceCover(_ clipID: ClipID, choice: FaceCoverChoice) {
        guard let c = project.timeline.clip(clipID), let asset = c.mediaID.flatMap(project.asset) else { return }
        if let j = ai.faceJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        if let style = choice.effectStyle {
            Task {
                let id = await JobQueue.shared.enqueue(titleKey: "faceCover.job", priority: 0, subject: clipID.description) { progress in
                    try await MatteGenerator.generate(asset, mode: .faces) { progress.report($0) }
                }
                ai.faceJobs[clipID] = id
                let st = await JobQueue.shared.wait(id)
                if ai.faceJobs[clipID] == id { ai.faceJobs[clipID] = nil }
                switch st {
                case .done:
                    MatteStore.shared.didWriteMatte(media: asset, kind: CutoutMode.faces.kind)
                    if perform(Edit("cmd.faceCover") { p in
                        FaceStickers.remove(from: clipID, in: &p)
                        try FaceCover.apply(style, to: clipID, in: &p)
                    }) {
                        engine.forceRebuild()
                        showToast(tr("faceCover.done"))
                    }
                case .failed: showToast(tr("faceCover.failed"), error: true)
                default: break
                }
            }
            return
        }
        // sticker covers: face tracks (cached per media range), then one sticker clip per face
        let ui = FaceCoverUI.shared
        guard let sid = choice.stickerID(ui) else { return }
        let size = ui.size, opacity = ui.opacity
        let range = c.sourceRange
        let key = FaceTrackCache.key(asset, range)
        let finish: ([[TrackSample]]) -> Void = { [weak self] tracks in
            guard let self else { return }
            let ok = self.perform(Edit("cmd.faceCover") { p in
                FaceCover.remove(from: clipID, in: &p)
                try FaceStickers.apply(tracks, sticker: sid, size: size, opacity: opacity, to: clipID, in: &p)
            })
            if ok { self.showToast(tr("faceCover.done")) } else { self.showToast(tr("faceCover.noFaces"), error: true) }
        }
        if let cached = FaceTrackCache.shared[key] { finish(cached); return }
        Task {
            let box = TracksBox()
            let id = await JobQueue.shared.enqueue(titleKey: "faceCover.job", priority: 0, subject: clipID.description) { progress in
                box.tracks = try await FaceTracker.analyze(asset, range: range) { progress.report($0) }
            }
            ai.faceJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.faceJobs[clipID] == id { ai.faceJobs[clipID] = nil }
            switch st {
            case .done:
                FaceTrackCache.shared[key] = box.tracks
                finish(box.tracks)
            case .failed: showToast(tr("faceCover.failed"), error: true)
            default: break
            }
        }
    }

    public func removeFaceCover(_ clipID: ClipID) {
        if let j = ai.faceJobs[clipID] { ai.faceJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard hasFaceCover(clipID) else { return }
        perform(Edit("cmd.faceCover") { p in
            FaceCover.remove(from: clipID, in: &p)
            FaceStickers.remove(from: clipID, in: &p)
        })
    }
}

nonisolated private final class TracksBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [[TrackSample]] = []
    var tracks: [[TrackSample]] { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
