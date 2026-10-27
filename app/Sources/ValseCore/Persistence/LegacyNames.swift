import Foundation

/// Valse was called Montage until 0.3 (bundle id `fr.montage.Montage`). Every name Valse still has to recognise from
/// that time lives here, so the rest of the code only says Valse: settings, folders and keychain items are migrated at
/// the first launch (`RebrandMigration`), and projects, content IDs, file types and running copies of the old app keep
/// working through the readers below.
public enum LegacyNames {
    /// The old app: bundle id, executable / bundle name (`Montage.app`).
    public static let bundleID = "fr.montage.Montage"
    public static let appName = "Montage"
    /// Folder name under Application Support, Caches and Movies (`~/Movies/Montage`, the old default project library).
    public static let folderName = "Montage"
    /// Development caches of the old checkouts (`~/Library/Caches/MontageDev`: music library, test fixtures).
    public static let devCacheFolderName = "MontageDev"
    /// Project packages saved by Montage (`Name.montage`, UTI `fr.montage.project`): still opened, never renamed.
    public static let projectExtension = "montage"
    public static let projectUTI = "fr.montage.project"
    /// Custom effect packages (`<id>.montagefx` folders in Application Support/…/Effects).
    public static let effectPackageExtension = "montagefx"
    /// Keychain service of the online-audio provider keys.
    public static let keychainService = "fr.montage.online-audio"
    /// Unified-logging subsystem (support packages read both).
    public static let logSubsystem = "fr.montage"

    // MARK: Built-in content IDs ("montage.effect.blur" → "valse.effect.blur")

    static let contentPrefix = "montage."
    static let newContentPrefix = "valse."

    /// The Valse ID of a built-in content ID saved by Montage (effects, filters, transitions, animations, stickers,
    /// text styles, templates, speed / voice / EQ presets…); any other ID is returned unchanged.
    public static func contentID(_ id: String) -> String {
        guard id.hasPrefix(contentPrefix), isIdentifierLike(id) else { return id }
        return newContentPrefix + id.dropFirst(contentPrefix.count)
    }

    /// "montage.x.y" with no spaces / slashes: an ID, not user text that happens to start with the word.
    static func isIdentifierLike(_ s: String) -> Bool {
        s.count <= 200 && s.dropFirst(contentPrefix.count).allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
            && s.count > contentPrefix.count
    }

    /// Rewrites every legacy content ID (string values and dictionary keys) in a JSON document (project.json, compound
    /// presets, text presets…). Returns `data` itself when it holds none, so new files cost one byte scan.
    public static func migrateContentIDs(inJSON data: Data) -> Data {
        guard data.range(of: Data("\"\(contentPrefix)".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        let migrated = migrateContentIDs(in: obj)
        return (try? JSONSerialization.data(withJSONObject: migrated, options: [.fragmentsAllowed])) ?? data
    }

    /// Same on a decoded JSON / property-list value (strings, arrays, dictionaries; other values unchanged).
    public static func migrateContentIDs(in value: Any) -> Any {
        switch value {
        case let s as String: return contentID(s)
        case let a as [Any]: return a.map { migrateContentIDs(in: $0) }
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[contentID(k)] = migrateContentIDs(in: v) }
            return out
        default: return value
        }
    }

    // MARK: Settings keys ("MontageHomeSort" → "ValseHomeSort", "montage.media.sort" → "valse.media.sort")

    /// The Valse key of a setting saved by Montage, or nil when `key` is not one of Montage's own (system / Sparkle keys
    /// are copied as they are).
    public static func defaultsKey(_ key: String) -> String? {
        if key.hasPrefix(appName), key.count > appName.count, key[key.index(key.startIndex, offsetBy: appName.count)].isUppercase {
            return "Valse" + key.dropFirst(appName.count)
        }
        if key.hasPrefix(contentPrefix) { return newContentPrefix + key.dropFirst(contentPrefix.count) }
        return nil
    }

    /// Settings values that hold content IDs or drag / library item IDs ("montage-lib:…", favourites lists, JSON blobs).
    public static func defaultsValue(_ value: Any) -> Any {
        switch value {
        case let s as String:
            if s.hasPrefix("montage-") { return "valse-" + s.dropFirst("montage-".count) }
            return contentID(s)
        case let d as Data:
            return migrateContentIDs(inJSON: d)
        case let a as [Any]: return a.map(defaultsValue)
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[contentID(k)] = defaultsValue(v) }
            return out
        default: return value
        }
    }
}
