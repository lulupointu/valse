import Foundation

/// Tiny path language over JSON-like values (`[String: Any]` / `[Any]` / scalars) for UI test assertions.
///
/// `tracks.main.clips.count`, `selection.0`, `selectedClips.0.duration`, `undo.depth`. Segments: dictionary keys,
/// array indices (negative = from the end), `count` (array/dictionary/string length), `first`, `last`.
nonisolated public enum JSONPath {
    public static func get(_ root: Any, _ path: String) -> Any? {
        var cur: Any? = root
        for seg in path.split(separator: ".").map(String.init) where !seg.isEmpty {
            guard let c = cur else { return nil }
            if let d = c as? [String: Any] {
                if let v = d[seg] { cur = v } else if seg == "count" { cur = d.count } else { return nil }
            } else if let a = c as? [Any] {
                switch seg {
                case "count": cur = a.count
                case "first": cur = a.first
                case "last": cur = a.last
                default:
                    guard let i = Int(seg) else { return nil }
                    let j = i < 0 ? a.count + i : i
                    cur = a.indices.contains(j) ? a[j] : nil
                }
            } else if let s = c as? String, seg == "count" {
                cur = s.count
            } else {
                return nil
            }
        }
        return cur
    }

    /// Evaluates one expectation (`{"path": "...", "equals": …}` etc.). Returns nil when it holds, else a message.
    public static func check(_ root: Any, _ spec: [String: Any]) -> String? {
        guard let path = spec["path"] as? String else { return "expect: missing \"path\"" }
        let v = get(root, path)
        let tol = (spec["tolerance"] as? NSNumber)?.doubleValue ?? 1e-6
        func show(_ x: Any?) -> String {
            guard let x else { return "nil" }
            if let d = try? JSONSerialization.data(withJSONObject: x, options: [.fragmentsAllowed, .sortedKeys]),
               let s = String(data: d, encoding: .utf8) { return s.count > 300 ? String(s.prefix(300)) + "…" : s }
            return "\(x)"
        }
        func fail(_ what: String) -> String { "\(path): expected \(what), got \(show(v))" }
        for (op, expected) in spec where !["path", "tolerance", "message"].contains(op) {
            switch op {
            case "equals":
                if !equal(v, expected, tol) { return fail("== \(show(expected))") }
            case "notEquals":
                if equal(v, expected, tol) { return fail("!= \(show(expected))") }
            case "exists":
                let want = (expected as? Bool) ?? true
                if (v != nil && !(v is NSNull)) != want { return fail(want ? "to exist" : "not to exist") }
            case "gt", "gte", "lt", "lte":
                guard let a = number(v), let b = number(expected) else { return fail("a number \(op) \(show(expected))") }
                let ok = op == "gt" ? a > b : op == "gte" ? a >= b - tol : op == "lt" ? a < b : a <= b + tol
                if !ok { return fail("\(op) \(show(expected))") }
            case "approx":
                guard let a = number(v), let b = number(expected) else { return fail("≈ \(show(expected))") }
                let t = (spec["tolerance"] as? NSNumber)?.doubleValue ?? 1e-3
                if abs(a - b) > t { return fail("≈ \(show(expected)) ± \(t)") }
            case "contains":
                if let s = v as? String, let e = expected as? String { if !s.contains(e) { return fail("to contain \(show(e))") } }
                else if let a = v as? [Any] { if !a.contains(where: { equal($0, expected, tol) }) { return fail("to contain \(show(expected))") } }
                else if let d = v as? [String: Any], let k = expected as? String { if d[k] == nil { return fail("to contain key \(k)") } }
                else { return fail("a string/array containing \(show(expected))") }
            case "notContains":
                if let s = v as? String, let e = expected as? String { if s.contains(e) { return fail("not to contain \(show(e))") } }
                else if let a = v as? [Any] { if a.contains(where: { equal($0, expected, tol) }) { return fail("not to contain \(show(expected))") } }
                else if let d = v as? [String: Any], let k = expected as? String { if d[k] != nil { return fail("not to contain key \(k)") } }
                else if v != nil && !(v is NSNull) { return fail("a string/array not containing \(show(expected))") }
            case "count":
                let n = (v as? [Any])?.count ?? (v as? [String: Any])?.count ?? (v as? String)?.count
                if n == nil || number(expected).map({ Double(n!) != $0 }) ?? true { return fail("count \(show(expected))") }
            default:
                return "expect: unknown operator \(op)"
            }
        }
        return nil
    }

    static func number(_ x: Any?) -> Double? {
        (x as? NSNumber)?.doubleValue
    }

    static func equal(_ a: Any?, _ b: Any?, _ tol: Double) -> Bool {
        if a == nil || a is NSNull { return b == nil || b is NSNull }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) <= tol }
        if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1, tol) } }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return x.count == y.count && x.allSatisfy { k, v in y[k] != nil && equal(v, y[k], tol) }
        }
        return false
    }
}
