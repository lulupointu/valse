import Testing
import Foundation
@preconcurrency import Metal
import ValseEngine
@testable import ValseUI

/// macOS 13 (Intel Macs): the timeline canvas library compiles with MSL 3.0 (engine libraries: `Mac2GPUTests`).
@MainActor struct Mac2UIShaderTests {
    @Test func timelineCanvasCompilesWithMSL30() throws {
        let o = MTLCompileOptions()
        o.languageVersion = GPUCapabilities.baselineLanguageVersion
        _ = try MetalContext.shared.device.makeLibrary(source: Canvas2DRenderer.shader, options: o)
    }
}
