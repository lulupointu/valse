import Metal
import Foundation
import Testing
import ValseCore
import ValseEffects
@testable import ValseEngine

/// Runtime-compiled MSL must build with Metal Shading Language 3.0, the newest macOS 13 supports (the app compiles with
/// `options: nil` = the OS's newest; on 14+ that is 3.1+, so a 3.1-only construct would only fail on macOS 13).
struct MSLVersionTests {
    static func compile(_ source: String) -> String? {
        let o = MTLCompileOptions()
        o.languageVersion = .version3_0
        do { _ = try MetalContext.shared.device.makeLibrary(source: source, options: o); return nil }
        catch { return String(describing: error).split(separator: "\n").prefix(3).joined(separator: " ") }
    }

    @Test func engineLibrariesCompileWithMSL30() {
        let libs = ["CoreShaders": CoreShaders.source, "FinishShaders": FinishShaders.source, "FeatureShaders": FeatureShaders.source,
                    "F4Shaders": F4Shaders.source, "RelightShaders": RelightShaders.source,
                    "EffectPreviewScene": EffectPreviewRenderer.sceneSource, "TextGPU": TextGPU.shader]
        for (name, src) in libs {
            let e = Self.compile(src)
            #expect(e == nil, "\(name): \(e ?? "")")
        }
    }

    @Test func registryShadersCompileWithMSL30() {
        var sources: [String: String] = [:]   // source → first id (presets share sources)
        for d in Registries.effects.all where !d.shader.isEmpty {
            let s = ShaderPrelude.source + "\n" + d.shader + EffectPipelines.effectWrapper(inputs: d.inputs)
            if sources[s] == nil { sources[s] = d.id }
        }
        for d in Registries.transitions.all {
            let s = ShaderPrelude.source + "\n" + d.shader + EffectPipelines.transitionWrapper
            if sources[s] == nil { sources[s] = d.id }
        }
        #expect(sources.count > 50)
        let list = Array(sources)
        let failures = LockedList()
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            if let e = Self.compile(list[i].key) { failures.append("\(list[i].value): \(e)") }
        }
        #expect(failures.items.isEmpty, "\(failures.items.sorted().prefix(10))")
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock(); private var list: [String] = []
    func append(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
}
