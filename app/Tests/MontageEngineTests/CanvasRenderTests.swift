import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import MontageCore
import MontageEngine
import MontageTestSupport

/// Canvas background (CV-002) through the real compositor: preview and export share this path.
@Suite(.serialized) struct CanvasRenderTests {
    @Test func colorCanvasFillsLetterbox() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(.red), size: CGSize(width: 180, height: 320))
        p[id].canvas = .color(.green)
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: .red))
        #expect(img[0.05, 0.5].isClose(to: .green))
    }

    @Test func blurCanvasFillsLetterboxWithClipColours() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(.red), size: CGSize(width: 180, height: 320))
        let plain = try await p.render(at: 0.5)
        #expect(plain[0.05, 0.5].isClose(to: .black))
        p[id].canvas = .blur(level: 3)
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: .red))
        #expect(img[0.05, 0.5].isClose(to: .red, tolerance: 0.15))
    }

    @Test func presenterContentRectPlacesFrame() throws {
        // Zoom/pan path: the present pass maps the frame into an arbitrary rect.
        let ctx = MetalContext.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 100, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let src = ctx.device.makeTexture(descriptor: d)!, out = ctx.device.makeTexture(descriptor: d)!
        let white = [UInt8](repeating: 255, count: 100 * 100 * 4)
        src.replace(region: MTLRegionMake2D(0, 0, 100, 100), mipmapLevel: 0, withBytes: white, bytesPerRow: 400)
        let cmd = ctx.queue.makeCommandBuffer()!
        Presenter.encode(src, to: out, contentAspect: 1, letterbox: .black, contentRect: CGRect(x: 50, y: 0, width: 50, height: 50),
                         commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 100 * 100 * 4)
        out.getBytes(&px, bytesPerRow: 400, from: MTLRegionMake2D(0, 0, 100, 100), mipmapLevel: 0)
        func at(_ x: Int, _ y: Int) -> UInt8 { px[(y * 100 + x) * 4] }
        #expect(at(75, 25) > 200)   // inside the top-right quadrant
        #expect(at(25, 25) < 30)    // letterbox
        #expect(at(75, 75) < 30)
    }
}
