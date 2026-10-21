import Foundation

/// "Character encoding" of imported caption files (MI-020, CapCut Local captions). `auto` = BOM / UTF-8 / Windows-1252
/// detection (`CaptionFile.decode`); the others force a charset for legacy files auto-detection reads wrongly
/// (Cyrillic, Central European, Japanese, Chinese, Korean subtitles).
public enum CaptionEncoding: String, CaseIterable, Sendable {
    case auto, utf8, utf16, windows1252, isoLatin1, windows1250, windows1251, macRoman, shiftJIS, gb18030, big5, eucKR

    public var nameKey: String { "captions.encoding.\(rawValue)" }

    var stringEncoding: String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .auto: return nil
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        case .windows1250: return .windowsCP1250
        case .windows1251: return .windowsCP1251
        case .macRoman: return .macOSRoman
        case .shiftJIS: return .shiftJIS
        case .gb18030: return cf(.GB_18030_2000)
        case .big5: return cf(.big5)
        case .eucKR: return cf(.EUC_KR)
        }
    }

    /// Decodes a caption file's bytes (a UTF-8 BOM is dropped whatever the choice).
    public func decode(_ data: Data) -> String? {
        guard let enc = stringEncoding else { return CaptionFile.decode(data) }
        var d = data
        if enc == .utf8, d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        guard var s = String(data: d, encoding: enc) else { return nil }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// The user's choice (Text ▸ Local captions ▸ Character encoding), persisted in the user defaults.
    public static let defaultsKey = "montage.captionEncoding"
    public static var current: CaptionEncoding {
        get { AppDefaults.store.string(forKey: defaultsKey).flatMap(CaptionEncoding.init(rawValue:)) ?? .auto }
        set { AppDefaults.store.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
