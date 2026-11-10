import SwiftUI
import AppKit
import Perception
import ValseCore
import ValseEngine

/// Progress of "Pack project": a non-modal banner (Home and editor) with a determinate bar, the percentage and a
/// Cancel button, like Finder's copy progress and Final Cut's background tasks: packing copies every media file, so it
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

struct PackProgressBanner: View {
    let model: PackProgress
    var body: some View {
        WithPerceptionTracking {
            if let item = model.current {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.cancelling ? tr("pack.cancelling") : tr("pack.progress", item.name, Int((item.progress * 100).rounded(.down))))
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        ProgressView(value: item.progress).tint(Theme.Valse.ink).frame(width: 220).testID("pack.progress.bar")
                    }
                    Button(tr("common.cancel")) { model.cancel() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .bold)).underline()
                        .disabled(item.cancelling).testID("pack.cancel")
                }
                .foregroundStyle(Theme.Valse.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.Valse.mint, in: Capsule())
                .offset(x: -1, y: -1)
                .background(Capsule().fill(Theme.Valse.teal).offset(x: 2, y: 2))
                .testID("pack.progress")
            }
        }
    }
}
