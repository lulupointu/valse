import Foundation
import Observation
import CryptoKit
import MontageCore
import MontageEngine

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
    case checksumMismatch, httpStatus(Int), cancelled, io(String)
    public var messageKey: String {
        switch self {
        case .checksumMismatch: return "model.error.checksum"
        case .httpStatus: return "model.error.network"
        case .cancelled: return "model.error.cancelled"
        case .io: return "model.error.io"
        }
    }
}

/// Downloads, verifies, imports and removes on-device models (main actor, observable). Files live in
/// `ModelCatalog.modelsDirectory`; the download is the only network access and is always started by the user.
@MainActor @Observable
public final class ModelManager {
    public static let shared = ModelManager()

    public private(set) var states: [String: AIModelState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloads: [String: URLSessionDownloadTask] = [:]

    init() { refresh() }

    public func state(_ spec: AIModelSpec) -> AIModelState { states[spec.id] ?? .notInstalled }

    /// Re-scans the disk (cheap).
    public func refresh() {
        for s in ModelCatalog.all where !(states[s.id]?.isBusy ?? false) {
            states[s.id] = ModelCatalog.installedURL(s).map(AIModelState.installed) ?? .notInstalled
        }
    }

    /// Starts downloading a model (no-op if installed or already downloading).
    public func download(_ spec: AIModelSpec) {
        guard !state(spec).isBusy, !state(spec).isInstalled else { return }
        states[spec.id] = .downloading(0)
        let id = spec.id
        tasks[id] = Task { [weak self] in
            do {
                let tmp = try await ModelDownloader.download(spec.url) { p in
                    Task { @MainActor in if case .downloading = self?.states[id] { self?.states[id] = .downloading(p) } }
                } onTask: { t in
                    Task { @MainActor in self?.downloads[id] = t }
                }
                self?.states[id] = .verifying
                try await Self.verifyAndInstall(tmp, spec: spec, move: true)
                self?.states[id] = ModelCatalog.installedURL(spec).map(AIModelState.installed) ?? .failed("missing")
            } catch is CancellationError {
                self?.states[id] = .notInstalled
            } catch let e as ModelError where e == .cancelled {
                self?.states[id] = .notInstalled
            } catch let e as ModelError {
                self?.states[id] = .failed(tr(e.messageKey))
            } catch {
                self?.states[id] = .failed(tr("model.error.network"))
            }
            self?.tasks[id] = nil
            self?.downloads[id] = nil
        }
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
                try await Self.verifyAndInstall(url, spec: spec, move: false)
                self?.states[id] = ModelCatalog.installedURL(spec).map(AIModelState.installed) ?? .failed("missing")
            } catch let e as ModelError {
                self?.states[id] = .failed(tr(e.messageKey))
            } catch {
                self?.states[id] = .failed(tr("model.error.io"))
            }
            self?.tasks[id] = nil
        }
    }

    public func remove(_ spec: AIModelSpec) {
        if let u = ModelCatalog.installedURL(spec) { try? FileManager.default.removeItem(at: u) }
        states[spec.id] = .notInstalled
    }

    /// SHA-256 check (streamed, off-main) then move/clone into place.
    nonisolated static func verifyAndInstall(_ file: URL, spec: AIModelSpec, move: Bool) async throws {
        try await Task.detached(priority: .utility) {
            let digest = try sha256(of: file)
            guard digest == spec.sha256 else {
                if move { try? FileManager.default.removeItem(at: file) }
                throw ModelError.checksumMismatch
            }
            let fm = FileManager.default
            let dir = ModelCatalog.modelsDirectory
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = dir.appendingPathComponent(spec.fileName)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                if move { try fm.moveItem(at: file, to: dst) } else { try fm.copyItem(at: file, to: dst) }   // APFS clone
            } catch { throw ModelError.io(String(describing: error)) }
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
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("montage-model-\(UUID().uuidString)")
            do { try FileManager.default.moveItem(at: location, to: dst); continuation?.resume(returning: dst) }
            catch { continuation?.resume(throwing: ModelError.io(String(describing: error))) }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let ns = error as NSError
            continuation?.resume(throwing: ns.code == NSURLErrorCancelled ? ModelError.cancelled : ModelError.io(ns.localizedDescription))
            continuation = nil
        }
    }
}
