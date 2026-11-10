import SwiftUI
import AppKit
import Perception
import ValseCore
import ValseEngine

/// Progress of "Pack project": a non-modal card (Home and editor; the bottom-right download card) with a determinate bar, the percentage and a
/// cancel X: packing copies every media file, so it
/// can take minutes, and the user keeps working (or cancels) meanwhile. Runs through `JobQueue` (`job.pack`).
@MainActor @Perceptible
public final class PackProgress {
    public static let shared = PackProgress()

    public struct Item: Equatable {
        public var name: String
        public var progress: Double
        public var id: JobID?
        public var cancelling = false
    }
    public private(set) var current: Item?
    @PerceptionIgnored private var queue: JobQueue = .shared

    public init() {}

    /// Runs `work` as a `job.pack` job with the banner shown; returns the packed URL, or nil when cancelled / failed.
    /// `onDone` gets the outcome on the main actor (toast, Finder reveal).
    public enum Outcome: Equatable { case packed(URL), cancelled, failed }

    @discardableResult
    public func run(name: String, queue: JobQueue = .shared,
                    work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> URL) async -> Outcome {
        let box = PackBox()
        self.queue = queue
        current = Item(name: name, progress: 0, id: nil)
        let id = await queue.enqueue(titleKey: "job.pack", priority: 1) { handle in
            box.url = try work { p in
                handle.report(p)
                Task { @MainActor [self] in setProgress(p) }
            }
        }
        current?.id = id
        let state = await queue.wait(id)
        current = nil
        if state == .done, let u = box.url { return .packed(u) }
        return state == .cancelled ? .cancelled : .failed
    }

    func setProgress(_ p: Double) {
        guard var c = current else { return }
        c.progress = max(c.progress, p)
        current = c
    }

    /// Banner "Cancel": stops the job; the packer deletes what it wrote.
    public func cancel() {
        guard var c = current, !c.cancelling else { return }
        c.cancelling = true
        current = c
        if let id = c.id { let q = queue; Task { await q.cancel(id) } }
    }

    /// Toast + Finder reveal for an outcome (shared by the editor and Home entry points).
    public static func present(_ outcome: Outcome, store: EditorStore) {
        switch outcome {
        case .packed(let u):
            store.showToast(tr("toast.packed", u.lastPathComponent))
            NSWorkspace.shared.activateFileViewerSelecting([u])
        case .cancelled: store.showToast(tr("toast.packCancelled"))
        case .failed: store.showToast(tr("toast.packFailed"), error: true)
        }
    }
}

/// Home: the same bottom-right card the editor uses for model downloads (`ModelDownloadIndicator`), with only the pack row.
struct PackProgressCard: View {
    let model: PackProgress
    var body: some View {
        WithPerceptionTracking {
            if model.current != nil {
                ModelDownloadIndicator(flow: nil, pack: model)
                    .reportsSnapshotFrame { SnapshotRegistry.shared.floatingFrames["modelDownloads"] = $0 }
                    .padding(.trailing, 16).padding(.bottom, 16)
            }
        }
    }
}
