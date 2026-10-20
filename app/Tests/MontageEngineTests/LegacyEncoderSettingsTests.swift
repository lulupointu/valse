@preconcurrency import AVFoundation
import VideoToolbox
import Foundation
import Testing
import MontageCore
@testable import MontageEngine

/// macOS 13 / Intel: an encoder that does not know a compression property makes `canApply` fail (and
/// `AVAssetWriterInput.init` throw an ObjC exception). The exporter drops its optional properties instead of failing.
struct LegacyEncoderSettingsTests {
    func writer() throws -> AVAssetWriter {
        try AVAssetWriter(outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID()).mov"), fileType: .mov)
    }

    @Test func optionalKeysAreDroppedAndTheRestIsKept() throws {
        var s = ExportSettings(); s.codec = .hevc; s.preferHardware = true; s.fastEncoding = true
        let full = Exporter.videoSettings(s, w: 1280, h: 720, canvas: Size2(1280, 720), space: .hdrHLG, bitDepth: 10,
                                          ambient: Data(repeating: 1, count: 8))
        let props = try #require(full[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(props["AmbientViewingEnvironment"] != nil)
        #expect(props[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] != nil)
        let stripped = Exporter.withoutOptionalCompressionKeys(full)
        let sp = try #require(stripped[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(sp["AmbientViewingEnvironment"] == nil)
        #expect(sp[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] == nil)
        #expect(sp[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        #expect(sp.count == props.count - 2)
        #expect(try writer().canApply(outputSettings: stripped, forMediaType: .video))
    }

    @Test func unknownCompressionPropertyFailsCanApply() throws {
        // the mechanism the fallback relies on (an older encoder sees a newer key exactly like an unknown one)
        let s: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
                                AVVideoCompressionPropertiesKey: ["MontageUnknownKey": 1, AVVideoAverageBitRateKey: 1_000_000]]
        #expect(try !writer().canApply(outputSettings: s, forMediaType: .video))
    }
}
