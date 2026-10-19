import Foundation
import MontageCore
import MontageEngine

/// Disk cache of transcripts, keyed by media content hash + source range + language + engine
/// (`~/Library/Caches/Montage/transcripts`). Re-generating captions or opening the transcript panel on the same media
/// is instant. Thread-safe.
public final class TranscriptStore: @unchecked Sendable {
    public static let shared = TranscriptStore()
    public let directory: URL
    private let lock = NSLock()
    private var memory: [String: Transcript] = [:]

    public init(directory: URL = MontagePaths.cacheDirectory.appendingPathComponent("transcripts", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func key(hash: String, range: TimeRange?, language: String?, engine: SpeechEngine, fillers: Bool) -> String {
        let r = range.map { "\(Int($0.start.seconds * 1000))-\(Int($0.end.seconds * 1000))" } ?? "all"
        // t4: DTW word times + speech-onset snapping (older cached transcripts have early/late words); t5: punctuated style prompt
        return "\(hash)-\(r)-\(language ?? "auto")-\(engine.rawValue)\(fillers ? "-f" : "")-t5"
    }

    public func get(_ key: String) -> Transcript? {
        if let t = lock.withLock({ memory[key] }) { return t }
        guard let d = try? Data(contentsOf: url(key)), let t = try? JSONDecoder().decode(Transcript.self, from: d) else { return nil }
        lock.withLock { memory[key] = t }
        return t
    }

    public func put(_ t: Transcript, _ key: String) {
        lock.withLock { memory[key] = t }
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: url(key), options: .atomic) }
    }

    /// Most recent transcript of a media item whatever its parameters (transcript panel).
    public func latest(hash: String) -> Transcript? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let mine = files.filter { $0.lastPathComponent.hasPrefix(hash + "-") && $0.lastPathComponent.contains("-all-") }
        let newest = mine.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        return newest.flatMap { get($0.deletingPathExtension().lastPathComponent) }
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension("json") }
}
