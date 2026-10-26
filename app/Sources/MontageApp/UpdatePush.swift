import Foundation

/// Release push for automatic updates (SE-015): one idle HTTP stream to an ntfy topic (Info.plist `MontageUpdatePushURL`,
/// `https://ntfy.sh/<topic>/json`) while Montage runs, instead of polling. scripts/release.sh publishes to the topic
/// once the GitHub release is up.
///
/// The stream is newline-delimited JSON: `{"event":"open"}` on connect, `keepalive` every ~45 s, `message` on a release.
/// A message only triggers an ordinary update check, which verifies the signed appcast and archive: a forged push
/// costs one check, nothing else. Failures (offline, ntfy down, sleep) are silent and retried with backoff
/// (5 s → 10 min); each reconnect after a drop checks once, to catch a release pushed while disconnected.
@MainActor
final class UpdatePushListener {
    private let url: URL
    private let onRelease: @MainActor () -> Void
    private let onReconnect: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120          // > 2 missed keepalives: the connection is dead, reconnect
        c.timeoutIntervalForResource = 60 * 60 * 24 * 365
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(url: URL, onRelease: @escaping @MainActor () -> Void, onReconnect: @escaping @MainActor () -> Void) {
        self.url = url
        self.onRelease = onRelease
        self.onReconnect = onReconnect
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// After wake: drop the stale connection now instead of waiting for its timeout.
    func restart() {
        stop()
        start()
    }

    private func run() async {
        var delay: Double = 5
        var connectedBefore = false
        while !Task.isCancelled {
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                for try await line in bytes.lines {
                    switch Self.event(line) {
                    case "open":
                        // the launch / wake check covers the first connection; later ones may have missed a push
                        if connectedBefore { onReconnect() }
                        connectedBefore = true
                        delay = 5
                    case "message":
                        onRelease()
                    default:
                        break
                    }
                }
            } catch {}
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 600)
        }
    }

    nonisolated static func event(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["event"] as? String
    }
}
