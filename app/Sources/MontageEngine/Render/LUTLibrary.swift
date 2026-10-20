@preconcurrency import Metal
import CryptoKit
import Foundation
import MontageCore
import MontageEffects

/// Resolves `EffectInput`s to GPU textures for `FrameRenderer.applyEffects`.
public enum EffectInputs {
    public static func texture(for input: EffectInput) -> MTLTexture? {
        switch input {
        case .lut3D(let id): return LUTLibrary.texture(id)
        case .original, .backdrop: return nil   // bound by the renderer (the effect's own input / the un-cut layer)
        }
    }
}

/// Imported LUTs (CapCut Adjust ▸ Basic ▸ LUT, "Import LUT").
///
/// - Import copies the file to `~/Library/Application Support/Montage/LUTs/<hash>.cube|3dl` (content hash, so the
///   same LUT imported twice is one entry, and projects keep working when the original file moves) and records its
///   display name in `index.json`.
/// - Each LUT becomes one effect descriptor `user.lut.<hash>` (category `.adjustment`, one Strength param) registered
///   in `Registries.effects`, so it is keyframeable, works on clips and adjustment layers, preview and export alike.
/// - The GPU texture is a rgba16Float 3D lattice (1D LUTs are baked to 33³), created lazily and cached.
/// `loadAll()` registers the library at startup.
public final class LUTLibrary: @unchecked Sendable {
    public static let shared = LUTLibrary(directory: defaultDirectory)
    public static let idPrefix = "user.lut."

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Montage/LUTs", isDirectory: true)
    }

    public struct Entry: Sendable, Hashable, Codable {
        public let id: String
        public let name: String
        public let fileName: String
    }

    public let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    // Shared by all instances: LUT data + textures by effect id (the renderer has no library reference).
    nonisolated(unsafe) private static var luts: [String: LUT] = [:]
    nonisolated(unsafe) private static var textures: [String: MTLTexture] = [:]
    private static let storeLock = NSLock()

    public init(directory: URL) { self.directory = directory }

    /// Entries in name order (inspector dropdown).
    public var all: [Entry] { lock.withLock { entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } } }

    public func entry(_ id: String) -> Entry? { lock.withLock { entries[id] } }

    /// Registers every LUT already in the library directory (parses the files; textures are created on first use).
    public func loadAll() {
        let index = readIndex()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for f in files where f.hasSuffix(".cube") || f.hasSuffix(".3dl") {
            let hash = (f as NSString).deletingPathExtension
            let url = directory.appendingPathComponent(f)
            guard let lut = try? LUT.load(url) else { continue }
            add(lut, id: Self.idPrefix + hash, name: index[hash] ?? lut.title, fileName: f)
        }
    }

    /// Imports a .cube/.3dl file (validates it first). Returns the effect descriptor id. Idempotent per content.
    @discardableResult
    public func importLUT(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let lut = try LUT.load(url)
        let hash = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased() == "3dl" ? "3dl" : "cube"
        let fileName = "\(hash).\(ext)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dst = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: dst.path) { try data.write(to: dst, options: .atomic) }
        let name = url.deletingPathExtension().lastPathComponent
        var index = readIndex(); index[hash] = name; writeIndex(index)
        let id = Self.idPrefix + hash
        add(lut, id: id, name: name, fileName: fileName)
        return id
    }

    /// Registers an in-memory LUT (generated looks, tests). Returns the descriptor id. `listed: false` keeps it out of
    /// the LUT dropdown (AI looks such as Auto adjust / Color match have their own sections).
    @discardableResult
    public func add(_ lut: LUT, id: String, name: String, fileName: String = "", listed: Bool = true) -> String {
        if listed { lock.withLock { entries[id] = Entry(id: id, name: name, fileName: fileName) } }
        Self.storeLock.withLock { Self.luts[id] = lut.baked3D(); Self.textures[id] = nil }
        Registries.effects.register(Self.descriptor(id: id, name: name))
        return id
    }

    /// The effect for a LUT. `nameKey` is the display name itself (user content, not localized).
    static func descriptor(id: String, name: String) -> EffectDescriptor {
        EffectDescriptor(
            id: id, category: .adjustment, nameKey: name, groupKey: "adjust.group.lut",
            params: [.scalar("intensity", "fx.param.strength", 0, 1, 1, display: 100)],
            symbol: "cube", inputs: [.lut3D(id: id)],
            shader: """
            float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx,
                          texture3d<float> lut, sampler s3) {
                float4 c = src.sample(s, uv);
                float3 g = fx_lut3d(lut, s3, c.rgb);
                return float4(mix(c.rgb, g, saturate(p[0])), c.a);
            }
            """)
    }

    /// GPU texture for a registered LUT (created on first use).
    static func texture(_ id: String) -> MTLTexture? {
        storeLock.withLock {
            if let t = textures[id] { return t }
            guard let lut = luts[id] else { return nil }
            let t = makeTexture(lut)
            textures[id] = t
            return t
        }
    }

    static func makeTexture(_ lut: LUT) -> MTLTexture? {
        let n = lut.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        d.storageMode = MetalContext.shared.caps.readbackStorageMode   // CPU-filled: shared (Apple GPU) / managed (Mac2)
        guard let t = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        #if arch(arm64)
        var half = [Float16](repeating: 1, count: n * n * n * 4)
        for (i, v) in lut.values.enumerated() {
            half[i * 4] = Float16(v.x); half[i * 4 + 1] = Float16(v.y); half[i * 4 + 2] = Float16(v.z)
        }
        #else   // Float16 is unavailable on x86_64: same IEEE half bits via the portable conversion
        var half = [UInt16](repeating: 0x3C00, count: n * n * n * 4)
        for (i, v) in lut.values.enumerated() {
            half[i * 4] = Half.bits(Float(v.x)); half[i * 4 + 1] = Half.bits(Float(v.y)); half[i * 4 + 2] = Half.bits(Float(v.z))
        }
        #endif
        half.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                      bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        return t
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func readIndex() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
    }
    private func writeIndex(_ i: [String: String]) {
        if let d = try? JSONEncoder().encode(i) { try? d.write(to: indexURL, options: .atomic) }
    }
}
