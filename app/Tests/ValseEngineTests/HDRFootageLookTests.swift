import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseTestSupport

/// Manual look test: renders real HDR footage (`VALSE_HDR_FOOTAGE=<file>[|<file>…]`, `VALSE_HDR_OUT=<dir>`) through
/// the compositor in SDR / HLG / PQ projects and writes PNGs to compare with a reference. Skipped without the env vars.
@Suite(.serialized) struct HDRFootageLookTests {
    @Test func renderUserFootage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let paths = env["VALSE_HDR_FOOTAGE"], let out = env["VALSE_HDR_OUT"] else { return }
        let t = Double(env["VALSE_HDR_TIME"] ?? "5") ?? 5
        let suffix = env["VALSE_HDR_SUFFIX"] ?? ""
        for path in paths.split(separator: "|").map(String.init) {
            let tag = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let a = try await MediaProbe.probe(URL(fileURLWithPath: path))
            let portrait = a.pixelSize.height > a.pixelSize.width || (a.sourceRotation % 180 != 0)
            let at = min(t, max(0, a.duration.seconds - 0.5))
            for space in ProjectColorSpace.allCases {
                var p = TestProject(canvas: portrait ? Size2(540, 960) : Size2(640, 360))
                p.project.settings.colorSpace = space
                try await p.addMedia(URL(fileURLWithPath: path), duration: Time(at + 1))
                let cg = try await OfflineRenderer.renderFrame(p.project, at: Time(at))
                print("look \(tag) \(space): CGImage bpc \(cg.bitsPerComponent) space \(String(describing: cg.colorSpace?.name))")
                let img = Bitmap(cg)
                img.writePNG(URL(fileURLWithPath: out).appendingPathComponent("\(tag)-valse-\(space.rawValue)\(suffix).png"))
            }
        }
    }
}
