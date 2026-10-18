import Foundation

/// `Montage --imgdiff a.png b.png [--threshold 16] [--tolerance 0.005] [--diff out.png]` (scripts/imgdiff.sh).
/// Prints the `ImageDiff.Result` as JSON; exit 0 = match, 1 = differ, 2 = unreadable input.
nonisolated public enum ImageDiffCLI {
    public static func run(_ args: [String]) -> Int32 {
        var files: [String] = []
        var diff = ImageDiff()
        var diffOut: URL?
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--threshold": diff.threshold = next().flatMap(Int.init) ?? diff.threshold
            case "--tolerance": diff.tolerance = next().flatMap(Double.init) ?? diff.tolerance
            case "--diff": diffOut = next().map { URL(fileURLWithPath: $0) }
            default: files.append(a)
            }
            i += 1
        }
        guard files.count == 2 else {
            FileHandle.standardError.write(Data("usage: --imgdiff a.png b.png [--threshold N] [--tolerance F] [--diff out.png]\n".utf8))
            return 2
        }
        guard let r = diff.compare(URL(fileURLWithPath: files[0]), URL(fileURLWithPath: files[1]), diffURL: diffOut) else {
            FileHandle.standardError.write(Data("cannot read input images\n".utf8))
            return 2
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(r) { print(String(decoding: d, as: UTF8.self)) }
        return r.passed ? 0 : 1
    }
}
