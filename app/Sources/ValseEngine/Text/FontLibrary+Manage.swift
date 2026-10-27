import CoreText
import Foundation
import ValseCore

/// Font book (MI-021): imported font files per family, and removal (unregister + delete the copy).
extension FontLibrary {
    /// Imported files whose fonts belong to `family`.
    public static func files(ofFamily family: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) && FontCatalog.familyNames(in: $0).contains(family) }
    }

    /// Removes an imported family from Valse (the user's original file is untouched). Texts using it fall back to the
    /// system font until it is imported again. Returns the number of files removed.
    @discardableResult
    public static func remove(family: String) -> Int {
        var n = 0
        for u in files(ofFamily: family) {
            var err: Unmanaged<CFError>?
            _ = CTFontManagerUnregisterFontsForURL(u as CFURL, .process, &err)
            if (try? FileManager.default.removeItem(at: u)) != nil { n += 1 }
        }
        FontCatalog.invalidate()
        return n
    }
}
