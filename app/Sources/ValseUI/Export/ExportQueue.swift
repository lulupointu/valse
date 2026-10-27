import SwiftUI
import Perception
import AppKit
@preconcurrency import UserNotifications
import ValseCore
import ValseEngine

/// One queued export (one click on Export, or one clip of "Export selected clips").
@Perceptible
public final class ExportJobItem: Identifiable {
    public enum State: Equatable {
        case queued, running, done, failed(String), cancelled
    }
    public let id = UUID()
    public let title: String
    public let spec: ExportJobSpec
    public let outputs: [ExportJobSpec.Output]
    public internal(set) var state: State = .queued
    public internal(set) var progress: Double = 0
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var written: [URL] = []
    /// Technical detail of a failure (error domain / code): "Copy Details" in the job row and the log, never the message.
    public internal(set) var failureDetail: String?
    @PerceptionIgnored var task: Task<Void, Never>?

    init(spec: ExportJobSpec) {
        self.spec = spec
        self.title = spec.title
        self.outputs = spec.plannedOutputs()
    }

    public var isActive: Bool { state == .queued || state == .running }

    /// Remaining seconds (linear extrapolation once a little progress is known).
    public var eta: TimeInterval? {
        guard state == .running, let s = startedAt, progress > 0.02, progress < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(s)
        return elapsed / progress * (1 - progress)
    }

    public var primaryURL: URL? { (written.first ?? outputs.first?.url) }
}

/// Background export queue (EX-015): jobs run one at a time off the main actor on project snapshots, so editing
/// continues; progress / ETA / cancel per job; system notification (+ optional sound) when a job finishes.
@Perceptible
public final class ExportQueue {
    public private(set) var items: [ExportJobItem] = []
    /// Called on the main actor when a job ends (toast, etc.).
    @PerceptionIgnored public var onFinish: ((ExportJobItem) -> Void)?
    /// UserDefaults key of "Sound for export" (CapCut Settings ▸ Edit; the settings UI belongs to W12).
    public static let soundDefaultsKey = "valse.export.notificationSound"
    /// Settings ▸ General ▸ "Notify when an export finishes" (W12). Unset = on.
    public static let notifyDefaultsKey = "valse.export.notify"

    public init() {}

    public var active: [ExportJobItem] { items.filter(\.isActive) }
    public var running: ExportJobItem? { items.first { $0.state == .running } }
    /// Mean progress of the active jobs (title-bar ring).
    public var overallProgress: Double? {
        let a = active
        guard !a.isEmpty else { return nil }
        return a.map(\.progress).reduce(0, +) / Double(a.count)
    }

    @discardableResult
    public func enqueue(_ spec: ExportJobSpec) -> ExportJobItem {
        let item = ExportJobItem(spec: spec)
        items.append(item)
        pump()
        return item
    }

    public func cancel(_ item: ExportJobItem) {
        switch item.state {
        case .queued: item.state = .cancelled; item.finishedAt = Date()
        case .running: item.task?.cancel()
        default: break
        }
    }

    public func cancelAll() { items.forEach(cancel) }

    public func remove(_ item: ExportJobItem) {
        guard !item.isActive else { return }
        items.removeAll { $0.id == item.id }
    }

    public func clearFinished() { items.removeAll { !$0.isActive } }

    /// Waits until `item` leaves the queue/running states (tests).
    public func wait(_ item: ExportJobItem) async {
        while item.isActive { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func pump() {
        guard running == nil, let next = items.first(where: { $0.state == .queued }) else { return }
        next.state = .running
        next.startedAt = Date()
        let spec = next.spec, outputs = next.outputs
        next.task = Task { [weak self, weak next] in
            let progressBox = ProgressRelay { p in next?.progress = max(next?.progress ?? 0, p) }
            let result: Result<[URL], Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await ExportRunner.run(spec, outputs: outputs) { p in progressBox.send(p) }) }
                catch { return .failure(error) }
            }.value
            guard let next else { return }
            switch result {
            case .success(let urls): next.written = urls; next.progress = 1; next.state = .done
            case .failure(let e as ExportError) where e == .cancelled: next.state = .cancelled
            case .failure(let e) where Task.isCancelled && !(e is ExportError): next.state = .cancelled
            case .failure(let e):
                let f = Self.failure(e, title: next.title)
                next.failureDetail = f.detail
                if let d = f.detail { EngineLog.error("export \(next.title) failed: \(d)") }
                next.state = .failed(f.message)
            }
            next.finishedAt = Date()
            self?.finished(next)
            self?.pump()
        }
    }

    /// User message + technical detail of an export failure (BUG-ERROR-COPY): what happened and what to do; error
    /// domains / codes only in `detail` (Copy Details, log), never in the message.
    static func failure(_ error: Error, title: String) -> (message: String, detail: String?) {
        if let e = error as? ExportError {
            switch e {
            case .missingMedia(let names): return (tr(e.messageKey, names.joined(separator: ", ")), nil)
            case .encoderUnavailable(let format): return (tr(e.messageKey, format.uppercased()), nil)
            case .failed(let detail):
                // the writer's error text: a full disk still gets its own message (AVErrorDiskFull = -11807)
                if detail.contains("ENOSPC") || detail.contains("-11807") || detail.contains("NSFileWriteOutOfSpaceError") {
                    return (tr("export.error.space"), detail)
                }
                return (tr("export.error.failed", title), detail)
            default: return (tr(e.messageKey), nil)
            }
        }
        let detail = String(describing: error)
        switch FileErrorKind.classify(error) {
        case .diskFull: return (tr("export.error.space"), detail)
        case .noPermission, .readOnlyVolume: return (tr("export.error.noPermission"), detail)
        case .notFound, .other: return (tr("export.error.failed", title), detail)
        }
    }

    private func finished(_ item: ExportJobItem) {
        onFinish?(item)
        let sound = AppDefaults.store.bool(forKey: Self.soundDefaultsKey) && !TestAnchors.isEnabled
        if case .failed = item.state, sound { NotificationSounds.play(.failure) }   // AU-040
        guard item.state == .done else { return }
        if sound { NotificationSounds.play(.success) }
        if AppDefaults.store.object(forKey: Self.notifyDefaultsKey) == nil || AppDefaults.store.bool(forKey: Self.notifyDefaultsKey) {
            Self.postNotification(title: tr("export.notify.title"), body: tr("export.notify.body", item.primaryURL?.lastPathComponent ?? item.title))
        }
    }

    /// System notification (only from a bundled app: UNUserNotificationCenter needs a bundle identifier).
    static func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app",
              !ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent(); c.title = title; c.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}

/// Coalesces progress callbacks from the export threads onto the main actor (≤ ~30 updates/s).
nonisolated final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Double?
    private let apply: @MainActor (Double) -> Void
    init(_ apply: @escaping @MainActor (Double) -> Void) { self.apply = apply }
    func send(_ p: Double) {
        let schedule: Bool = lock.withLock { let s = pending == nil; pending = p; return s }
        guard schedule else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(33))
            let v: Double? = lock.withLock { let v = pending; pending = nil; return v }
            if let v { apply(v) }
        }
    }
}
