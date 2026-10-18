import Foundation

public enum Metrics {
    public static let stack = "swift-native"
    public static func emit(_ metric: String, _ value: Double, _ unit: String) {
        let v = value.isFinite ? (value * 1000).rounded() / 1000 : -1
        print("{\"stack\":\"\(stack)\",\"metric\":\"\(metric)\",\"value\":\(v),\"unit\":\"\(unit)\"}")
        fflush(stdout)
    }
    public static func log(_ s: String) {
        FileHandle.standardError.write(("[montage] " + s + "\n").data(using: .utf8)!)
    }
    public static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let idx = min(s.count - 1, max(0, Int((p / 100 * Double(s.count - 1)).rounded())))
        return s[idx]
    }
}

/// Samples CPU% and RSS of a set of processes with `ps` (the app + VideoToolbox XPC helpers if any).
/// [bench harness fix] CPU% used to be the mean of `ps %cpu`, which on macOS is a decaying average that lags
/// (under-reports right after start-up). It is now cumulative CPU time (`ps time`) delta / wall time, like the
/// other prototypes (proc_pid_rusage / proc_pidinfo / ps time). 100 % = one core.
public final class ProcSampler: @unchecked Sendable {
    private var rss: [Double] = []
    private var running = false
    private let lock = NSLock()
    /// Helper processes that already existed before we started belong to other apps: ignore them.
    private let preexisting: Set<String>
    public private(set) var helperPidsSeen: Set<String> = []
    private var cpuStart: [String: Double] = [:]   // cumulative CPU s per pid at start()
    private var cpuLast: [String: Double] = [:]    // last cumulative CPU s seen per pid
    private var t0 = Date()
    public init() { preexisting = Set(ProcSampler.helperPids()) }

    static let helperNames = ["VTDecoderXPCService", "VTEncoderXPCService"]
    static func helperPids() -> [String] {
        helperNames.flatMap { run("/usr/bin/pgrep", ["-x", $0]).split(separator: "\n").map(String.init) }
    }

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.environment = ["LC_ALL": "C", "LANG": "C"]  // ps prints '12,3' under a French locale
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func parseCpuTime(_ s: Substring) -> Double {  // [[dd-]hh:]mm:ss.ss
        var days = 0.0, rest = s
        if let d = s.firstIndex(of: "-") { days = Double(s[..<d]) ?? 0; rest = s[s.index(after: d)...] }
        var sec = 0.0
        for part in rest.split(separator: ":") { sec = sec * 60 + (Double(part) ?? 0) }
        return sec + days * 86400
    }

    /// One snapshot: (pid -> cumulative cpu s, total rss MB)
    private func snapshot() -> ([String: Double], Double) {
        let helpers = ProcSampler.helperPids().filter { !preexisting.contains($0) }
        let pids = ["\(getpid())"] + helpers
        let out = ProcSampler.run("/bin/ps", ["-o", "pid=,time=,rss=", "-p", pids.joined(separator: ",")])
        var cpu: [String: Double] = [:], m = 0.0
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count >= 3 { cpu[String(f[0])] = ProcSampler.parseCpuTime(f[1]); m += (Double(f[2]) ?? 0) / 1024 }
        }
        lock.lock(); helperPidsSeen.formUnion(helpers); lock.unlock()
        return (cpu, m)
    }

    public func start(interval: Double = 0.5) {
        let (c0, _) = snapshot()
        lock.lock(); running = true; cpuStart = c0; cpuLast = c0; t0 = Date(); lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let r = running; lock.unlock()
                if !r { break }
                let (c, m) = snapshot()
                lock.lock(); rss.append(m); cpuLast.merge(c) { _, new in new }; lock.unlock()
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    /// (mean cpu %, mean rss MB, peak rss MB)
    public func stop() -> (Double, Double, Double) {
        let (cEnd, mEnd) = snapshot()
        lock.lock(); running = false
        cpuLast.merge(cEnd) { _, new in new }
        rss.append(mEnd)
        let r = rss, wall = Date().timeIntervalSince(t0)
        let used = cpuLast.reduce(0.0) { $0 + ($1.value - (cpuStart[$1.key] ?? 0)) }
        lock.unlock()
        guard !r.isEmpty, wall > 0 else { return (.nan, .nan, .nan) }
        return (used / wall * 100, r.reduce(0, +) / Double(r.count), r.max()!)
    }
}
