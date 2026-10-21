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
/// - Thread safety: language, bundles and the merged tables form one immutable `State` value, built off-lock and
///   swapped in by a single assignment; every reader works from one snapshot of it.
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()
    public static let supportedLanguages = ["en", "fr"]
    /// UserDefaults key holding "system", "en" or "fr".
    public static let overrideDefaultsKey = "MontageLanguage"
    public static let didChange = Notification.Name("MontageLanguageDidChange")

    /// Everything a lookup depends on, swapped in as ONE value: language, bundles and their merged tables always match
    /// (a reader never sees the new language with the old table, or a table missing a just-registered module).
    private struct State {
        var generation: Int
        var bundles: [Bundle]
        var language: String
        var table: [String: String]
        var fallback: [String: String]   // English (== table when the language is English)
    }

    /// Guards `state` + `otherTables`; held only to copy / swap them, never while reading files (readers, e.g. on the
    /// main thread, never wait for a table load).
    private let lock = NSLock()
    /// Serializes mutations (register / language switch): each one builds on the state it replaces, so two concurrent
    /// mutations can't lose each other's update.
    private let writeLock = NSLock()
    private var state: State
    /// Tables of non-active languages, valid for `state.generation` only.
    private var otherTables: (generation: Int, tables: [String: [String: String]]) = (0, [:])

    private init() {
        state = L10n.makeState(generation: 0, bundles: [CoreResources.bundle],
                               language: L10n.resolveLanguage(AppDefaults.store.string(forKey: L10n.overrideDefaultsKey)))
    }

    /// An independent instance (not `shared`): tests that switch languages use one, so they never flip the
    /// process-wide language under other tests running in parallel.
    public init(bundles: [Bundle], language: String) {
        state = L10n.makeState(generation: 0, bundles: bundles, language: L10n.resolveLanguage(language))
    }

    private var snapshot: State { lock.withLock { state } }

    /// Active language code ("en" / "fr").
    public var language: String { snapshot.language }

    public var locale: Locale { Locale(identifier: language) }

    /// Registers a module resource bundle (idempotent).
    public func register(_ bundle: Bundle) {
        update { s in
            guard !s.bundles.contains(where: { $0.bundleURL == bundle.bundleURL }) else { return nil }
            return (s.bundles + [bundle], s.language)
        }
    }

    /// Sets the in-app language ("system", "en", "fr"); persists it and notifies observers.
    public func setLanguagePreference(_ pref: String) {
        AppDefaults.store.set(pref, forKey: L10n.overrideDefaultsKey)
        setLanguage(L10n.resolveLanguage(pref))
    }

    /// Forces a language for this process only (e.g. `--lang fr`), without persisting.
    public func setLanguageForSession(_ lang: String) {
        setLanguage(L10n.resolveLanguage(lang))
    }

    private func setLanguage(_ lang: String) {
        update { s in s.language == lang ? nil : (s.bundles, lang) }
        NotificationCenter.default.post(name: L10n.didChange, object: nil)
    }

    /// One mutation: `change` maps the current state to new (bundles, language), or nil for no change. The tables are
    /// loaded outside `lock`, then the complete new state replaces the old one in a single assignment.
    private func update(_ change: (State) -> (bundles: [Bundle], language: String)?) {
        writeLock.withLock {
            let cur = snapshot
            guard let (bundles, lang) = change(cur) else { return }
            let next = L10n.makeState(generation: cur.generation + 1, bundles: bundles, language: lang)
            lock.withLock { state = next }
        }
    }

    private static func makeState(generation: Int, bundles: [Bundle], language: String) -> State {
        let t = load(language, from: bundles)
        let f = language == "en" ? t : load("en", from: bundles)
        return State(generation: generation, bundles: bundles, language: language, table: t, fallback: f)
    }

    public var languagePreference: String { AppDefaults.store.string(forKey: L10n.overrideDefaultsKey) ?? "system" }

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
        let s = snapshot
        let fmt = s.table[key] ?? s.fallback[key] ?? key
        return args.isEmpty ? fmt : String(format: fmt, locale: Locale(identifier: s.language), arguments: args)
    }

    public func has(_ key: String) -> Bool { snapshot.table[key] != nil }

    /// Every string of one language (cached), e.g. to match names typed in either language (EditPilot).
    public func strings(for lang: String) -> [String: String] {
        let s = snapshot
        if lang == s.language { return s.table }
        if lang == "en" { return s.fallback }
        if let t = lock.withLock({ otherTables.generation == s.generation ? otherTables.tables[lang] : nil }) { return t }
        let t = L10n.load(lang, from: s.bundles)
        lock.withLock {
            // a table loaded from an older bundle set is never cached over a newer one
            guard state.generation == s.generation else { return }
            if otherTables.generation != s.generation { otherTables = (s.generation, [:]) }
            otherTables.tables[lang] = t
        }
        return t
    }

    /// Plural-aware lookup via `.stringsdict` (e.g. "%d clips").
    public func plural(_ key: String, count: Int) -> String {
        let s = snapshot
        for b in s.bundles {
            for l in [s.language, "en"] {
                guard let path = b.path(forResource: l, ofType: "lproj"), let lb = Bundle(path: path) else { continue }
                for url in lb.urls(forResourcesWithExtension: "stringsdict", subdirectory: nil) ?? [] {
                    let tableName = url.deletingPathExtension().lastPathComponent
                    let fmt = lb.localizedString(forKey: key, value: "\u{0}", table: tableName)
                    if fmt != "\u{0}" { return String(format: fmt, locale: Locale(identifier: l), count) }
                }
            }
        }
        return String(format: s.table[key] ?? s.fallback[key] ?? key, count)
    }

    /// All keys of a language across registered bundles (completeness checks / tests).
    public func keys(for lang: String) -> Set<String> {
        Set(L10n.load(lang, from: snapshot.bundles).keys)
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
