import Foundation

/// Wall-clock budgets of unit tests (W14, DX-C). Several teams run builds/tests on one machine, so wall-clock numbers
/// depend on everything else running: the correctness suite (`scripts/test.sh`, every gate) never asserts them — it
/// emits the measurement (`metric(_:_:_:)`) and checks behaviour only. Budgets are ASSERTED only in perf runs
/// (`VALSE_PERF=1`: scripts/perf.sh holds every test slot, and `scripts/test.sh --perf`), against `budget × factor`
/// (default 3, `VALSE_TIMING_FACTOR`) and still skipped with a message when the machine is oversubscribed (1-min load
/// average above the core count). Precise budgets: bench/perf_thresholds.json — add a timing test to the `--filter` in
/// scripts/perf.sh (run by every check_clean --ui gate). `VALSE_TIMING_ASSERT=1` forces assertion in any run.
/// Costs that can be measured as thread CPU / GPU time keep a gross bound in the correctness suite (`cpuLimit`).
nonisolated public enum TimingBudget {
    public static var factor: Double {
        ProcessInfo.processInfo.environment["VALSE_TIMING_FACTOR"].flatMap(Double.init) ?? 3
    }

    /// Whether wall-clock budgets are asserted in this process (perf runs only).
    public static var enforced: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["VALSE_PERF"] == "1" || env["VALSE_TIMING_ASSERT"] == "1"
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

    /// Load-robust GROSS bound for a cost measured as thread CPU time (`CLOCK_THREAD_CPUTIME_ID`, `threadCPUms`) or
    /// GPU command-buffer time — always asserted, in every gate: other processes don't add to the CPU time of the
    /// measuring thread (preemption excluded). Limit = `budget × cpuFactor` (default 4, `VALSE_CPU_TIMING_FACTOR`:
    /// a loaded machine can run the thread on an efficiency core, ~2–3× slower per instruction).
    public static func cpuLimit(_ budget: Double) -> Double { budget * cpuFactor }
    public static var cpuFactor: Double {
        ProcessInfo.processInfo.environment["VALSE_CPU_TIMING_FACTOR"].flatMap(Double.init) ?? 4
    }

    /// CPU time (ms) the calling thread spends in `body` (excludes time the thread is preempted).
    public static func threadCPUms<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let r = try body()
        return (r, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6)
    }

    /// 1-minute load average per CPU core.
    public static func loadPerCore() -> Double {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) > 0 else { return 0 }
        // VALSE_PERF_CORES: the core count of perf.sh's load rule (also forces the "loaded" branch in its self-check)
        let cores = ProcessInfo.processInfo.environment["VALSE_PERF_CORES"].flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount
        return l[0] / Double(max(1, cores))
    }

    /// JSON metric line picked up by scripts/perf.sh (same format as the perf smoke tests).
    public static func metric(_ name: String, _ value: Double, _ unit: String) {
        print("{\"stack\":\"valse\",\"metric\":\"\(name)\",\"value\":\((value * 100).rounded() / 100),\"unit\":\"\(unit)\"}")
    }
}
