import Foundation
import ValseCore

/// A downloadable on-device model. Models are never bundled or committed (`.gitignore` has `models/`); the user
/// downloads them once from the Model manager (Settings / the feature panel), or points Valse at an existing file.
/// Everything runs locally afterwards — the download is the only network access, always user-initiated.
public struct AIModelSpec: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case whisper, demucs, coreML, llm }
    public let id: String
    public let kind: Kind
    public let nameKey: String
    public let descriptionKey: String
    /// File name inside the models directory.
    public let fileName: String
    public let url: URL
    public let bytes: Int64
    /// Lower-case hex SHA-256 of the file (verified after download / import).
    public let sha256: String
    public let license: String
    /// Approximate resident memory while running (MB), shown in the manager and used by `MemoryBudget` checks.
    public let runtimeMB: Int
    /// Multi-file models (e.g. a compiled `.mlmodelc` directory): every file is downloaded and SHA-256 checked into
    /// `fileName` (a directory); `url` / `sha256` are then those of the largest part (the weights).
    public var parts: [Part]? = nil

    public struct Part: Sendable, Hashable {
        /// Path inside the model directory.
        public let path: String
        public let url: URL
        public let bytes: Int64
        public let sha256: String
    }
    /// Small extra files of a multi-file model (e.g. the other files of an `.mlpackage` directory whose big
    /// weights file is `fileName`), downloaded and verified before the main file. Paths are relative to the models folder.
    public var companions: [AIModelCompanion] = []
}

/// One extra file of a multi-file model (see `AIModelSpec.companions`).
public struct AIModelCompanion: Sendable, Hashable {
    public let path: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String
}

public enum ModelCatalog {
    /// Whisper large-v3-turbo, 5-bit (OpenAI MIT weights, ggml conversion by whisper.cpp). Best FR/EN accuracy (≈3 % WER
    /// on bench/speech_fr.wav), ~5–10× real time with Metal on M1.
    public static let whisperTurbo = AIModelSpec(
        id: "whisper.large-v3-turbo-q5_0", kind: .whisper, nameKey: "model.whisperTurbo", descriptionKey: "model.whisperTurbo.desc",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", license: "MIT", runtimeMB: 1100)

    /// Whisper small, 5-bit: lighter fallback for tight memory (8 GB with many apps open).
    public static let whisperSmall = AIModelSpec(
        id: "whisper.small-q5_1", kind: .whisper, nameKey: "model.whisperSmall", descriptionKey: "model.whisperSmall.desc",
        fileName: "ggml-small-q5_1.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
        bytes: 190_085_487, sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", license: "MIT", runtimeMB: 450)

    /// HTDemucs v4, 4 stems (drums / bass / other / vocals), f16 ggml for demucs.cpp (MIT weights by Meta, conversion by
    /// demucs.cpp). ~2× real time on CPU (Accelerate) — background job.
    public static let demucs4 = AIModelSpec(
        id: "demucs.htdemucs-4s", kind: .demucs, nameKey: "model.demucs4", descriptionKey: "model.demucs4.desc",
        fileName: "ggml-model-htdemucs-4s-f16.bin",
        url: URL(string: "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin")!,
        bytes: 83_994_361, sha256: "72b17c42d308982ddb5069bc3bf48b81a5aac4cb6516e4366c0fa7cef6df0064", license: "MIT", runtimeMB: 900)

    /// HTDemucs 6 stems (+ guitar, piano).
    public static let demucs6 = AIModelSpec(
        id: "demucs.htdemucs-6s", kind: .demucs, nameKey: "model.demucs6", descriptionKey: "model.demucs6.desc",
        fileName: "ggml-model-htdemucs-6s-f16.bin",
        url: URL(string: "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-6s-f16.bin")!,
        bytes: 54_855_129, sha256: "09704f4ceae204e56e77d5eefd6ac71d7275be81fd507e6913371d59abcee856", license: "MIT", runtimeMB: 900)

    /// Qwen3-4B-Instruct-2507, Q4_K_M GGUF (Apache-2.0, Alibaba; quantized by Unsloth) for llama.cpp: local text
    /// generation FR/EN (AI writer, AI clipper highlights) when Apple Intelligence is off. ~45 tok/s on M-series
    /// Metal, ~3 GB resident while a job runs (sidecar, unloaded afterwards).
    public static let qwen3_4b = AIModelSpec(
        id: "llm.qwen3-4b-instruct-q4km", kind: .llm, nameKey: "model.qwen3", descriptionKey: "model.qwen3.desc",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        bytes: 2_497_281_120, sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597", license: "Apache-2.0", runtimeMB: 3100)

    /// LaMa (big-lama, Apache-2.0, Samsung AI) Core ML, 800×800, ~600 MB peak: AI remove (object inpainting).
    public static let lama = AIModelSpec(
        id: "coreml.lama-800", kind: .coreML, nameKey: "model.lama", descriptionKey: "model.lama.desc",
        fileName: "LaMa.mlpackage.zip",
        url: URL(string: "https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/lama/LaMa.mlpackage.zip")!,
        bytes: 196_237_256, sha256: "b57b8451a1a86c00aea52d75230fb5f49d3076eec67403192758c9d2b59c0e69", license: "Apache-2.0", runtimeMB: 600)

    /// Depth Anything V2 Small, F16 Core ML package by Apple (Apache-2.0), 518×392: monocular depth for Relight
    /// (~50 MB, ~300 MB while running). An `.mlpackage` is a directory: the weights are the main file, the model spec
    /// and manifest are companions.
    public static let depthAnything: AIModelSpec = {
        let base = "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/"
        let pkg = "DepthAnythingV2SmallF16.mlpackage"
        var s = AIModelSpec(
            id: "coreml.depth-anything-v2-small", kind: .coreML, nameKey: "model.depth", descriptionKey: "model.depth.desc",
            fileName: "\(pkg)/Data/com.apple.CoreML/weights/weight.bin",
            url: URL(string: base + "\(pkg)/Data/com.apple.CoreML/weights/weight.bin")!,
            bytes: 49_419_072, sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed", license: "Apache-2.0", runtimeMB: 300)
        s.companions = [
            AIModelCompanion(path: "\(pkg)/Manifest.json", url: URL(string: base + "\(pkg)/Manifest.json")!, bytes: 617,
                             sha256: "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"),
            AIModelCompanion(path: "\(pkg)/Data/com.apple.CoreML/model.mlmodel", url: URL(string: base + "\(pkg)/Data/com.apple.CoreML/model.mlmodel")!,
                             bytes: 399_433, sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
        ]
        return s
    }()

    /// CLIP ViT-B/32 (OpenCLIP, DataComp-1B, MIT) as two compiled Core ML models + the CLIP BPE vocabulary, ~300 MB:
    /// free-text smart media search (AI-028) — "a dog on the beach", "sunset over the sea". Images are embedded once
    /// per media (3 frames, cached in the media index); a query costs one text-encoder pass (~10 ms).
    public static let clip: AIModelSpec = {
        let rev = "https://huggingface.co/InspiratioNULL/CLIP-VIT-B-32-DataComp.XL-CoreML/resolve/b2f82c6a9d42abae0c6e2211332037bbd5122c55/"
        func part(_ p: String, _ bytes: Int64, _ sha: String) -> AIModelSpec.Part {
            AIModelSpec.Part(path: p, url: URL(string: rev + p)!, bytes: bytes, sha256: sha)
        }
        let parts = [
            part("CLIP_ImageEncoder.mlmodelc/weights/weight.bin", 175_709_312, "aa215c95d527ea6508f368b70329299ffd387d23a193adc891dd971f1d268b56"),
            part("CLIP_ImageEncoder.mlmodelc/model.mil", 201_781, "06c6dc3ca679d9c66441230d23abc54b76c9442eaee35b6ece0cf0f5b67a95a2"),
            part("CLIP_ImageEncoder.mlmodelc/metadata.json", 2100, "ff41fdda7c2a02e16c4142757a331ff99138c2c05ca32e5ba4ecfb4a04759ac9"),
            part("CLIP_ImageEncoder.mlmodelc/coremldata.bin", 472, "68a77b743ee02d373e0f0a152d5146ea1eb9860a9c81b1979576a99972a9dcc2"),
            part("CLIP_ImageEncoder.mlmodelc/analytics/coremldata.bin", 243, "9d4292a5186e1d7b5fee66d202e904b13f8036e3a19fb7b91444478b0bf997ea"),
            part("CLIP_TextEncoder.mlmodelc/weights/weight.bin", 126_878_848, "3fa0dfd9975b5e10a37e3cd8cc4a563d28be2eeb7fc84e575ba74c0136176a01"),
            part("CLIP_TextEncoder.mlmodelc/model.mil", 197_123, "58ca3815f654a44de9b36ae107b20266aec1463ec2134109bce2267264e1c1fc"),
            part("CLIP_TextEncoder.mlmodelc/metadata.json", 2111, "6d28e82797c18f495bfdb21773503b04b0ad4e54fe5fe20b6f57259e9332c0cd"),
            part("CLIP_TextEncoder.mlmodelc/coremldata.bin", 478, "1ea6f6dfb60c6f0f8d80c2e06500b1bf6a835a114aad66094dc4bf097f238935"),
            part("CLIP_TextEncoder.mlmodelc/analytics/coremldata.bin", 243, "c1c58c2cf62ade0826a10b4441c8bb7e4fcd64a0fe5db2ed2d0a77cb8c6bbc0c"),
            part("vocab.json", 862_328, "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
            part("merges.txt", 524_657, "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"),
        ]
        var s = AIModelSpec(id: "coreml.clip-vit-b32", kind: .coreML, nameKey: "model.clip", descriptionKey: "model.clip.desc",
                            fileName: "CLIP-ViT-B-32-DataComp", url: parts[0].url, bytes: parts.reduce(0) { $0 + $1.bytes },
                            sha256: parts[0].sha256, license: "MIT", runtimeMB: 450)
        s.parts = parts
        return s
    }()

    /// Apple's Depth Anything package is Core ML spec 8 (iOS 17 opset): macOS 13 cannot compile it. There Relight uses
    /// its pseudo-depth fallback and the manager doesn't offer the download.
    public static var depthModelSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// Package directory of the installed depth model (nil where the OS can't run it).
    public static var installedDepthPackage: URL? {
        guard depthModelSupported, installedURL(depthAnything) != nil else { return nil }
        return modelsDirectory.appendingPathComponent("DepthAnythingV2SmallF16.mlpackage", isDirectory: true)
    }

    public static let all: [AIModelSpec] = [whisperTurbo, whisperSmall, demucs4, demucs6, qwen3_4b, lama]
        + (depthModelSupported ? [depthAnything] : []) + [clip]
    public static func spec(_ id: String) -> AIModelSpec? { all.first { $0.id == id } }

    /// Set by the UI test driver: scripts see an empty sandboxed models folder (deterministic "not installed" UX) unless
    /// they declare `"requires": {"models": [...]}`, which points this back at `userModelsDirectory`.
    public nonisolated(unsafe) static var directoryOverride: URL?
    /// True while a UI test runs on the empty sandboxed models folder (no `requires.models`): features that could
    /// otherwise pick up an OS model (Apple Intelligence) stay deterministic.
    public nonisolated(unsafe) static var isSandboxed = false

    /// ~/Library/Application Support/Valse/Models (override: `VALSE_MODELS_DIR`).
    public static var modelsDirectory: URL { directoryOverride ?? userModelsDirectory }

    public static var userModelsDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["VALSE_MODELS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return ValsePaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Installed file of a model, if any (sync, cheap: a few `stat`s).
    public static func installedURL(_ spec: AIModelSpec) -> URL? {
        let fm = FileManager.default
        if let parts = spec.parts {
            let dir = modelsDirectory.appendingPathComponent(spec.fileName, isDirectory: true)
            let ok = parts.allSatisfy { p in
                ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(p.path).path))?[.size] as? NSNumber)?.int64Value == p.bytes
            }
            return ok ? dir : nil
        }
        var candidates = [modelsDirectory.appendingPathComponent(spec.fileName)]
        if spec.kind == .whisper {
            // legacy "AI pack" location of the foundation (AIPacks/whisper/model.bin)
            candidates.append(ValsePaths.supportDirectory.appendingPathComponent("AIPacks/whisper/model.bin"))
        }
        for c in spec.companions {
            let u = modelsDirectory.appendingPathComponent(c.path)
            guard let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber, size.int64Value >= c.bytes else { return nil }
        }
        for u in candidates {
            if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber, size.int64Value > spec.bytes / 2 { return u }
        }
        return nil
    }

    /// Best installed speech model (turbo first).
    public static var installedWhisperModel: URL? { installedURL(whisperTurbo) ?? installedURL(whisperSmall) }

    /// UserDefaults key: the user chose the lighter speech model after running out of memory (BUG-CAPTION-ERRORS).
    public static let preferLighterWhisperKey = "speech.preferLighterModel"
    /// Speech model used for transcription: the lighter one when the user chose it and it is installed.
    public static var preferredWhisperModel: URL? {
        if UserDefaults.standard.bool(forKey: preferLighterWhisperKey), let u = installedURL(whisperSmall) { return u }
        return installedWhisperModel
    }
    /// The spec of `preferredWhisperModel` (the one to download again when it is damaged).
    public static var preferredWhisperSpec: AIModelSpec {
        if UserDefaults.standard.bool(forKey: preferLighterWhisperKey), installedURL(whisperSmall) != nil { return whisperSmall }
        return installedURL(whisperTurbo) != nil || installedURL(whisperSmall) == nil ? whisperTurbo : whisperSmall
    }
}

/// The whisper.cpp command-line runtime (`whisper-cli`, Metal). Like FFmpeg it runs as a separate process
/// (ARCHITECTURE §6.1): no C++ in the app binary, the model is unloaded when the job ends, a crash can't take the
/// editor down. Lookup: `VALSE_WHISPER_CLI`, the app bundle (`Contents/Helpers/whisper-cli`, built by
/// `scripts/build_whisper.sh`), Application Support/Valse/bin, Homebrew.
public enum WhisperRuntime {
    public static var cliURL: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["VALSE_WHISPER_CLI"], !e.isEmpty { c.append(e) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-cli").path)
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/whisper-cli").path)
        c.append(ValsePaths.supportDirectory.appendingPathComponent("bin/whisper-cli").path)
        c.append(ValsePaths.supportDirectory.appendingPathComponent("AIPacks/whisper/whisper-cli").path)
        // the user's real App Support (UI tests sandbox `supportDirectory`, but runtimes aren't settings)
        c.append(ValsePaths.defaultSupportDirectory.appendingPathComponent("bin/whisper-cli").path)
        c += ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return c.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static var isAvailable: Bool { cliURL != nil && ModelCatalog.installedWhisperModel != nil }
}

/// The llama.cpp one-shot runtime (`llama-completion`, Metal) for the local LLM. Sidecar like whisper: lookup
/// `VALSE_LLAMA_CLI`, `Contents/Helpers/llama-completion`, Application Support/Valse/bin (scripts/build_ai_runtimes.sh).
public enum LlamaRuntime {
    public static var cliURL: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["VALSE_LLAMA_CLI"], !e.isEmpty { c.append(e) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-completion").path)
        c.append(ValsePaths.supportDirectory.appendingPathComponent("bin/llama-completion").path)
        // the user's real App Support (UI tests sandbox `supportDirectory`, but runtimes aren't settings)
        c.append(ValsePaths.defaultSupportDirectory.appendingPathComponent("bin/llama-completion").path)
        return c.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    public static var model: URL? { ModelCatalog.installedURL(ModelCatalog.qwen3_4b) }
    public static var isAvailable: Bool { cliURL != nil && model != nil }

    /// One chat turn (system + user) → the reply text. Runs off the caller's actor; cancel = terminate.
    public static func respond(_ prompt: String, instructions: String, temperature: Double, maxTokens: Int = 700) async throws -> String {
        guard let cli = cliURL, let model else { throw AIToolError.modelMissing(ModelCatalog.qwen3_4b.id) }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["-m", model.path, "-sys", instructions, "-p", prompt, "-cnv", "-st", "--jinja", "-n", "\(maxTokens)",
                       "--temp", String(format: "%.2f", temperature), "-c", "8192", "--no-display-prompt"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let box = OutputBox()
        out.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }
        try p.run()
        try await withTaskCancellationHandler {
            while p.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        } onCancel: { p.terminate() }
        try Task.checkCancellation()
        out.fileHandleForReading.readabilityHandler = nil
        box.append(out.fileHandleForReading.readDataToEndOfFile())
        guard p.terminationStatus == 0 else { throw AIToolError.unavailable("llama exit \(p.terminationStatus)") }
        var text = String(decoding: box.data, as: UTF8.self)
        if let r = text.range(of: "[end of text]") { text = String(text[..<r.lowerBound]) }
        // Qwen3 hybrid models may emit an empty think block
        text = text.replacingOccurrences(of: "<think>\n\n</think>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
    }
}
