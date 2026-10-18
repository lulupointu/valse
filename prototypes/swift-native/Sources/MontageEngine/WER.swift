import Foundation

/// Rough word error rate (Levenshtein over normalized words).
public enum WER {
    public static func normalize(_ s: String) -> [String] {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let cleaned = String(lowered.map { ($0.isLetter || $0.isNumber || $0 == "'") ? $0 : " " })
        // split elisions (l'endroit → l' endroit) so both sides tokenize alike
        return cleaned.replacingOccurrences(of: "'", with: "' ").split(separator: " ").map(String.init)
    }

    public static func compute(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count), cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            if h.count > 0 {
                for j in 1...h.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
                }
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
