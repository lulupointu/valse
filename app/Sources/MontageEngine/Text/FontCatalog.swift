import CoreText
import Foundation
import MontageCore

/// What the font picker lists (TX-002): imported families first (files of `FontLibrary`, MI-021), then the installed
/// system families. Import / registration itself is `FontLibrary` (media pipeline).
public enum FontCatalog {
    public struct Family: Hashable, Sendable, Identifiable {
        public let name: String
        public let isImported: Bool
        public var id: String { name }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSystem: [String]?
    nonisolated(unsafe) private static var cachedImported: [String]?

    /// Registers the imported fonts once per process (renderer start-up; the editor also loads them at launch).
    public static let ensureLoaded: Bool = { FontLibrary.loadAll(); return true }()

    static func familyNames(in url: URL) -> [String] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

    /// Families of the fonts in the import folder.
    public static var importedFamilies: [String] {
        if let c = lock.withLock({ cachedImported }) { return c }
        let files = (try? FileManager.default.contentsOfDirectory(at: FontLibrary.directory, includingPropertiesForKeys: nil)) ?? []
        let names = Array(Set(files.filter { FontLibrary.extensions.contains($0.pathExtension.lowercased()) }.flatMap(familyNames))).sorted()
        lock.withLock { cachedImported = names }
        return names
    }

    /// Imports font files (copy + register) and returns their family names.
    @discardableResult
    public static func importFonts(_ urls: [URL]) throws -> [String] {
        try FontLibrary.importFonts(urls)
        lock.withLock { cachedImported = nil; cachedSystem = nil }
        return Array(Set(urls.flatMap(familyNames))).sorted()
    }

    /// Drops the cached family lists (after imported fonts were removed, MI-021).
    public static func invalidate() { lock.withLock { cachedImported = nil; cachedSystem = nil } }

    /// Installed font families (no hidden "." system families), sorted.
    public static var systemFamilies: [String] {
        if let c = lock.withLock({ cachedSystem }) { return c }
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            .filter { !$0.hasPrefix(".") && !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lock.withLock { cachedSystem = names }
        return names
    }

    /// Everything the font picker lists: imported first, then system families.
    public static var families: [Family] {
        _ = ensureLoaded
        let imp = importedFamilies
        return imp.map { Family(name: $0, isImported: true) } + systemFamilies.filter { !imp.contains($0) }.map { Family(name: $0, isImported: false) }
    }

    /// Display name of a `TextContent.fontName` ("" = the system font → nil).
    public static func displayName(_ fontName: String) -> String? {
        guard !fontName.isEmpty else { return nil }
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        let fam = CTFontCopyFamilyName(f) as String
        return fam.caseInsensitiveCompare(fontName) == .orderedSame || fontName.contains(fam) ? fam : fontName
    }
}
