import Foundation

/// Animated counter text (TX-039, CapCut "number / date counter" templates): the clip's displayed string counts from
/// `from` to `to` over the first `countFraction` of the clip, then holds. Evaluated per frame by `FrameEvaluator`
/// (pure, deterministic: same string in preview and export).
/// - number: `prefix` + value with `decimals` and an optional thousands separator + `suffix` (e.g. "0 %" → "100 %").
/// - timer: seconds shown as m:ss (h:mm:ss past an hour), `decimals` adds hundredths — counts down when `to < from`.
/// - date: days since 2001-01-01 (UTC), shown in `dateFormat`.
public struct TextCounter: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case number, timer, date
        public var nameKey: String { "counter.kind.\(rawValue)" }
    }
    public enum DateFormat: String, Codable, Sendable, CaseIterable {
        /// 31/12/2026 · 12/31/2026 · 2026-12-31 · 31 December 2026 (localized month) · 2026 (year only)
        case dmy, mdy, ymd, long, year
        public var nameKey: String { "counter.date.\(rawValue)" }
    }

    public var kind: Kind
    public var from: Double
    public var to: Double
    public var decimals: Int
    public var thousandsSeparator: Bool
    public var prefix: String
    public var suffix: String
    /// Ease-out (fast start, slow landing) instead of linear counting.
    public var easeOut: Bool
    /// Part of the clip (0.05…1) during which the value counts; the rest holds the end value.
    public var countFraction: Double
    public var dateFormat: DateFormat

    public init(kind: Kind = .number, from: Double = 0, to: Double = 100, decimals: Int = 0, thousandsSeparator: Bool = true,
                prefix: String = "", suffix: String = "", easeOut: Bool = true, countFraction: Double = 0.8,
                dateFormat: DateFormat = .dmy) {
        self.kind = kind; self.from = from; self.to = to; self.decimals = decimals; self.thousandsSeparator = thousandsSeparator
        self.prefix = prefix; self.suffix = suffix; self.easeOut = easeOut; self.countFraction = countFraction
        self.dateFormat = dateFormat
    }

    /// Defaults when switching kind in the inspector.
    public static func defaults(_ kind: Kind) -> TextCounter {
        switch kind {
        case .number: return TextCounter()
        case .timer: return TextCounter(kind: .timer, from: 10, to: 0, easeOut: false, countFraction: 1)
        case .date: return TextCounter(kind: .date, from: day(2000, 1, 1), to: day(2026, 1, 1), countFraction: 0.8)
        }
    }

    /// Days since 2001-01-01 UTC of a calendar date.
    public static func day(_ y: Int, _ m: Int, _ d: Int) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date(timeIntervalSinceReferenceDate: 0)
        return (date.timeIntervalSinceReferenceDate / 86_400).rounded()
    }

    /// Counting progress 0…1 at clip-local `t` of a clip lasting `duration` (eased when `easeOut`).
    public func progress(at t: Time, duration: Time) -> Double {
        let span = max(duration.seconds * min(max(countFraction, 0.05), 1), 1e-6)
        let p = min(max(t.seconds / span, 0), 1)
        return easeOut ? 1 - pow(1 - p, 3) : p
    }

    /// Displayed steps per unit: 1, 10^decimals for numbers, 100 for timers with hundredths.
    var stepsPerUnit: Double {
        kind == .number ? pow(10, Double(min(max(decimals, 0), 4))) : (kind == .timer && decimals > 0 ? 100 : 1)
    }

    /// Number of distinct values shown, `from` and `to` included.
    public var valueCount: Int { Int((abs(to - from) * stepsPerUnit + 1e-6).rounded(.down)) + 1 }

    /// Value at progress `p` (OB-01, owner rule): the count span is split into `valueCount` equal buckets, one per
    /// displayed value, so 1 → 10 over 100 frames shows each number for 10 frames and `to` holds the last bucket.
    /// Easing bends `p` before bucketing (linear = equal buckets).
    public func value(progress p: Double) -> Double {
        let n = valueCount
        let k = min(Int((min(max(p, 0), 1) * Double(n) + 1e-9).rounded(.down)), n - 1)
        if k == n - 1 { return to }
        let q = stepsPerUnit
        return (from * q + (to >= from ? 1 : -1) * Double(k)) / q
    }

    public func string(at t: Time, duration: Time, language: String = L10n.shared.language) -> String {
        prefix + format(value(progress: progress(at: t, duration: duration)), language: language) + suffix
    }

    public func format(_ v: Double, language: String) -> String {
        switch kind {
        case .number:
            let fr = language.hasPrefix("fr")
            let d = min(max(decimals, 0), 4)
            let neg = v < 0
            let s = String(format: "%.\(d)f", abs(v))
            let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
            var int = parts[0]
            if thousandsSeparator, int.count > 3 {
                let sep = fr ? "\u{202F}" : ","
                var out: [String] = []
                while int.count > 3 { out.insert(String(int.suffix(3)), at: 0); int.removeLast(3) }
                out.insert(int, at: 0)
                int = out.joined(separator: sep)
            }
            return (neg ? "−" : "") + int + (parts.count > 1 ? (fr ? "," : ".") + parts[1] : "")
        case .timer:
            let total = abs(v)
            let whole = Int(total.rounded(.down))
            let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
            var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            if decimals > 0 { out += String(format: ".%02d", Int(((total - Double(whole)) * 100 + 1e-6).rounded(.down)) % 100) }
            return out
        case .date:
            let date = Date(timeIntervalSinceReferenceDate: v.rounded() * 86_400)
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: language)
            f.calendar = Calendar(identifier: .gregorian)
            switch dateFormat {
            case .dmy: f.dateFormat = "dd/MM/yyyy"
            case .mdy: f.dateFormat = "MM/dd/yyyy"
            case .ymd: f.dateFormat = "yyyy-MM-dd"
            case .long: f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
            case .year: f.dateFormat = "yyyy"
            }
            return f.string(from: date)
        }
    }
}
