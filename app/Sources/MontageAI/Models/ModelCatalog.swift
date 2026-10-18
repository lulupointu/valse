import Foundation
import MontageCore

/// A downloadable on-device model. Models are never bundled or committed (`.gitignore` has `models/`); the user
/// downloads them once from the Model manager (Settings / the feature panel), or points Montage at an existing file.
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
    /// generation FR/EN (AI writer, AI clipper highlights, keywords) when Apple Intelligence is off. ~45 tok/s on M-series
    /// Metal, ~3 GB resident while a job runs (sidecar, unloaded afterwards).
    public static let qwen3_4b = AIModelSpec(
        id: "llm.qwen3-4b-instruct-q4km", kind: .llm, nameKey: "model.qwen3", descriptionKey: "model.qwen3.desc",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        bytes: 2_497_281_120, sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597", license: "Apache-2.0", runtimeMB: 3100)

    public static let all: [AIModelSpec] = [whisperTurbo, whisperSmall, demucs4, demucs6, qwen3_4b]
    public static func spec(_ id: String) -> AIModelSpec? { all.first { $0.id == id } }

    /// ~/Library/Application Support/Montage/Models (override: `MONTAGE_MODELS_DIR`).
    public static var modelsDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["MONTAGE_MODELS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return MontagePaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Installed file of a model, if any (sync, cheap: a few `stat`s).
    public static func installedURL(_ spec: AIModelSpec) -> URL? {
        let fm = FileManager.default
        var candidates = [modelsDirectory.appendingPathComponent(spec.fileName)]
        if spec.kind == .whisper {
            // legacy "AI pack" location of the foundation (AIPacks/whisper/model.bin)
            candidates.append(MontagePaths.supportDirectory.appendingPathComponent("AIPacks/whisper/model.bin"))
        }
        for u in candidates {
            if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber, size.int64Value > spec.bytes / 2 { return u }
        }
        return nil
    }

    /// Best installed speech model (turbo first).
    public static var installedWhisperModel: URL? { installedURL(whisperTurbo) ?? installedURL(whisperSmall) }
}

/// The whisper.cpp command-line runtime (`whisper-cli`, Metal). Like FFmpeg it runs as a separate process
/// (ARCHITECTURE §6.1): no C++ in the app binary, the model is unloaded when the job ends, a crash can't take the
/// editor down. Lookup: `MONTAGE_WHISPER_CLI`, the app bundle (`Contents/Helpers/whisper-cli`, built by
/// `scripts/build_whisper.sh`), Application Support/Montage/bin, Homebrew.
public enum WhisperRuntime {
    public static var cliURL: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["MONTAGE_WHISPER_CLI"], !e.isEmpty { c.append(e) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-cli").path)
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/whisper-cli").path)
        c.append(MontagePaths.supportDirectory.appendingPathComponent("bin/whisper-cli").path)
        c.append(MontagePaths.supportDirectory.appendingPathComponent("AIPacks/whisper/whisper-cli").path)
        c += ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return c.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static var isAvailable: Bool { cliURL != nil && ModelCatalog.installedWhisperModel != nil }
}

/// The llama.cpp one-shot runtime (`llama-completion`, Metal) for the local LLM. Sidecar like whisper: lookup
/// `MONTAGE_LLAMA_CLI`, `Contents/Helpers/llama-completion`, Application Support/Montage/bin (scripts/build_ai_runtimes.sh).
public enum LlamaRuntime {
    public static var cliURL: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["MONTAGE_LLAMA_CLI"], !e.isEmpty { c.append(e) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-completion").path)
        c.append(MontagePaths.supportDirectory.appendingPathComponent("bin/llama-completion").path)
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
