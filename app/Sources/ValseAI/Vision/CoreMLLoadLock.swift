import Foundation

/// Cross-process exclusive lock (`flock` on a file next to the compiled models) around Core ML model loads and their
/// first prediction (FLAKY-LAMA, see `LaMaInpainter.init(compiled:)`): Core ML's on-disk GPU-program cache is shared by
/// every Valse process and written in place during a load, so a load must never overlap another process's.
/// `flock` also excludes other threads of this process (each call opens its own descriptor). Released on return, and by
/// the kernel when a holder dies.
public enum CoreMLLoadLock {
    /// The lock file for a compiled model: one per (resolved) models folder, so every process agrees on it.
    public static func url(for compiledModel: URL) -> URL {
        compiledModel.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(".coreml-load.lock")
    }

    /// Runs `body` holding the lock. Waits for other holders (polling, so `cancelled` is honoured); after `timeout`
    /// (a holder that hangs) it runs anyway rather than never.
    public static func withLock<T>(_ lockFile: URL, timeout: TimeInterval = 600, cancelled: () -> Bool = { false },
                                   _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return try body() }   // unwritable folder: nothing to share it with
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return try body() }
            if cancelled() { throw CancellationError() }
            if Date() > deadline { return try body() }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
