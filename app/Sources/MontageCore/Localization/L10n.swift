import Foundation

/// Localization for every user-visible string (en + fr), with an in-app language override that switches at runtime.
///
/// Mechanism (works with plain `swift build`, verified by scripts/test.sh):
/// - Each module ships `Resources/<lang>.lproj/*.strings` (any table name; one table per feature avoids merge
///   conflicts). SwiftPM copies them into the module resource bundle `Montage_<Module>.bundle`.
/// - Modules register their bundle once at startup (`L10n.shared.register(bundle)`; Core registers itself).
/// - All tables of the active language are merged into one dictionary, so lookups are a hash lookup and switching
///   language is just reloading the dictionary (UI observes `L10n.didChange`).
/// - Fallback: active language → English → the key itself (missing keys are caught by the completeness check).
/// - Plurals: `.stringsdict` tables are resolved through Foundation (`plural(_:count:)`).
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()
    public static let supportedLanguages = ["en", "fr"]
    /// UserDefaults key holding "system", "en" or "fr".
    public static let overrideDefaultsKey = "MontageLanguage"
    public static let didChange = Notification.Name("MontageLanguageDidChange")

    private let lock = NSLock()
    private var bundles: [Bundle] = []
    private var table: [String: String] = [:]
    private var fallback: [String: String] = [:]
    private var _language: String = "en"

    private init() {
        bundles = [CoreResources.bundle]
        _language = L10n.resolveLanguage(UserDefaults.standard.string(forKey: L10n.overrideDefaultsKey))
        reload()
    }

    /// Active language code ("en" / "fr").
    public var language: String { lock.withLock { _language } }

    public var locale: Locale { Locale(identifier: language) }

    /// Registers a module resource bundle (idempotent).
    public func register(_ bundle: Bundle) {
        lock.withLock {
            guard !bundles.contains(where: { $0.bundleURL == bundle.bundleURL }) else { return }
            bundles.append(bundle)
        }
        reload()
    }

    /// Sets the in-app language ("system", "en", "fr"); persists it and notifies observers.
    public func setLanguagePreference(_ pref: String) {
        UserDefaults.standard.set(pref, forKey: L10n.overrideDefaultsKey)
        let lang = L10n.resolveLanguage(pref)
        lock.withLock { _language = lang }
        reload()
        NotificationCenter.default.post(name: L10n.didChange, object: nil)
    }

    /// Forces a language for this process only (e.g. `--lang fr`), without persisting.
    public func setLanguageForSession(_ lang: String) {
        lock.withLock { _language = L10n.resolveLanguage(lang) }
        reload()
        NotificationCenter.default.post(name: L10n.didChange, object: nil)
    }

    public var languagePreference: String { UserDefaults.standard.string(forKey: L10n.overrideDefaultsKey) ?? "system" }

    public static func resolveLanguage(_ pref: String?) -> String {
        if let pref, supportedLanguages.contains(pref) { return pref }
        for l in Locale.preferredLanguages {
            let code = String(l.prefix(2))
            if supportedLanguages.contains(code) { return code }
        }
        return "en"
    }

    /// Localized string for `key`; `args` are applied with `String(format:)` semantics.
    public func string(_ key: String, _ args: [any CVarArg] = []) -> String {
        let fmt: String = lock.withLock { table[key] ?? fallback[key] ?? key }
        return args.isEmpty ? fmt : String(format: fmt, locale: locale, arguments: args)
    }

    public func has(_ key: String) -> Bool { lock.withLock { table[key] != nil } }

    /// Plural-aware lookup via `.stringsdict` (e.g. "%d clips").
    public func plural(_ key: String, count: Int) -> String {
        let lang = language
        for b in lock.withLock({ bundles }) {
            for l in [lang, "en"] {
                guard let path = b.path(forResource: l, ofType: "lproj"), let lb = Bundle(path: path) else { continue }
                for url in lb.urls(forResourcesWithExtension: "stringsdict", subdirectory: nil) ?? [] {
                    let tableName = url.deletingPathExtension().lastPathComponent
                    let fmt = lb.localizedString(forKey: key, value: "\u{0}", table: tableName)
                    if fmt != "\u{0}" { return String(format: fmt, locale: Locale(identifier: l), count) }
                }
            }
        }
        return String(format: string(key), count)
    }

    /// All keys of a language across registered bundles (completeness checks / tests).
    public func keys(for lang: String) -> Set<String> {
        Set(L10n.load(lang, from: lock.withLock { bundles }).keys)
    }

    private func reload() {
        let (bs, lang) = lock.withLock { (bundles, _language) }
        let t = L10n.load(lang, from: bs)
        let f = lang == "en" ? t : L10n.load("en", from: bs)
        lock.withLock { table = t; fallback = f }
    }

    public static func load(_ lang: String, from bundles: [Bundle]) -> [String: String] {
        var out: [String: String] = [:]
        for b in bundles {
            guard let lproj = b.url(forResource: lang, withExtension: "lproj") else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: lproj, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "strings" {
                guard let dict = NSDictionary(contentsOf: f) as? [String: String] else { continue }
                out.merge(dict) { a, _ in a }
            }
        }
        return out
    }
}

/// Shorthand: `tr("panel.media")`, `tr("toast.undo", name)` (format arguments).
public func tr(_ key: String, _ args: any CVarArg...) -> String { L10n.shared.string(key, args) }

/// Locates a SwiftPM resource bundle both inside the .app (Contents/Resources) and in `.build` (tests / swift run),
/// without touching `Bundle.module` when the app is packaged.
public enum ResourceBundleLocator {
    public static func find(_ name: String, fallback: @autoclosure () -> Bundle) -> Bundle {
        let file = "\(name).bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(file),
            Bundle.main.bundleURL.appendingPathComponent(file),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(file),
        ]
        for c in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: c.path) {
            if let b = Bundle(url: c) { return b }
        }
        return fallback()
    }
}

public enum CoreResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Montage_MontageCore", fallback: .module)
}
