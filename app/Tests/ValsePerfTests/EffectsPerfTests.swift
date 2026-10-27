import Testing
import Foundation
import ValseCore
import ValseEffects
import ValseEngine
import ValseTestSupport

/// Renders every effect / filter / adjustment once at 1080p and flags any over the real-time budget.
///
/// Budget: an effect must cost ≤ `budgetMs` of GPU time per 1080p frame on this machine. The default (3.5 ms on an
/// M1 Pro) maps to ≈ 7–8 ms on a base M1/M2 Air GPU, which keeps a 30 fps preview with decode + compositing.
/// Always runs (≈ 3 s): every entry must render; the GPU budget itself is asserted only in perf runs (`VALSE_PERF=1`,
/// exact budget; `VALSE_TIMING_ASSERT=1`: lenient ×2) — GPU timings depend on whatever else uses the GPU (TimingBudget).
/// `VALSE_FX_BUDGET_MS` overrides it. Prints the slowest entries.
@Suite(.serialized) struct EffectsPerfTests {
    static let strict = ProcessInfo.processInfo.environment["VALSE_PERF"] == "1"
    static let budgetMs = Double(ProcessInfo.processInfo.environment["VALSE_FX_BUDGET_MS"] ?? "") ?? 3.5
    /// Extra measurements (5 command buffers each) of an entry first measured over the limit.
    static let remeasures = 5

    @Test func everyEffectFitsTheRealTimeBudget() {
        let r = EffectPreviewRenderer.shared
        let all = Registries.effects.all.filter { $0.id.hasPrefix("valse.") && $0.category != .canvas }
        var times: [(String, Double)] = []
        for d in all {
            guard let ms = r.gpuMilliseconds(d, width: 1920, height: 1080, time: 1.1, runs: 3) else {
                Issue.record("\(d.id): could not render"); continue
            }
            times.append((d.id, ms))
        }
        let limit = Self.budgetMs * (Self.strict ? 1 : 2)
        // GPU time of a command buffer includes the time the GPU spends on OTHER processes' work interleaved with it
        // (other checkouts' tests / apps share the GPU; the CPU load average doesn't see it: lightRays measured 3.73 ms
        // vs its usual 1.5-1.9 with 3 agents running). Contention only ever ADDS time, so an entry over the limit is
        // re-measured a few times, spread over ~1 s, and keeps its minimum: a real regression stays over every time.
        times = times.map { id, ms in
            guard ms > limit, let d = all.first(where: { $0.id == id }) else { return (id, ms) }
            var best = ms
            for _ in 0..<Self.remeasures where best > limit {
                Thread.sleep(forTimeInterval: 0.2)
                if let again = r.gpuMilliseconds(d, width: 1920, height: 1080, time: 1.1, runs: 5) { best = min(best, again) }
            }
            if best < ms { print(String(format: "  re-measured %@: %.2f → %.2f ms (GPU contention)", id, ms, best)) }
            return (id, best)
        }
        times.sort { $0.1 > $1.1 }
        print("effects perf (1080p GPU ms, budget \(Self.budgetMs), limit \(limit)), slowest:")
        for (id, ms) in times.prefix(15) { print(String(format: "  %6.2f  %@", ms, id)) }
        let total = times.reduce(0) { $0 + $1.1 }
        print(String(format: "  mean %.2f ms over %d entries", total / Double(max(times.count, 1)), times.count))
        // lenient mode follows TimingBudget: not asserted in the correctness suite, nor while the machine is oversubscribed
        // strict (perf runs) and lenient budgets follow TimingBudget's load rule (GPU contention from other processes is
        // real); the gross x4 GPU-time bound below always gates
        let overloaded = TimingBudget.limit(Self.budgetMs, "effects 1080p GPU budget") == nil
        for (id, ms) in times where ms > limit && !overloaded {
            Issue.record("\(id) costs \(String(format: "%.2f", ms)) ms at 1080p (limit \(limit) ms)")
        }
        // always: a gross bound on the GPU command-buffer time (what the effect costs on the GPU, not wall clock)
        for (id, ms) in times where ms > TimingBudget.cpuLimit(Self.budgetMs) {
            Issue.record("\(id) costs \(String(format: "%.2f", ms)) ms of GPU time at 1080p (gross limit \(TimingBudget.cpuLimit(Self.budgetMs)) ms)")
        }
        #expect(times.count == all.count)
    }
}
