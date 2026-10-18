import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine

/// Renders every effect / filter / adjustment once at 1080p and flags any over the real-time budget.
///
/// Budget: an effect must cost ≤ `budgetMs` of GPU time per 1080p frame on this machine. The default (3.5 ms on an
/// M1 Pro) maps to ≈ 7–8 ms on a base M1/M2 Air GPU, which keeps a 30 fps preview with decode + compositing.
/// Always runs (≈ 3 s) with a lenient ×2 margin so slow CI hosts don't flap; `MONTAGE_PERF=1` enforces the exact
/// budget. `MONTAGE_FX_BUDGET_MS` overrides it. Prints the slowest entries.
@Suite(.serialized) struct EffectsPerfTests {
    static let strict = ProcessInfo.processInfo.environment["MONTAGE_PERF"] == "1"
    static let budgetMs = Double(ProcessInfo.processInfo.environment["MONTAGE_FX_BUDGET_MS"] ?? "") ?? 3.5

    @Test func everyEffectFitsTheRealTimeBudget() {
        let r = EffectPreviewRenderer.shared
        let all = Registries.effects.all.filter { $0.id.hasPrefix("montage.") && $0.category != .canvas }
        var times: [(String, Double)] = []
        for d in all {
            guard let ms = r.gpuMilliseconds(d, width: 1920, height: 1080, time: 1.1, runs: 3) else {
                Issue.record("\(d.id): could not render"); continue
            }
            times.append((d.id, ms))
        }
        times.sort { $0.1 > $1.1 }
        let limit = Self.budgetMs * (Self.strict ? 1 : 2)
        print("effects perf (1080p GPU ms, budget \(Self.budgetMs), limit \(limit)), slowest:")
        for (id, ms) in times.prefix(15) { print(String(format: "  %6.2f  %@", ms, id)) }
        let total = times.reduce(0) { $0 + $1.1 }
        print(String(format: "  mean %.2f ms over %d entries", total / Double(max(times.count, 1)), times.count))
        for (id, ms) in times where ms > limit {
            Issue.record("\(id) costs \(String(format: "%.2f", ms)) ms at 1080p (limit \(limit) ms)")
        }
        #expect(times.count == all.count)
    }
}
