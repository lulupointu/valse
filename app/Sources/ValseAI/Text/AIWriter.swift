import Foundation
import NaturalLanguage
import ValseCore

/// AI writer (AI-029, UX_AI §11): topic + requirements + script type → a short video script, then Make longer /
/// Make shorter / Rewrite, through `OnDeviceLLM` (Apple Foundation Models, else the local Qwen model). The script lands
/// on the timeline as caption clips (`CaptionOps.addCaptionTrack`, origin `.script`), split per sentence at a
/// reading pace, or as one clip.
public enum AIWriter {
    public enum Kind: String, CaseIterable, Sendable {
        case talking, ad, inspirational, meme, romantic, tutorial
        public var nameKey: String { "writer.kind.\(rawValue)" }
        var promptEN: String {
            switch self {
            case .talking: return "a talking script read to camera"
            case .ad: return "a punchy product ad"
            case .inspirational: return "an inspirational motivational script"
            case .meme: return "a funny meme-style script"
            case .romantic: return "a romantic, tender script"
            case .tutorial: return "a clear step-by-step tutorial script"
            }
        }
    }
    public enum Revision: String, Sendable { case longer, shorter, rewrite }

    public static var isAvailable: Bool { OnDeviceLLM.isAvailable }

    static func instructions(language: String) -> String {
        let lang = language == "fr" ? "French" : (language == "en" ? "English" : "the language of the topic")
        return "You write short scripts for social videos. Write in \(lang). Reply with the script text only: no title, no stage directions, no brackets, no markdown, no emojis. Short sentences that are easy to read as captions."
    }

    /// New script for a topic.
    public static func write(topic: String, requirements: String, kind: Kind, language: String) async throws -> String {
        var prompt = "Write \(kind.promptEN) about: \(topic.trimmingCharacters(in: .whitespacesAndNewlines))."
        let req = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += req.isEmpty ? " About 80 to 120 words." : " Requirements: \(req)"
        return clean(try await OnDeviceLLM.respond(prompt, instructions: instructions(language: language), temperature: 0.7))
    }

    /// Make longer / shorter / rewrite an existing script.
    public static func revise(_ script: String, _ r: Revision, language: String) async throws -> String {
        let ask: String
        switch r {
        case .longer: ask = "Make this script about 50% longer, adding relevant content and keeping its tone:"
        case .shorter: ask = "Shorten this script to about half its length, keeping the key message:"
        case .rewrite: ask = "Rewrite this script with fresh wording, same meaning and length:"
        }
        return clean(try await OnDeviceLLM.respond("\(ask)\n\n\(script)", instructions: instructions(language: language), temperature: 0.7))
    }

    /// Removes the decorations small models like to add (markdown, quotes, bracketed directions, "Script:" headers).
    public static func clean(_ s: String) -> String {
        var lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        lines = lines.map { l in
            var t = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(voix|voice|music|musique|pause)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            return t.trimmingCharacters(in: .whitespaces)
        }
        lines.removeAll { $0.isEmpty || $0.lowercased().hasPrefix("script") && $0.hasSuffix(":") || $0.hasPrefix("---") }
        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
    }

    /// Caption segments for a script starting at `start` (timeline seconds): one per sentence (long sentences split
    /// at commas to ≤ 2 caption lines), duration from a ~15 characters/s reading pace (≥ 1.2 s); `split: false` = one.
    public static func segments(_ script: String, start: Double, split: Bool = true) -> [CaptionSegment] {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        func dur(_ s: String) -> Double { max(1.2, Double(s.count) / 15) }
        guard split else { return [CaptionSegment(text: text, start: start, end: start + dur(text))] }
        var pieces: [String] = []
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count <= 56 { if !s.isEmpty { pieces.append(s) } } else {
                // ≤ 2 lines of 28: break at commas, else at word boundaries
                var cur = ""
                for w in s.split(separator: " ") {
                    let cand = cur.isEmpty ? String(w) : cur + " " + w
                    if cand.count > 56 || (cur.count > 20 && cur.hasSuffix(",")) { pieces.append(cur); cur = String(w) } else { cur = cand }
                }
                if !cur.isEmpty { pieces.append(cur) }
            }
            return true
        }
        var t = start
        return pieces.map { p in
            let d = dur(p)
            defer { t += d }
            return CaptionSegment(text: p, start: t, end: t + d)
        }
    }
}
