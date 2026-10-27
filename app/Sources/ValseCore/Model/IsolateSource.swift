import Foundation

/// "Isolate voice" source (AU-009): speech (Apple voice isolation, default) or a singing voice over music (HTDemucs).
public enum IsolateSource: String, Codable, Sendable, CaseIterable {
    case speech, music
    public var nameKey: String { "audio.isolate.\(rawValue)" }
}
