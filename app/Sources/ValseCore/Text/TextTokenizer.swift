import Foundation

/// Word segmentation shared by the caption model and the text renderer, so the i-th caption word timing always maps to
/// the i-th rendered word. Words are whitespace-separated tokens; scripts written without spaces (CJK, Thai…) use one
/// token per character.
public enum TextTokenizer {
    /// UTF-16 ranges of the words of `s`.
    public static func words(in s: String) -> [TextSpan] {
        var out: [TextSpan] = []
        var offset = 0
        var start: Int?
        for ch in s {
            let len = ch.utf16.count
            if ch.isWhitespace {
                if let st = start { out.append(TextSpan(st, offset - st)); start = nil }
            } else if isUnspacedScript(ch) {
                if let st = start { out.append(TextSpan(st, offset - st)); start = nil }
                out.append(TextSpan(offset, len))
            } else if start == nil {
                start = offset
            }
            offset += len
        }
        if let st = start { out.append(TextSpan(st, offset - st)) }
        return out
    }

    /// The words themselves.
    public static func tokens(_ s: String) -> [String] {
        let u = Array(s.utf16)
        return words(in: s).map { String(utf16CodeUnits: Array(u[$0.location..<$0.end]), count: $0.length) }
    }

    /// Han, Hiragana, Katakana and Thai are not space-separated.
    public static func isUnspacedScript(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x0E00...0x0E7F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
