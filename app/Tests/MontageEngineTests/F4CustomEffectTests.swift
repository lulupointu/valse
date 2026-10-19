import Testing
import Foundation
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// F4 FX-018: custom effect packages (manifest + Metal shader + sliders): import (folder / ZIP), compile errors,
/// render with slider values, reload after an edit, delete, export / re-import.
@Suite(.serialized) struct F4CustomEffectTests {
    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("f4-fx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A package that paints `color` param (default red) where the slider "mix" says so.
    static func package(in dir: URL, id: String, shader: String? = nil) throws -> URL {
        let pkg = dir.appendingPathComponent("\(id).montagefx")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let manifest = """
        {"id": "\(id)", "name": "Tint test", "name_fr": "Test teinte", "tags": ["Test"],
         "params": [{"key": "mix", "name": "Mix", "name_fr": "Mélange", "min": 0, "max": 1, "default": 1},
                    {"key": "color", "name": "Colour", "type": "color", "default": [1, 0, 0, 1]}]}
        """
        try manifest.write(to: pkg.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let body = shader ?? """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            return float4(mix(c.rgb, float3(p[1], p[2], p[3]), p[0]), c.a);
        }
        """
        try body.write(to: pkg.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        return pkg
    }

    @Test func importRendersWithSlidersAndColour() async throws {
        let lib = CustomEffectLibrary(directory: Self.tempDir())
        let id = "tint\(UUID().uuidString.prefix(6))"
        let e = try lib.importPackage(try Self.package(in: Self.tempDir(), id: id))
        #expect(e.effectID == "user.effect.\(id)")
        let d = try #require(Registries.effects[e.effectID])
        #expect(d.groupKey == CustomEffectLibrary.groupKey && d.category == .effect)
        #expect(d.params.map(\.key) == ["mix", "color"])
        #expect(d.tags.contains("test"))
        #expect(FileManager.default.fileExists(atPath: lib.directory.appendingPathComponent("\(id).montagefx/manifest.json").path))

        var p = TestProject(canvas: Size2(160, 90), background: .black)
        let clip = try p.addSolid(RGBA(0, 0, 1))
        var inst = d.makeInstance()
        p[clip].effects = [inst]
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: .red), "default: full red")
        inst.params["mix"] = .scalar(0.5)
        inst.params["color"] = .color(RGBA(0, 1, 0, 1))
        p[clip].effects = [inst]
        let half = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(half.g > 0.3 && half.b > 0.3 && half.r < 0.1, "\(half)")
        lib.remove(e.effectID)
        #expect(Registries.effects[e.effectID] == nil)
        #expect(lib.all.isEmpty)
    }

    @Test func compileErrorsAreReportedAndNothingIsInstalled() throws {
        let lib = CustomEffectLibrary(directory: Self.tempDir())
        let id = "broken\(UUID().uuidString.prefix(6))"
        let pkg = try Self.package(in: Self.tempDir(), id: id, shader: "float4 effect(float2 uv) { return oops; }")
        #expect(throws: CustomEffectLibrary.ImportError.self) { try lib.importPackage(pkg) }
        do { try lib.importPackage(pkg) } catch {
            let m = CustomEffectLibrary.message(error)
            #expect(m.contains("oops") || m.lowercased().contains("error"), "\(m)")
        }
        #expect(Registries.effects["user.effect.\(id)"] == nil)
        #expect(!FileManager.default.fileExists(atPath: lib.directory.appendingPathComponent("\(id).montagefx").path))
    }

    @Test func badManifestsAreRejected() throws {
        let lib = CustomEffectLibrary(directory: Self.tempDir())
        let dir = Self.tempDir()
        try "{\"id\": \"../evil\", \"name\": \"x\"}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        #expect(throws: CustomEffectLibrary.ImportError.self) { try lib.importPackage(dir) }
        #expect(throws: CustomEffectLibrary.ImportError.self) { try lib.importPackage(Self.tempDir()) }   // no manifest
    }

    @Test func zipRoundTripTemplateAndReloadAfterEdit() async throws {
        let lib = CustomEffectLibrary(directory: Self.tempDir())
        let t = try lib.createTemplate()
        #expect(t.manifest.id == "myEffect")
        #expect(Registries.effects[t.effectID]?.params.count == 2)
        // edit the shader on disk (as in a text editor) → reload picks it up (full green)
        let green = """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) { return float4(0.0, 1.0, 0.0, 1.0); }
        """
        try green.write(to: t.folder.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        #expect(lib.loadAll(compile: true).isEmpty)
        var p = TestProject(canvas: Size2(160, 90), background: .black)
        let clip = try p.addSolid(RGBA(0, 0, 1))
        p[clip].effects = [Registries.effects[t.effectID]!.makeInstance()]
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0, 1, 0)))
        // export → delete → re-import the ZIP
        let zip = Self.tempDir().appendingPathComponent("fx.zip")
        try lib.exportZIP(t.effectID, to: zip)
        lib.remove(t.effectID)
        #expect(Registries.effects[t.effectID] == nil)
        let back = try lib.importPackage(zip)
        #expect(back.effectID == t.effectID && Registries.effects[t.effectID] != nil)
        lib.remove(t.effectID)
    }
}
