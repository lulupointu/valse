import Foundation

/// Load-aware wall-clock budgets for the unit suite (W14). Several teams run builds/tests on one machine (load 100+),
/// so exact budgets flake and block unrelated merges. The unit suite only catches GROSS regressions: the limit is
/// `budget × factor` (default 3, `MONTAGE_TIMING_FACTOR`), and the assertion is skipped with a message when the
/// machine is oversubscribed (1-min load average above the core count). Precise budgets live in scripts/perf.sh
/// (exclusive slot, bench/perf_thresholds.json): emit the measurement with `metric(_:_:_:)` and add a threshold there.
nonisolated public enum TimingBudget {
    public static var factor: Double {
        ProcessInfo.processInfo.environment["MONTAGE_TIMING_FACTOR"].flatMap(Double.init) ?? 3
    }

    /// Limit to assert against for a nominal `budget`, or nil (= don't assert; a message is printed) under overload.
    public static func limit(_ budget: Double, _ what: String) -> Double? {
        let load = loadPerCore()
        if load > 1 {
            print("⚠️ timing check '\(what)' skipped: machine load \(String(format: "%.2f", load))/core (precise budget is in scripts/perf.sh)")
            return nil
        }
        return budget * factor
    }

    /// 1-minute load average per CPU core.
    public static func loadPerCore() -> Double {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) > 0 else { return 0 }
        return l[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// JSON metric line picked up by scripts/perf.sh (same format as the perf smoke tests).
    public static func metric(_ name: String, _ value: Double, _ unit: String) {
        print("{\"stack\":\"montage\",\"metric\":\"\(name)\",\"value\":\((value * 100).rounded() / 100),\"unit\":\"\(unit)\"}")
    }
}
