@preconcurrency import Metal
import Foundation

/// What the Metal device can do beyond the `MTLGPUFamily.mac2` baseline (Intel / AMD GPUs of Intel Macs, macOS 13).
/// Every Mac2 fallback is gated on these flags, so the Apple-silicon path is unchanged.
///
/// `VALSE_FORCE_MAC2_GPU_PATH=1` forces the Mac2 path on an Apple GPU (tests / benchmarks of the fallbacks).
public struct GPUCapabilities: Sendable, Equatable {
    /// Apple-family GPU (Apple silicon): tile memory, programmable blending, shared-storage textures.
    public var isAppleGPU: Bool
    /// Programmable blending (`[[color(n)]]` fragment inputs). Apple GPUs only.
    public var framebufferFetch: Bool
    /// `MTLStorageMode.shared` allowed for textures (CPU readback textures). Apple GPUs only on macOS.
    public var sharedTextures: Bool
    /// Device memory budget hint (Intel HD/Iris 6xx: ~1.5 GB carved out of RAM).
    public var recommendedWorkingSet: UInt64

    public static let forceMac2EnvKey = "VALSE_FORCE_MAC2_GPU_PATH"
    public static var forceMac2FromEnvironment: Bool { ProcessInfo.processInfo.environment[forceMac2EnvKey] == "1" }

    public init(device: MTLDevice, forceMac2: Bool = GPUCapabilities.forceMac2FromEnvironment) {
        let apple = device.supportsFamily(.apple1) && !forceMac2
        isAppleGPU = apple
        framebufferFetch = apple
        sharedTextures = apple
        recommendedWorkingSet = device.recommendedMaxWorkingSetSize
    }

    /// Highest MSL version macOS 13 compiles. Runtime libraries are compiled with it on the Mac2 path
    /// (Apple path: `nil` = the OS default, unchanged); `ShaderMSLVersionTests` compiles everything with it.
    public static let baselineLanguageVersion: MTLLanguageVersion = .version3_0

    /// Options for every runtime `makeLibrary(source:options:)` call.
    public var compileOptions: MTLCompileOptions? {
        guard !isAppleGPU else { return nil }
        let o = MTLCompileOptions()
        o.languageVersion = Self.baselineLanguageVersion
        return o
    }

    /// Storage mode for textures the CPU reads back (`getBytes`). `.managed` needs `MetalContext.synchronize` first.
    public var readbackStorageMode: MTLStorageMode { sharedTextures ? .shared : .managed }
}
