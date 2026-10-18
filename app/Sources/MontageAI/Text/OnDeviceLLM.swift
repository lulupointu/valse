import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif
import MontageCore

/// Apple Foundation Models (macOS 26, on-device ~3B) behind a tiny text-in/text-out API, with graceful fallback:
/// callers check `isAvailable` and use a statistical path otherwise (no model download, never the network).
public enum OnDeviceLLM {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// One-shot generation. Throws `AIToolError.unavailable` when the system model isn't available.
    public static func respond(_ prompt: String, instructions: String, temperature: Double = 0.3) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return r.content
        }
        #endif
        throw AIToolError.unavailable("Apple Intelligence model unavailable")
    }
}

/// Keyword extraction for "Highlight keywords" (TX-022 / AI-004): the LLM picks the words a viewer should notice;
/// fallback = nouns/proper nouns ranked by frequency × rarity (TF-IDF over the captions), stop-words removed.
public enum KeywordExtractor {
    public static func keywords(_ captions: [String], language: String, maxCount: Int? = nil) async -> Set<String> {
        let limit = maxCount ?? max(1, captions.count / 2)
        if OnDeviceLLM.isAvailable {
            let prompt = captions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let instr = "You pick keywords in video captions. Reply with at most \(limit) single words copied exactly from the captions, comma separated, nothing else. Prefer nouns, names, numbers and strong verbs."
            if let r = try? await OnDeviceLLM.respond(prompt, instructions: instr) {
                let all = Set(captions.flatMap { CaptionText.tokens($0).map(CaptionText.normalize) })
                let picked = r.split(whereSeparator: { ",\n;".contains($0) }).map { CaptionText.normalize(String($0)) }.filter { all.contains($0) }
                if !picked.isEmpty { return Set(picked.prefix(limit)) }
            }
        }
        return statistical(captions, language: language, limit: limit)
    }

    static let stop: Set<String> = ["le", "la", "les", "un", "une", "des", "de", "du", "et", "en", "à", "au", "aux", "ce", "ces", "cette", "est",
        "sont", "pour", "par", "sur", "dans", "avec", "que", "qui", "nous", "vous", "ils", "elles", "il", "elle", "on", "je", "tu", "pas", "plus",
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "be", "it", "this", "that", "we", "you", "they",
        "i", "he", "she", "at", "by", "from", "as", "not", "so", "but", "if", "then", "your", "our", "their", "my", "will", "can", "just"]

    public static func statistical(_ captions: [String], language: String, limit: Int) -> Set<String> {
        var tf: [String: Int] = [:], df: [String: Int] = [:]
        var nouns = Set<String>()
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        for c in captions {
            tagger.string = c
            var seen = Set<String>()
            tagger.enumerateTags(in: c.startIndex..<c.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, r in
                let w = CaptionText.normalize(String(c[r]))
                guard w.count >= 4 || w.allSatisfy(\.isNumber), !stop.contains(w) else { return true }
                tf[w, default: 0] += 1
                if seen.insert(w).inserted { df[w, default: 0] += 1 }
                if tag == .noun || tag == .personalName || tag == .placeName || tag == .organizationName || tag == .number { nouns.insert(w) }
                return true
            }
        }
        let n = Double(max(captions.count, 1))
        let scored = tf.map { w, f -> (String, Double) in
            let idf = log(1 + n / Double(df[w] ?? 1))
            return (w, Double(f) * idf * (nouns.contains(w) ? 2 : 1) + Double(w.count) * 0.01)
        }.sorted { $0.1 > $1.1 }
        return Set(scored.prefix(limit).map(\.0))
    }
}
