import Foundation
import MontageCore
import MontageEffects

/// FX-018 custom effect authoring (CapCut's effect creator, local): an effect package is a folder `<id>.montagefx`
/// (or a ZIP of it) holding
///
/// - `manifest.json`: `{"id": "ripple", "name": "Ripple", "name_fr": "Ondulation", "group": "…", "passes": 1,
///   "usesOriginal": false, "shader": "effect.metal", "tags": ["water"],
///   "params": [{"key": "amount", "name": "Amount", "name_fr": "Quantité", "min": 0, "max": 1, "default": 0.5},
///              {"key": "tint", "name": "Tint", "type": "color", "default": [1, 1, 1, 1]}]}`
/// - the Metal source: `float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx)`
///   (plus `texture2d<float> orig` when `usesOriginal`), the same contract and `kit_*` helpers as the built-in
///   library. `p[]` holds the sliders in manifest order (a colour takes 4 floats); `ctx.time`, `ctx.size`,
///   `ctx.aspect`, `ctx.pass` are available.
///
/// Packages live in `~/Library/Application Support/Montage/Effects/` and register as `user.effect.<id>` in the
/// Effects ▸ Custom group, so they behave like built-ins (cards, preview, sliders in the inspector, render, export).
/// Every import / reload compiles the shader first and reports the compiler message on failure.
public final class CustomEffectLibrary: @unchecked Sendable {
    nonisolated(unsafe) public static var shared = CustomEffectLibrary(directory: defaultDirectory)
    public static let idPrefix = "user.effect."
    public static let groupKey = "effect.group.custom"
    public static let packageExtension = "montagefx"

    public static var defaultDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["MONTAGE_USER_EFFECTS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        let name = ProcessInfo.processInfo.processName
        if CommandLine.arguments.contains("--uitest") || name.contains("xctest") || name.contains("swiftpm-testing") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("montage-uitest-effects-\(getpid())", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Montage/Effects", isDirectory: true)
    }

    public struct Param: Codable, Sendable, Hashable {
        public var key: String
        public var name: String
        public var name_fr: String?
        public var type: String?
        public var min: Double?
        public var max: Double?
        public var `default`: [Double]?
        public init(key: String, name: String, nameFr: String? = nil, type: String? = nil, min: Double? = nil, max: Double? = nil, default d: [Double]? = nil) {
            self.key = key; self.name = name; self.name_fr = nameFr; self.type = type; self.min = min; self.max = max; self.default = d
        }
        enum CodingKeys: String, CodingKey { case key, name, name_fr, type, min, max, `default` }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
            name_fr = try c.decodeIfPresent(String.self, forKey: .name_fr)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
            if let one = try? c.decode(Double.self, forKey: .default) { self.default = [one] }
            else { self.default = try c.decodeIfPresent([Double].self, forKey: .default) }
        }
    }

    public struct Manifest: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var name_fr: String?
        public var passes: Int?
        public var usesOriginal: Bool?
        public var shader: String?
        public var tags: [String]?
        public var params: [Param]?
    }

    public struct Entry: Sendable, Hashable {
        public let manifest: Manifest
        public let folder: URL
        public var effectID: String { CustomEffectLibrary.idPrefix + manifest.id }
    }

    public enum ImportError: Error, Equatable, Sendable {
        case noManifest
        case badManifest(String)
        case noShader(String)
        case compile(String)
        case unzip
    }

    public let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(directory: URL) { self.directory = directory }

    public var all: [Entry] { lock.withLock { entries.values.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending } } }
    public func entry(_ effectID: String) -> Entry? { lock.withLock { entries[effectID] } }

    // MARK: Loading

    /// Registers every package of the library folder (launch, Effects ▸ Custom ▸ Reload). Packages whose shader no
    /// longer compiles stay listed in `failures` (id → message) and are not registered.
    @discardableResult
    public func loadAll(compile: Bool = false) -> [String: String] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Self.packageExtension }
        var failures: [String: String] = [:]
        var seen = Set<String>()
        for f in folders {
            do {
                let e = try Self.read(f)
                let d = Self.descriptor(e)
                if compile, let err = EffectPipelines.shared.compileError(d) { failures[e.manifest.id] = err; continue }
                EffectPipelines.shared.invalidate(effect: d.id)
                Registries.effects.register(d)
                lock.withLock { entries[d.id] = e }
                seen.insert(d.id)
            } catch {
                failures[f.deletingPathExtension().lastPathComponent] = Self.message(error)
            }
        }
        // packages removed from the folder by hand
        let gone = lock.withLock { entries.keys.filter { !seen.contains($0) } }
        for id in gone { Registries.effects.unregister(id); lock.withLock { entries[id] = nil } }
        return failures
    }

    // MARK: Import / create / delete / export

    /// Imports a `.montagefx` folder, any folder holding a `manifest.json`, or a ZIP of one. Replaces a package with
    /// the same id (an updated version). Throws with the compiler message when the shader doesn't compile.
    @discardableResult
    public func importPackage(_ url: URL) throws -> Entry {
        let fm = FileManager.default
        var src = url
        var tmp: URL?
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        if url.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("montagefx-\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tmp = t
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, t.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ImportError.unzip }
            guard let found = Self.findPackage(in: t) else { throw ImportError.noManifest }
            src = found
        } else if !fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
            guard let found = Self.findPackage(in: url) else { throw ImportError.noManifest }
            src = found
        }
        let e = try Self.read(src)
        let d = Self.descriptor(e)
        if let err = EffectPipelines.shared.compileError(d) { throw ImportError.compile(err) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent("\(e.manifest.id).\(Self.packageExtension)", isDirectory: true)
        if src.standardizedFileURL != dest.standardizedFileURL {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        }
        let stored = Entry(manifest: e.manifest, folder: dest)
        Registries.effects.register(Self.descriptor(stored))
        EffectPipelines.shared.invalidate(effect: d.id)
        lock.withLock { entries[d.id] = stored }
        return stored
    }

    /// "New effect": writes a commented template package (wave + tint, two sliders) into the library and registers it.
    @discardableResult
    public func createTemplate(name: String = "My effect", nameFr: String = "Mon effet") throws -> Entry {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 1
        var id = "myEffect"
        while fm.fileExists(atPath: directory.appendingPathComponent("\(id).\(Self.packageExtension)").path) { n += 1; id = "myEffect\(n)" }
        let folder = directory.appendingPathComponent("\(id).\(Self.packageExtension)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = Manifest(id: id, name: n == 1 ? name : "\(name) \(n)", name_fr: n == 1 ? nameFr : "\(nameFr) \(n)", passes: 1,
                         usesOriginal: false, shader: "effect.metal", tags: ["custom"],
                         params: [Param(key: "amount", name: "Wave", nameFr: "Vague", min: 0, max: 1, default: [0.5]),
                                  Param(key: "tint", name: "Tint", nameFr: "Teinte", type: "color", default: [1, 0.85, 0.6, 1])])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: folder.appendingPathComponent("manifest.json"))
        try Self.templateShader.write(to: folder.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        return try importPackage(folder)
    }

    public func remove(_ effectID: String) {
        guard let e = entry(effectID) else { return }
        try? FileManager.default.removeItem(at: e.folder)
        Registries.effects.unregister(effectID)
        EffectPipelines.shared.invalidate(effect: effectID)
        lock.withLock { entries[effectID] = nil }
    }

    /// ZIP of the package, to share it (re-importable on another Mac).
    public func exportZIP(_ effectID: String, to url: URL) throws {
        guard let e = entry(effectID) else { throw ImportError.noManifest }
        try? FileManager.default.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", e.folder.path, url.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportError.unzip }
    }

    // MARK: Package → descriptor

    static func findPackage(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let u as URL in en where u.lastPathComponent == "manifest.json" && !u.path.contains("__MACOSX") {
            return u.deletingLastPathComponent()
        }
        return nil
    }

    static func read(_ folder: URL) throws -> Entry {
        let mURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: mURL) else { throw ImportError.noManifest }
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw ImportError.badManifest(String(describing: error)) }
        let idOK = !m.id.isEmpty && m.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && m.id.count <= 64
        guard idOK else { throw ImportError.badManifest("id must be letters, digits, - or _") }
        guard !m.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ImportError.badManifest("name is empty") }
        guard (m.params ?? []).count <= 16, Set((m.params ?? []).map(\.key)).count == (m.params ?? []).count else {
            throw ImportError.badManifest("at most 16 params with unique keys")
        }
        let shaderFile = m.shader ?? "effect.metal"
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(shaderFile).path) else { throw ImportError.noShader(shaderFile) }
        return Entry(manifest: m, folder: folder)
    }

    /// Localized display name: `name_fr` in French when present. (Shown verbatim: names aren't l10n keys.)
    static func display(_ en: String, _ fr: String?) -> String {
        L10n.shared.language.hasPrefix("fr") ? (fr ?? en) : en
    }

    public static func descriptor(_ e: Entry) -> EffectDescriptor {
        let m = e.manifest
        let body = (try? String(contentsOf: e.folder.appendingPathComponent(m.shader ?? "effect.metal"), encoding: .utf8)) ?? ""
        let params: [ParamSpec] = (m.params ?? []).map { p in
            let name = display(p.name, p.name_fr)
            if p.type == "color" {
                let v = p.default ?? [1, 1, 1, 1]
                let c = RGBA(v.count > 0 ? v[0] : 1, v.count > 1 ? v[1] : 1, v.count > 2 ? v[2] : 1, v.count > 3 ? v[3] : 1)
                return ParamSpec(p.key, nameKey: name, .color(defaultValue: c))
            }
            let lo = p.min ?? 0, hi = max(p.max ?? 1, lo + 1e-6)
            let def = min(max(p.default?.first ?? lo, lo), hi)
            return .scalar(p.key, name, lo, hi, def, display: hi <= 1 && lo >= -1 ? 100 : 1)
        }
        return EffectDescriptor(id: idPrefix + m.id, category: .effect, nameKey: display(m.name, m.name_fr), groupKey: groupKey,
                                params: params, passes: max(1, min(m.passes ?? 1, 4)), symbol: "wand.and.stars",
                                inputs: (m.usesOriginal ?? false) ? [.original] : [],
                                tags: (m.tags ?? []).map { $0.lowercased() } + ["custom", m.id.lowercased()],
                                shader: FXKit.msl + "\n" + body)
    }

    public static func message(_ e: Error) -> String {
        switch e as? ImportError {
        case .noManifest?: return "manifest.json not found"
        case .badManifest(let s)?: return "manifest.json: \(s)"
        case .noShader(let f)?: return "shader file \(f) not found"
        case .compile(let s)?: return s
        case .unzip?: return "the ZIP could not be read"
        case nil: return String(describing: e)
        }
    }

    static let templateShader = """
    // Montage custom effect (FX-018). Edit this file, then Effects ▸ Custom ▸ Reload.
    // p[0] = "Wave" slider (0…1), p[1…4] = "Tint" colour (r, g, b, a). ctx.time = seconds into the effect,
    // ctx.size = pixels, ctx.aspect = width / height. kit_* helpers (kit_hue, kit_blur9, kit_fbm…) are available.
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        float wave = p[0];
        float3 tint = float3(p[1], p[2], p[3]);
        float2 q = uv + float2(sin(uv.y * 24.0 + ctx.time * 4.0), cos(uv.x * 18.0 + ctx.time * 3.0)) * 0.012 * wave;
        float4 c = src.sample(s, q);
        return float4(c.rgb * mix(float3(1.0), tint, 0.6), c.a);
    }
    """
}
