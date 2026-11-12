@preconcurrency import CoreML
import CoreVideo
import Foundation

/// Cross-process exclusive lock (`flock` on a file next to the compiled models) around Core ML compiles, loads and
/// first predictions (FLAKY-LAMA): Core ML keeps the GPU / ANE program it builds from a model in an on-disk cache shared
/// by every process of the same name (`~/Library/Caches/Valse/com.apple.e5rt.e5bundlecache`: all UI-test apps, the dev
/// app) and (re)writes it in place while loading. A process loading while another writes reads a half-written
/// `model_0.mpsgraph`; its load "succeeds" and its first prediction aborts the app in MPSGraph
/// (`MPSGraphTensorData.mm:223: failed assertion 'shape.count = 0 != strides.count = 4'`, f4_ai_remove_long,
/// Valse-2026-11-04-201454.ips; reproduced by truncating that file before a load: LaMaStressTests).
/// `flock` also excludes other threads of this process (each call opens its own descriptor). Released on return, and by
/// the kernel when a holder dies. Load models with `CoreMLModels.load`, never `MLModel(contentsOf:)` (CoreMLLoadLintTests).
public enum CoreMLLoadLock {
    /// The lock file for a compiled model: one per (resolved) models folder, so every process agrees on it.
    public static func url(for compiledModel: URL) -> URL {
        compiledModel.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(".coreml-load.lock")
    }

    /// Runs `body` holding the lock. Waits for other holders (polling, so `cancelled` is honoured); after `timeout`
    /// (a holder that hangs) it runs anyway rather than never.
    public static func withLock<T>(_ lockFile: URL, timeout: TimeInterval = 600, cancelled: () -> Bool = { false },
                                   _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return try body() }   // unwritable folder: nothing to share it with
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return try body() }
            if cancelled() { throw CancellationError() }
            if Date() > deadline { return try body() }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// The one way Valse loads its own Core ML models (downloaded / compiled into Caches/Valse/models).
public enum CoreMLModels {
    /// Loads `compiled` and runs one warm-up prediction (Core ML finishes building and caching its program there),
    /// both under `CoreMLLoadLock`. `warmUp` overrides the default input (blank images, zero arrays from the model's
    /// description); return nil to skip the warm-up (inputs it cannot build). Blocking: call it off the cooperative pool.
    public static func load(_ compiled: URL, computeUnits: MLComputeUnits = .all, cancelled: () -> Bool = { false },
                            warmUp: ((MLModel) throws -> MLFeatureProvider?)? = nil) throws -> MLModel {
        let url = compiled.resolvingSymlinksInPath()
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        return try CoreMLLoadLock.withLock(CoreMLLoadLock.url(for: url), cancelled: cancelled) {
            let m = try MLModel(contentsOf: url, configuration: cfg)
            if let input = try warmUp.map({ try $0(m) }) ?? blankInput(for: m) { _ = try m.prediction(from: input) }
            return m
        }
    }

    /// `MLModel.compileModel(at:)` under the lock of the models folder `destination` will live in.
    public static func compile(_ package: URL, for destination: URL) throws -> URL {
        try CoreMLLoadLock.withLock(CoreMLLoadLock.url(for: destination)) { try MLModel.compileModel(at: package) }
    }

    /// Blank images / zero arrays matching the model's inputs, or nil when one cannot be built.
    static func blankInput(for m: MLModel) -> MLFeatureProvider? {
        var values: [String: MLFeatureValue] = [:]
        for (name, d) in m.modelDescription.inputDescriptionsByName {
            switch d.type {
            case .image:
                guard let c = d.imageConstraint, c.pixelsWide > 0, c.pixelsHigh > 0 else { return nil }
                var pb: CVPixelBuffer?
                let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
                guard CVPixelBufferCreate(nil, c.pixelsWide, c.pixelsHigh, c.pixelFormatType, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) { memset(base, 0, CVPixelBufferGetDataSize(pb)) }
                CVPixelBufferUnlockBaseAddress(pb, [])
                values[name] = MLFeatureValue(pixelBuffer: pb)
            case .multiArray:
                guard let c = d.multiArrayConstraint else { return nil }
                let shape = c.shape.isEmpty ? (c.shapeConstraint.enumeratedShapes.first ?? []) : c.shape
                guard !shape.isEmpty, let a = try? MLMultiArray(shape: shape, dataType: c.dataType) else { return nil }
                a.withUnsafeMutableBytes { p, _ in if let b = p.baseAddress { memset(b, 0, p.count) } }
                values[name] = MLFeatureValue(multiArray: a)
            default:
                return nil
            }
        }
        return try? MLDictionaryFeatureProvider(dictionary: values)
    }
}
