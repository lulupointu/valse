import Foundation
import Perception
import CryptoKit
import ValseCore
import ValseEngine

/// UI state of one model (Model manager rows, feature panels' "Download model" cards).
public enum AIModelState: Sendable, Equatable {
    case notInstalled
    /// Download in progress (0…1) — cancellable.
    case downloading(Double)
    /// Checking the SHA-256 of a downloaded / imported file.
    case verifying
    case installed(URL)
    case failed(String)

    public var isInstalled: Bool { if case .installed = self { return true }; return false }
    public var isBusy: Bool {
        switch self { case .downloading, .verifying: return true; default: return false }
    }
}

public enum ModelError: Error, Sendable, Equatable {
    case checksumMismatch, httpStatus(Int), cancelled, io(String), diskFull
    public var messageKey: String {
        switch self {
        case .checksumMismatch: return "model.error.checksum"
        case .httpStatus: return "model.error.network"
        case .cancelled: return "model.error.cancelled"
        case .io: return "model.error.io"
        case .diskFull: return "model.error.space"
        }
    }
}

/// Why a model download / import failed, in user terms (BUG-ERROR-COPY): each reason has its own message and, for a
/// full disk, its own action (Open Storage Settings) — a full disk used to be reported as "check your connection".
public enum ModelFailureReason: Sendable, Equatable {
    case network, diskFull, damaged, notInstalled, io

    public static func classify(_ error: Error) -> ModelFailureReason {
        switch error {
        case let e as ModelError:
            switch e {
            case .checksumMismatch: return .damaged
            case .httpStatus: return .network
            case .diskFull: return .diskFull
            case .io, .cancelled: return .io   // a full disk is thrown as `.diskFull` where the file is written
            }
        default:
            switch FileErrorKind.classify(error) {
            case .diskFull: return .diskFull
            case .noPermission, .readOnlyVolume: return .io
            case .notFound, .other: break
            }
            if (error as NSError).domain == NSURLErrorDomain {
                let code = URLError.Code(rawValue: (error as NSError).code)
                return [.cannotCreateFile, .cannotOpenFile, .cannotWriteToFile, .cannotMoveFile, .cannotRemoveFile].contains(code) ? .io : .network
            }
            return .io
        }
    }

    /// Localized message; `bytes` = the model's size (the space to free on a full disk).
    public func message(bytes: Int64) -> String {
        switch self {
        case .network: return tr("model.error.network")
        case .diskFull: return tr("model.error.space", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .damaged: return tr("model.error.checksum")
        case .notInstalled: return tr("model.error.notInstalled")
        case .io: return tr("model.error.io")
        }
    }
}

/// Downloads, verifies, imports and removes on-device models (main actor, observable). Files live in
/// `ModelCatalog.modelsDirectory`; the download is the only network access and is always started by the user.
@MainActor @Perceptible
public final class ModelManager {
    public static let shared = ModelManager()

    public private(set) var states: [String: AIModelState] = [:]
    /// Why the last download / import of a model failed (set with `.failed`): the UI adds the matching action
    /// (Open Storage Settings for `.diskFull`).
    public private(set) var failureReasons: [String: ModelFailureReason] = [:]
    @PerceptionIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @PerceptionIgnored private var downloads: [String: URLSessionDownloadTask] = [:]
    @PerceptionIgnored private var finishWaiters: [String: [@MainActor (AIModelState) -> Void]] = [:]

    /// Simulated downloads (UI tests: never the network). `.complete` reports progress then marks the model installed
    /// (in memory only: no file is written, so features still see it missing on disk); `.hold` stops at 40 % until
    /// cancelled (download-indicator / cancel checks).
    public enum Simulation: String, Sendable { case complete, hold }
    @PerceptionIgnored public var simulation: Simulation?
    @PerceptionIgnored private var simulatedInstalled: Set<String> = []

    public init() { refresh() }

    public func state(_ spec: AIModelSpec) -> AIModelState { states[spec.id] ?? .notInstalled }

    /// Re-scans the disk (cheap).
    public func refresh() {
        for s in ModelCatalog.all where !(states[s.id]?.isBusy ?? false) && !simulatedInstalled.contains(s.id) {
            states[s.id] = ModelCatalog.installedURL(s).map(AIModelState.installed) ?? .notInstalled
        }
    }

    /// Calls `body` once when the current (or next) download / import of `spec` ends: `.installed`, `.failed`, or
    /// `.notInstalled` (cancelled). Fires at once when nothing is in progress.
    public func whenFinished(_ spec: AIModelSpec, _ body: @escaping @MainActor (AIModelState) -> Void) {
        guard state(spec).isBusy else { body(state(spec)); return }
        finishWaiters[spec.id, default: []].append(body)
    }

    private func finish(_ id: String, _ s: AIModelState) {
        states[id] = s
        tasks[id] = nil
        downloads[id] = nil
        let w = finishWaiters.removeValue(forKey: id) ?? []
        for f in w { f(s) }
    }

    /// Ends a download task: maps the result to the model's state, then notifies `whenFinished` waiters.
    private func complete(_ id: String, _ error: Error?) {
        let spec = ModelCatalog.spec(id)
        guard let error else {
            if let u = spec.flatMap(ModelCatalog.installedURL) { failureReasons[id] = nil; finish(id, .installed(u)) }
            else { fail(id, .notInstalled) }
            return
        }
        switch error {
        case is CancellationError: finish(id, .notInstalled)
        case let e as ModelError where e == .cancelled: finish(id, .notInstalled)
        case let e as URLError where e.code == .cancelled: finish(id, .notInstalled)
        default:
            EngineLog.error("model \(id) failed: \(String(describing: error))")
            fail(id, ModelFailureReason.classify(error))
        }
    }

    private func fail(_ id: String, _ reason: ModelFailureReason) {
        failureReasons[id] = reason
        finish(id, .failed(reason.message(bytes: ModelCatalog.spec(id)?.bytes ?? 0)))
    }

    /// Starts downloading a model (no-op if installed or already downloading).
    public func download(_ spec: AIModelSpec) {
        guard !state(spec).isBusy, !state(spec).isInstalled else { return }
        states[spec.id] = .downloading(0)
        failureReasons[spec.id] = nil
        let id = spec.id
        if let simulation { simulate(spec, simulation); return }
        if spec.parts != nil { downloadParts(spec); return }
        tasks[id] = Task { [weak self] in
            do {
                // small companion files of multi-file models (.mlpackage directories) first
                for c in spec.companions {
                    let ctmp = try await ModelDownloader.download(c.url, progress: { _ in }, onTask: { _ in })
                    try await Self.verifyAndInstall(ctmp, sha256: c.sha256, relativePath: c.path, move: true)
                }
                let tmp = try await ModelDownloader.download(spec.url) { p in
                    Task { @MainActor in if case .downloading = self?.states[id] { self?.states[id] = .downloading(p) } }
                } onTask: { t in
                    Task { @MainActor in self?.downloads[id] = t }
                }
                self?.states[id] = .verifying
                try await Self.verifyAndInstall(tmp, spec: spec, move: true)
                self?.complete(id, nil)
            } catch {
                self?.complete(id, error)
            }
        }
    }

    /// UI-test download: progress ticks (a moving `ui.models.progress` keeps scripts' waits alive), no network, no file.
    private func simulate(_ spec: AIModelSpec, _ mode: Simulation) {
        let id = spec.id
        tasks[id] = Task { [weak self] in
            do {
                var p = 0.0
                while true {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    if mode == .hold && p >= 0.4 { continue }
                    p = min(1, p + 0.1)
                    self?.states[id] = .downloading(p)
                    if p >= 1 { break }
                }
                self?.simulatedInstalled.insert(id)
                self?.finish(id, .installed(ModelCatalog.modelsDirectory.appendingPathComponent(spec.fileName)))
            } catch {
                self?.complete(id, error)
            }
        }
    }

    /// Multi-file model: every part is downloaded and verified into a staging directory, then moved into place.
    private func downloadParts(_ spec: AIModelSpec) {
        let id = spec.id
        let parts = spec.parts ?? []
        let total = Double(max(spec.bytes, 1))
        tasks[id] = Task { [weak self] in
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("valse-model-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                var done = 0.0
                for part in parts {
                    try Task.checkCancellation()
                    let base = done
                    let tmp = try await ModelDownloader.download(part.url) { p in
                        let f = (base + p * Double(part.bytes)) / total
                        Task { @MainActor in if case .downloading = self?.states[id] { self?.states[id] = .downloading(f) } }
                    } onTask: { t in
                        Task { @MainActor in self?.downloads[id] = t }
                    }
                    let dst = stage.appendingPathComponent(part.path)
                    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: tmp, to: dst)
                    done += Double(part.bytes)
                }
                self?.states[id] = .verifying
                try await Self.verifyAndInstallDirectory(stage, spec: spec, move: true)
                self?.complete(id, nil)
            } catch {
                self?.complete(id, error)
            }
        }
    }

    /// Verifies every part of a multi-file model in `dir`, then moves / copies the directory into the models folder.
    nonisolated static func verifyAndInstallDirectory(_ dir: URL, spec: AIModelSpec, move: Bool) async throws {
        try await Task.detached(priority: .utility) {
            for p in spec.parts ?? [] {
                guard try sha256(of: dir.appendingPathComponent(p.path)) == p.sha256 else { throw ModelError.checksumMismatch }
            }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: ModelCatalog.modelsDirectory, withIntermediateDirectories: true)
                let dst = ModelCatalog.modelsDirectory.appendingPathComponent(spec.fileName, isDirectory: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                if move { try fm.moveItem(at: dir, to: dst) } else { try fm.copyItem(at: dir, to: dst) }
            } catch { throw FileErrorKind.classify(error) == .diskFull ? ModelError.diskFull : ModelError.io(String(describing: error)) }
        }.value
    }

    public func cancel(_ spec: AIModelSpec) {
        downloads[spec.id]?.cancel()
        tasks[spec.id]?.cancel()
    }

    /// Uses an existing model file the user already has (verified, then cloned into the models directory).
    public func importFile(_ url: URL, as spec: AIModelSpec) {
        guard !state(spec).isBusy else { return }
        states[spec.id] = .verifying
        let id = spec.id
        tasks[id] = Task { [weak self] in
            do {
                if spec.parts != nil { try await Self.verifyAndInstallDirectory(url, spec: spec, move: false) }
                else { try await Self.verifyAndInstall(url, spec: spec, move: false) }
                self?.complete(id, nil)
            } catch {
                self?.fail(id, ModelFailureReason.classify(error))
            }
        }
    }

    public func remove(_ spec: AIModelSpec) {
        simulatedInstalled.remove(spec.id)
        if let u = ModelCatalog.installedURL(spec) { try? FileManager.default.removeItem(at: u) }
        for c in spec.companions { try? FileManager.default.removeItem(at: ModelCatalog.modelsDirectory.appendingPathComponent(c.path)) }
        states[spec.id] = .notInstalled
    }

    /// SHA-256 check (streamed, off-main) then move/clone into place.
    nonisolated static func verifyAndInstall(_ file: URL, spec: AIModelSpec, move: Bool) async throws {
        try await verifyAndInstall(file, sha256: spec.sha256, relativePath: spec.fileName, move: move)
    }

    nonisolated static func verifyAndInstall(_ file: URL, sha256 expected: String, relativePath: String, move: Bool) async throws {
        try await Task.detached(priority: .utility) {
            let digest = try sha256(of: file)
            guard digest == expected else {
                if move { try? FileManager.default.removeItem(at: file) }
                throw ModelError.checksumMismatch
            }
            let fm = FileManager.default
            let dir = ModelCatalog.modelsDirectory
            do {
                let dst = dir.appendingPathComponent(relativePath)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                if move { try fm.moveItem(at: file, to: dst) } else { try fm.copyItem(at: file, to: dst) }   // APFS clone
            } catch { throw FileErrorKind.classify(error) == .diskFull ? ModelError.diskFull : ModelError.io(String(describing: error)) }
        }.value
    }

    public nonisolated static func sha256(of url: URL) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ModelError.io("open") }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = autoreleasepool { h.readData(ofLength: 8 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession download with progress + cancel (delegate based: async `download(from:)` has no progress).
enum ModelDownloader {
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void,
                         onTask: @escaping @Sendable (URLSessionDownloadTask) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                delegate.continuation = c
                let task = session.downloadTask(with: url)
                delegate.task = task
                onTask(task)
                task.resume()
            }
        } onCancel: { delegate.task?.cancel() }
    }

    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        private var lastReport = 0.0
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if p - lastReport > 0.005 || p >= 1 { lastReport = p; progress(p) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation?.resume(throwing: ModelError.httpStatus(http.statusCode)); continuation = nil; return
            }
            // the temp file is deleted when this returns: move it somewhere we own
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("valse-model-\(UUID().uuidString)")
            do { try FileManager.default.moveItem(at: location, to: dst); continuation?.resume(returning: dst) }
            catch { continuation?.resume(throwing: FileErrorKind.classify(error) == .diskFull ? ModelError.diskFull : ModelError.io(String(describing: error))) }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let ns = error as NSError
            // keep the URL error itself: `ModelFailureReason.classify` tells network failures from a full disk
            continuation?.resume(throwing: ns.code == NSURLErrorCancelled ? ModelError.cancelled : error)
            continuation = nil
        }
    }
}
