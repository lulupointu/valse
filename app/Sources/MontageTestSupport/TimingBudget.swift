import Foundation

/// Wall-clock budgets of unit tests (W14, DX-C). Several teams run builds/tests on one machine, so wall-clock numbers
/// depend on everything else running: the correctness suite (`scripts/test.sh`, every gate) never asserts them — it
/// emits the measurement (`metric(_:_:_:)`) and checks behaviour only. Budgets are ASSERTED only in perf runs
/// (`MONTAGE_PERF=1`: scripts/perf.sh holds every test slot, and `scripts/test.sh --perf`), against `budget × factor`
/// (default 3, `MONTAGE_TIMING_FACTOR`) and still skipped with a message when the machine is oversubscribed (1-min load
/// average above the core count). Precise budgets: bench/perf_thresholds.json — add a timing test to the `--filter` in
/// scripts/perf.sh. `MONTAGE_TIMING_ASSERT=1` forces assertion in any run (local investigation).
nonisolated public enum TimingBudget {
    public static var factor: Double {
        ProcessInfo.processInfo.environment["MONTAGE_TIMING_FACTOR"].flatMap(Double.init) ?? 3
    }

    /// Whether wall-clock budgets are asserted in this process (perf runs only).
    public static var enforced: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["MONTAGE_PERF"] == "1" || env["MONTAGE_TIMING_ASSERT"] == "1"
    }

    /// Limit to assert against for a nominal `budget`, or nil (= don't assert): outside perf runs, or under overload.
    public static func limit(_ budget: Double, _ what: String) -> Double? {
        guard enforced else { return nil }
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
