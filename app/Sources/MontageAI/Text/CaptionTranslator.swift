import Foundation
@preconcurrency import Translation
import MontageCore

/// On-device caption translation with Apple's Translation framework (AI-003 / TX-023). Language packs are managed by
/// the OS: installed pairs translate directly in the background (macOS 26 `TranslationSession(installedSource:)`);
/// otherwise the UI hosts a `.translationTask` that lets the system offer the download, then calls `translate(_:with:)`.
public enum CaptionTranslator {
    public enum Availability: Sendable, Equatable { case installed, needsDownload, unsupported }

    public static func status(from source: String, to target: String) async -> Availability {
        guard #available(macOS 15.0, *) else { return .unsupported }
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch s {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// Translates (id, text) pairs with an installed language pair.
    public static func translate<ID: Hashable & Sendable>(_ items: [(ID, String)], from source: String, to target: String) async throws -> [ID: String] {
        guard #available(macOS 26.0, *) else { throw AIToolError.unavailable("Translation needs macOS 26 for background use") }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        return try await translate(items, with: session)
    }

    /// Translates with a session handed out by SwiftUI's `.translationTask` (may trigger the system download sheet).
    @available(macOS 15.0, *)
    nonisolated(nonsending) public static func translate<ID: Hashable & Sendable>(_ items: [(ID, String)], with session: TranslationSession) async throws -> [ID: String] {
        var out: [ID: String] = [:]
        let requests = items.enumerated().map { i, it in TranslationSession.Request(sourceText: it.1.replacingOccurrences(of: "\n", with: " "), clientIdentifier: String(i)) }
        for r in try await session.translations(from: requests) {
            if let k = r.clientIdentifier.flatMap(Int.init), k < items.count { out[items[k].0] = r.targetText }
        }
        return out
    }
}
