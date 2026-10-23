@preconcurrency import AVFoundation
import Foundation
import Testing
import MontageCore
import MontageEngine
import MontageTestSupport

/// FLAKY-SYS-UNIT probe (opt-in, `MONTAGE_ENCODER_STRESS=<n>`): many AVAssetWriter encodes at once (synthetic media,
/// H.264 / HEVC Main10 HLG exports, reversed renders), the load the parallel unit suite + other checkouts put on
/// VideoToolbox. Prints every failure with its underlying errors.
@Suite struct EncoderLoadStressTests {
    static let n = Int(ProcessInfo.processInfo.environment["MONTAGE_ENCODER_STRESS"] ?? "") ?? 0

    static func describe(_ e: Error) -> String {
        var s = "\(e)"
        var u = (e as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        while let x = u { s += " <- \(x.domain) \(x.code)"; u = x.userInfo[NSUnderlyingErrorKey] as? NSError }
        return s
    }

    @Test func manyConcurrentEncodes() async throws {
        guard Self.n > 0 else { print("skip: set MONTAGE_ENCODER_STRESS=<jobs>"); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("enc-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = try await TestMedia.video(.movingBox(.blue, .white), seconds: 1, audioHz: 330)
        var hdr = TestProject(canvas: Size2(320, 180))
        hdr.project.settings.colorSpace = .hdrHLG
        try await hdr.addVideo(.solid(.white), seconds: 1)
        let hdrProject = hdr.project
        var sdr = TestProject(canvas: Size2(640, 360))
        try await sdr.addMedia(src)
        let sdrProject = sdr.project
        typealias Job = @Sendable () async throws -> Void
        let kinds: [(String, Job)] = [
            ("synthetic", { try await SyntheticMedia.writeVideo(to: tmp.appendingPathComponent("\(UUID()).mp4"), size: CGSize(width: 320, height: 180),
                                                                 seconds: 1, fps: 30, pattern: .solid(RGBA(0.5, 0.5, 0.5)), audioHz: 330) }),
            ("hdrExport", { var s = ExportSettings(); s.resolution = .p480
                try await Exporter.export(project: hdrProject, settings: s, to: tmp.appendingPathComponent("\(UUID()).mov"),
                                          range: TimeRange(start: .zero, duration: Time(0.3))) }),
            ("sdrToneMap", { var s = ExportSettings(); s.resolution = .p480; s.toneMapToSDR = true
                try await Exporter.export(project: hdrProject, settings: s, to: tmp.appendingPathComponent("\(UUID()).mov"),
                                          range: TimeRange(start: .zero, duration: Time(0.3))) }),
            ("h264Export", { var s = ExportSettings(); s.resolution = .p480
                try await Exporter.export(project: sdrProject, settings: s, to: tmp.appendingPathComponent("\(UUID()).mov"),
                                          range: TimeRange(start: .zero, duration: Time(0.5))) }),
            ("reverse", { try await ReverseManager.generate(source: src, to: tmp.appendingPathComponent("\(UUID()).mov")) }),
        ]
        let failures = try await withThrowingTaskGroup(of: (String, String?).self) { g in
            for i in 0..<Self.n {
                let (name, job) = kinds[i % kinds.count]
                g.addTask {
                    do { try await job(); return (name, nil) } catch { return (name, Self.describe(error)) }
                }
            }
            var out: [(String, String)] = []
            for try await (name, err) in g { if let err { out.append((name, err)) } }
            return out
        }
        for (name, e) in failures { print("encoder stress failure [\(name)]: \(e)") }
        print("encoder stress: \(failures.count) / \(Self.n) failed")
        #expect(failures.isEmpty)
    }

    /// The flaky tests' own bodies, `n` of each at once (their #expect issues are recorded on this test).
    @Test func flakyBodiesConcurrently() async throws {
        guard Self.n > 0 else { print("skip: set MONTAGE_ENCODER_STRESS=<jobs>"); return }
        typealias Job = @Sendable () async throws -> Void
        let kinds: [(String, Job)] = [
            ("hdrToneMappedToSDR", { try await ExportFormatTests().hdrToneMappedToSDR() }),
            ("hlgSourcePassesThroughHLGProject", { try await HDRTests().hlgSourcePassesThroughHLGProject() }),
            ("hdrProjectExportsHEVCMain10HLG", { try await HDRTests().hdrProjectExportsHEVCMain10HLG() }),
            ("reversedAudioIsSampleReversed", { try await TimeRemapTests().reversedAudioIsSampleReversed() }),
        ]
        let failures = try await withThrowingTaskGroup(of: (String, String?).self) { g in
            for i in 0..<Self.n {
                let (name, job) = kinds[i % kinds.count]
                g.addTask { do { try await job(); return (name, nil) } catch { return (name, Self.describe(error)) } }
            }
            var out: [(String, String)] = []
            for try await (name, err) in g { if let err { out.append((name, err)) } }
            return out
        }
        for (name, e) in failures { print("body stress failure [\(name)]: \(e)") }
        print("body stress: \(failures.count) / \(Self.n) threw")
        #expect(failures.isEmpty)
    }
}
