import Foundation

/// How times are shown and typed (Settings ▸ Edit ▸ Time code, TL-037 / SE-008).
public enum TimecodeStyle: String, Codable, Sendable, CaseIterable {
    /// HH:MM:SS:FF (CapCut default "HH:MM:SS+frame").
    case frames
    /// HH:MM:SS.mmm (milliseconds).
    case seconds
    public var nameKey: String { "timecode.style.\(rawValue)" }
}

/// App-wide timecode display preferences. Set from `AppSettings` at launch / on Save; thread-safe.
public struct TimecodeDisplay: Sendable, Equatable {
    public var style: TimecodeStyle = .frames
    /// Drop-frame counting (HH:MM:SS;FF) for 29.97 / 59.94 fps projects.
    public var dropFrame = false
    public init(style: TimecodeStyle = .frames, dropFrame: Bool = false) { self.style = style; self.dropFrame = dropFrame }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = TimecodeDisplay()
    public static var current: TimecodeDisplay {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }
}

/// Timecode formatting and parsing (CapCut shows `00:00:12:05`). Frame counts use the nominal (rounded) rate; with
/// drop-frame on and an NTSC rate (29.97 / 59.94) frame numbers 0–1 (0–3 at 59.94) are skipped every minute except
/// every tenth, so the label stays in step with the wall clock (SMPTE 12M).
public enum Timecode {
    /// True for 29.97 / 59.94 (the rates drop-frame applies to).
    public static func supportsDropFrame(_ rate: FrameRate) -> Bool {
        rate.denominator == 1001 && (rate.numerator == 30000 || rate.numerator == 60000)
    }

    /// Formats with the global display preferences (`TimecodeDisplay.current`).
    public static func display(_ t: Time, rate: FrameRate) -> String {
        let d = TimecodeDisplay.current
        return string(t, rate: rate, style: d.style, dropFrame: d.dropFrame)
    }

    public static func string(_ t: Time, rate: FrameRate, showFrames: Bool = true) -> String {
        string(t, rate: rate, style: .frames, dropFrame: false, showFrames: showFrames)
    }

    public static func string(_ t: Time, rate: FrameRate, style: TimecodeStyle, dropFrame: Bool, showFrames: Bool = true) -> String {
        let neg = t.ticks < 0
        let a = Time(ticks: abs(t.ticks))
        var base: String
        switch style {
        case .seconds:
            let ms = Int64((a.seconds * 1000).rounded(.down))
            let total = ms / 1000
            base = String(format: "%02lld:%02lld:%02lld", total / 3600, (total / 60) % 60, total % 60)
            if showFrames { base += String(format: ".%03lld", ms % 1000) }
        case .frames:
            let fpsInt = max(Int64(rate.fps.rounded()), 1)
            var frames = rate.frame(containing: a)
            let df = dropFrame && supportsDropFrame(rate)
            if df { frames = dropFrameDisplayCount(frames, fpsInt: fpsInt) }
            let totalSeconds = frames / fpsInt, ff = frames % fpsInt
            let h = totalSeconds / 3600, m = (totalSeconds / 60) % 60, s = totalSeconds % 60
            base = showFrames ? String(format: "%02lld:%02lld:%02lld%@%02lld", h, m, s, df ? ";" : ":", ff)
                              : String(format: "%02lld:%02lld:%02lld", h, m, s)
        }
        return neg ? "-" + base : base
    }

    /// Frames dropped per minute for a nominal rate (2 at 30, 4 at 60).
    static func dropsPerMinute(_ fpsInt: Int64) -> Int64 { fpsInt / 15 }

    /// Real frame index → the frame count the drop-frame label shows.
    static func dropFrameDisplayCount(_ frame: Int64, fpsInt: Int64) -> Int64 {
        let drop = dropsPerMinute(fpsInt)
        let per10 = fpsInt * 600 - drop * 9, perMin = fpsInt * 60 - drop
        let d = frame / per10, m = frame % per10
        return frame + drop * 9 * d + (m > drop ? drop * ((m - drop) / perMin) : 0)
    }

    /// Typed timecode → time, or nil when it can't be read. Accepts:
    /// - `HH:MM:SS:FF` / `MM:SS:FF` / `SS:FF` (`;` or `.` also separate frames; fields are read from the right),
    /// - digits only, right-aligned pairs like an NLE (`1005` = 00:00:10:05, `30000` = 00:03:00:00),
    /// - in the seconds style `HH:MM:SS.mmm`, `MM:SS`, `12.5` (seconds),
    /// - a leading `+` / `-` makes it relative to `relativeTo` (e.g. `+10` = 10 frames later, `-1:00` = 1 s earlier).
    public static func parse(_ text: String, rate: FrameRate, style: TimecodeStyle = .frames, dropFrame: Bool = false,
                             relativeTo base: Time? = nil) -> Time? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var sign: Int64 = 0
        if let f = s.first, f == "+" || f == "-" { sign = f == "+" ? 1 : -1; s.removeFirst() }
        guard !s.isEmpty else { return nil }
        guard let t = parseAbsolute(s, rate: rate, style: style, dropFrame: dropFrame) else { return nil }
        if sign != 0 {
            guard let base else { return sign < 0 ? nil : t }
            return Time(ticks: base.ticks + sign * t.ticks)
        }
        return t
    }

    private static func parseAbsolute(_ s: String, rate: FrameRate, style: TimecodeStyle, dropFrame: Bool) -> Time? {
        let allowed = CharacterSet(charactersIn: "0123456789:;.,")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let fpsInt = max(Int64(rate.fps.rounded()), 1)
        if style == .seconds {
            // HH:MM:SS.mmm — fractional part = seconds
            let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var total = 0.0
            for (i, p) in parts.enumerated() {
                guard let v = Double(p.isEmpty ? "0" : p), v >= 0 else { return nil }
                if i < parts.count - 1, v != v.rounded() { return nil }
                total = total * 60 + v
            }
            return Time(seconds: total)
        }
        var fields: [Int64]
        if s.allSatisfy(\.isNumber) {
            // right-aligned digit pairs: …HHMMSSFF
            guard s.count <= 8 else { return nil }
            let padded = String(repeating: "0", count: (2 - s.count % 2) % 2) + s
            fields = stride(from: 0, to: padded.count, by: 2).map {
                let a = padded.index(padded.startIndex, offsetBy: $0)
                return Int64(padded[a..<padded.index(a, offsetBy: 2)])!
            }
        } else {
            let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { ":;.,".contains($0) })
            guard (1...4).contains(parts.count) else { return nil }
            var out: [Int64] = []
            for p in parts { guard let v = Int64(p.isEmpty ? "0" : p) else { return nil }; out.append(v) }
            fields = out
        }
        while fields.count < 4 { fields.insert(0, at: 0) }
        let (h, m, sec, f) = (fields[0], fields[1], fields[2], fields[3])
        var frames = ((h * 60 + m) * 60 + sec) * fpsInt + f
        if dropFrame && supportsDropFrame(rate) {
            let totalMinutes = h * 60 + m
            frames -= dropsPerMinute(fpsInt) * (totalMinutes - totalMinutes / 10)
        }
        return rate.time(ofFrame: frames)
    }

    /// Compact duration label for clips, e.g. "3.2s" or "1:05".
    public static func shortDuration(_ t: Time) -> String {
        let s = t.seconds
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
