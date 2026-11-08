import CoreGraphics
import Foundation
import Perception
import ValseCore
import ValseEngine

/// Hover thumbnail of the full-screen seek bar (PB-006b, owner Q2 = B): the frame under the pointer rendered in the
/// background through the real compositor (`CompoundPreviewCache`, the compound-filmstrip renderer, keyed by the
/// timeline's content). Never blocks the main thread: the content key is hashed off the main actor, at most one render
/// is in flight and only the latest wanted time is rendered next (stale requests are dropped, not queued). Until the
/// wanted frame is ready the tooltip shows the time only.
@Perceptible
final class FullscreenThumbnailLoader {
    /// Tooltip box (points): 160 wide, at most 120 high (portrait canvases fit the height).
    static let maxSize = CGSize(width: 160, height: 120)

    private(set) var image: CGImage?
    /// Quantized time of `image` / of the wanted frame (`CompoundPreviewCache.quantize`).
    private(set) var imageQ: Int?
    private(set) var wantedQ: Int?

    /// "none" (not hovering) / "pending" / "ready" (UI scripts wait for "ready" before a snapshot).
    var state: String { wantedQ == nil ? "none" : (image != nil && imageQ == wantedQ ? "ready" : "pending") }
    var readyImage: CGImage? { image != nil && imageQ == wantedQ ? image : nil }

    @PerceptionIgnored private var keyCache: (revision: Int, duration: Time, key: String)?
    @PerceptionIgnored private var inflight = false
    @PerceptionIgnored private var pending: Request?
    @PerceptionIgnored private(set) var renders = 0

    struct Request { let project: Project; let revision: Int; let time: Time; let height: Int }

    /// Pixel height of the thumbnail (2× the point box) for a canvas.
    static func pixelHeight(canvas: Size2) -> Int {
        let aspect = canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9
        let h = min(maxSize.width / aspect, maxSize.height)
        return Int((h * 2 / 2).rounded()) * 2
    }

    /// Point size of the thumbnail for a canvas.
    static func pointSize(canvas: Size2) -> CGSize {
        let aspect = canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9
        let h = min(maxSize.width / aspect, maxSize.height)
        return CGSize(width: (h * aspect).rounded(), height: h.rounded())
    }

    /// The pointer hovers `t` of `project` (session `revision`).
    func request(project: Project, revision: Int, at t: Time) {
        let q = CompoundPreviewCache.quantize(t)
        guard project.duration > .zero else { clear(); return }
        if wantedQ == q, imageQ == q, image != nil { return }
        wantedQ = q
        let h = Self.pixelHeight(canvas: project.settings.canvasSize)
        if let k = key(revision, project.duration), let img = CompoundPreviewCache.shared.cachedThumbnail(key: k, at: t, height: h) {
            image = img; imageQ = q
            return
        }
        pending = Request(project: project, revision: revision, time: t, height: h)
        pump()
    }

    /// Not hovering any more.
    func clear() { wantedQ = nil; pending = nil }

    /// Full screen ended: forget the content key too.
    func reset() { clear(); image = nil; imageQ = nil; keyCache = nil }

    private func key(_ revision: Int, _ duration: Time) -> String? {
        guard let c = keyCache, c.revision == revision, c.duration == duration else { return nil }
        return c.key
    }

    private func pump() {
        guard !inflight, let r = pending else { return }
        pending = nil
        inflight = true
        let cached = key(r.revision, r.project.duration)
        Task { [weak self] in
            let project = r.project
            let k: String
            if let cached { k = cached } else {
                k = await Task.detached(priority: .userInitiated) { CompoundPreviewCache.key(timeline: project.timeline, in: project) }.value
            }
            let img = await CompoundPreviewCache.shared.thumbnail(project, key: k, at: r.time, height: r.height)
            guard let self else { return }
            self.keyCache = (r.revision, project.duration, k)
            self.renders += 1
            let q = CompoundPreviewCache.quantize(r.time)
            if let img, q == self.wantedQ { self.image = img; self.imageQ = q }
            self.inflight = false
            self.pump()
        }
    }
}
