import AppKit
import ValseCore
import ValseEngine

/// Finisher F3 editor actions (media / canvas / text / audio rows).
extension EditorStore {
    // MARK: MI-014 audio streams

    public func setAudioStream(_ index: Int) {
        let ids = selectedClips.map(\.id)
        edit("cmd.audioStream") { p in try TimelineOps.setAudioStream(ids, index, in: &p) }
    }

    public func separateAudioStreams() {
        guard let c = singleSelectedClip else { return }
        edit("cmd.separateStreams") { p in try TimelineOps.separateAudioStreams(c.id, in: &p) }
    }

    // MARK: CV-009 distribute

    /// Selected visual clips visible at the playhead with their canvas bounds.
    func selectedLayerBounds() -> [(ClipID, (minX: Double, minY: Double, maxX: Double, maxY: Double))] {
        let sel = selection
        guard !sel.isEmpty else { return [] }
        // CanvasLayers measures text / stickers like the canvas selection boxes do
        return CanvasLayers.at(playhead, project: project).filter { sel.contains($0.clipID) && !$0.isLocked }.map { l in
            let xs = l.geometry.corners.map(\.x), ys = l.geometry.corners.map(\.y)
            return (l.clipID, (xs.min()!, ys.min()!, xs.max()!, ys.max()!))
        }
    }

    var canDistribute: Bool { selection.count >= 2 && selectedLayerBounds().count >= 2 }

    func distributeSelection(_ axis: CanvasDistribute) {
        let items = selectedLayerBounds()
        guard items.count >= 2 else { return }
        let canvas = project.settings.canvasSize, t = playhead
        let deltas = axis.deltas(items.map(\.1), canvas: canvas)
        let moves = Dictionary(uniqueKeysWithValues: zip(items.map(\.0), deltas))
        perform(Edit("cmd.distribute") { p in
            for (id, d) in moves {
                guard var c = p.timeline.clip(id) else { continue }
                let local = (t - c.start).clamped(.zero, c.duration)
                let pos = c.value(.position, at: local)?.vec2 ?? .zero
                c.setValue(.position, .vec2(CanvasDrag.moved(pos, by: d, canvas: canvas)), at: local)
                p.timeline[clip: id] = c
            }
        })
    }

    /// Several layers: align to the selection's common bounds (one layer: to the canvas).
    func alignSelection(_ a: CanvasAlign) {
        let items = selectedLayerBounds()
        guard !items.isEmpty else { return }
        let canvas = project.settings.canvasSize, t = playhead
        var frame = (minX: 0.0, minY: 0.0, maxX: canvas.width, maxY: canvas.height)
        if items.count >= 2 {
            frame = (items.map(\.1.minX).min()!, items.map(\.1.minY).min()!, items.map(\.1.maxX).max()!, items.map(\.1.maxY).max()!)
        }
        // CanvasAlign.delta aligns to (0…canvas); shift the bounds into the frame's space
        let size = Size2(frame.maxX - frame.minX, frame.maxY - frame.minY)
        var moves: [ClipID: Vec2] = [:]
        for (id, b) in items {
            moves[id] = a.delta(bounds: (b.minX - frame.minX, b.minY - frame.minY, b.maxX - frame.minX, b.maxY - frame.minY), canvas: size)
        }
        let fixed = moves
        perform(Edit("cmd.align") { p in
            for (id, d) in fixed {
                guard var c = p.timeline.clip(id) else { continue }
                let local = (t - c.start).clamped(.zero, c.duration)
                let pos = c.value(.position, at: local)?.vec2 ?? .zero
                c.setValue(.position, .vec2(CanvasDrag.moved(pos, by: d, canvas: canvas)), at: local)
                p.timeline[clip: id] = c
            }
        })
    }

    // MARK: MI-012 Live Photo switch on the clip

    /// The still a Live Photo motion clip came from (nil when the clip isn't one).
    func livePhotoStill(of c: Clip) -> MediaAsset? {
        guard let a = c.mediaID.flatMap(project.asset), a.kind == .video else { return nil }
        return project.media.first { $0.livePhotoVideoURL?.standardizedFileURL == a.url.standardizedFileURL }
    }

    /// Right-click ▸ "Apply as a LIVE photo" (still → its motion video) / "Apply as a photo" (motion → the still), keeping
    /// the clip's place, length (shortened if the video is shorter) and look. One undo step.
    public func toggleLivePhoto(_ id: ClipID) {
        guard let c = project.timeline.clip(id), let a = c.mediaID.flatMap(project.asset) else { return }
        if let still = livePhotoStill(of: c) {
            edit("cmd.livePhoto") { p in try TimelineOps.replaceMedia(id, with: still, in: &p) }
            return
        }
        guard let video = a.livePhotoVideoURL else { return }
        Task {
            guard var v = try? await MediaProbe.probe(video) else { showImportFailure([video]); return }
            if let e = project.media.first(where: { $0.contentHash == v.contentHash }) { v = e } else { v.folderID = a.folderID }
            let asset = v
            edit("cmd.livePhoto") { p in try TimelineOps.replaceMedia(id, with: asset, in: &p) }
        }
    }

    // MARK: MI-006 auto-relink at open

    /// Looks for missing media in the project's folder, previously used relink folders and near their old location;
    /// relinks what it finds (one undo step + toast). Returns the number relinked.
    @discardableResult
    public func autoRelinkMissing() async -> Int {
        let missing = missingMedia
        guard !missing.isEmpty else { return 0 }
        let pkg = packageURL, remembered = MediaAutoRelink.rememberedFolders
        let found = await Task.detached { MediaAutoRelink.search(missing: missing, packageURL: pkg, remembered: remembered) }.value
        guard !found.isEmpty else { return 0 }
        perform(Edit("cmd.autoRelink") { MediaRelinker.apply(found, to: &$0) })
        showToast(tr("toast.autoRelinked", found.count))
        return found.count
    }
}
