import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import ValseCore

/// Apple Foundation Models (macOS 26, on-device ~3B) behind a tiny text-in/text-out API, with graceful fallback:
/// callers check `isAvailable` and use a statistical path otherwise (no model download, never the network).
public enum OnDeviceLLM {
    /// Apple Foundation Models first; else the local Qwen model through llama.cpp (when downloaded).
    public static var isAvailable: Bool { hasFoundationModels || LlamaRuntime.isAvailable }

    public static var hasFoundationModels: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// One-shot generation. Throws `AIToolError.unavailable` when no local model is available.
    public static func respond(_ prompt: String, instructions: String, temperature: Double = 0.3, maxTokens: Int = 700) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), hasFoundationModels {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens))
            return r.content
        }
        #endif
        if LlamaRuntime.isAvailable { return try await LlamaRuntime.respond(prompt, instructions: instructions, temperature: temperature, maxTokens: maxTokens) }
        throw AIToolError.unavailable("no on-device language model")
    }
}
