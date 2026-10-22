import AppKit
import Perception
import MontageCore
import MontageEngine

/// Quick cut popover state (TL-048, docs/QUICK_CUT.md §1): targets, the max-blank value, the analysis progress and the
/// live plan. Lives in `store.timelineUI.quickCut` while the popover is open (nil = closed). The project is never
/// touched until `apply()`: the timeline draws `plan` over the clips (TimelineView+QuickCut.swift) and the playback
/// engine jumps over the slices (`PlaybackEngine.skipRanges`).
///
/// Perf: a value change recomputes the plan synchronously (pure, microseconds per clip) and bumps `planRevision`, the
/// one thing the timeline canvas observes; the popover reads `value` / summary fields only.
@MainActor @Perceptible
public final class QuickCutSession {
    public enum Scope: Equatable { case all, selected(Int) }

    /// UserDefaults key of the last value used (app-wide, shared across projects).
    public static let defaultsKey = "quickCut.maxBlank"
    public static let defaultValue = 0.5

    @PerceptionIgnored weak var store: EditorStore?
    @PerceptionIgnored let defaults: UserDefaults
    @PerceptionIgnored let analyzer: QuickCutAnalyzer
    /// Selection when the popover opened (scope stays fixed while it is open).
    @PerceptionIgnored let selection: Set<ClipID>

    /// Max blank length (s), clamped to `QuickCut.maxBlankRange`, 1 decimal.
    public private(set) var value: Double
    public private(set) var scope: Scope
    public private(set) var targets: [QuickCutTarget] = []
    /// Every clip a target covers (primaries + their extracted audio): the others are dimmed on the timeline.
    @PerceptionIgnored public private(set) var targetClips: Set<ClipID> = []
    /// Latest plan for `value` with the masks analysed so far.
    @PerceptionIgnored public private(set) var plan: QuickCutPlan
    /// Bumped whenever `plan` / `targetClips` change (the timeline canvas observes this).
    public private(set) var planRevision = 0
    /// Summary fields (the popover reads these, not `plan`).
    public private(set) var count = 0
    public private(set) var removed: Time = .zero
    /// Analysis: media done / total of the targets' media, and the overall fraction (0…1, includes running files).
    public private(set) var analysed = 0
    public private(set) var total = 0
    public private(set) var progress = 1.0
    public var isAnalysing: Bool { analysed < total }

    @PerceptionIgnored var masks: [MediaID: QuickCutMask] = [:]
    @PerceptionIgnored private var media: [MediaAsset] = []
    @PerceptionIgnored private var partial: [MediaID: Double] = [:]
    @PerceptionIgnored private var running: [MediaID: Task<Void, Never>] = [:]
    @PerceptionIgnored private var revision = -1
    @PerceptionIgnored private(set) var isClosed = false

    init(store: EditorStore, defaults: UserDefaults = .standard, analyzer: QuickCutAnalyzer = .shared) {
        self.store = store
        self.defaults = defaults
        self.analyzer = analyzer
        selection = store.selection
        let v = Self.storedValue(defaults)
        value = v
        scope = .all
        plan = QuickCutPlan(maxBlank: v)
        refresh()
        watchProject()
    }

    /// An edit while open (undo, ⌘A…): targets and plan follow the project.
    private func watchProject() {
        withPerceptionTracking { _ = store?.session.revision } onChange: {
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.replan()
                self.watchProject()
            }
        }
    }

    // MARK: Value

    /// Clamp to the slider range and round to 1 decimal.
    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return defaultValue }
        let r = QuickCut.maxBlankRange
        return ((min(max(v, r.lowerBound), r.upperBound)) * 10).rounded() / 10
    }

    static func storedValue(_ d: UserDefaults) -> Double {
        d.object(forKey: defaultsKey) == nil ? defaultValue : clamp(d.double(forKey: defaultsKey))
    }

    public func setValue(_ v: Double) {
        let c = Self.clamp(v)
        guard c != value else { return }
        value = c
        defaults.set(c, forKey: Self.defaultsKey)
        replan()
    }

    /// Slider position (0…1) ↔ value.
    public var unit: Double {
        let r = QuickCut.maxBlankRange
        return (value - r.lowerBound) / (r.upperBound - r.lowerBound)
    }
    public func setUnit(_ u: Double) {
        let r = QuickCut.maxBlankRange
        setValue(r.lowerBound + min(max(u, 0), 1) * (r.upperBound - r.lowerBound))
    }

    // MARK: Targets / analysis / plan

    /// Recomputes targets (and starts the analyses still missing) when the project changed, then the plan.
    func refresh() {
        guard let store, !isClosed else { return }
        let p = store.project
        revision = store.session.revision
        let sel = selection.filter { p.timeline.clip($0) != nil }
        targets = QuickCut.targets(p, selection: Set(sel))
        // "the 3 selected media clips": selected clips Quick cut works on (a video and its extracted audio count twice)
        let selectedMedia = sel.filter { id in targets.contains { $0.members.contains(id) } }.count
        scope = selection.isEmpty ? .all : .selected(selectedMedia)
        targetClips = Set(targets.flatMap(\.members))
        media = QuickCut.media(of: targets, in: p)
        for a in media where masks[a.id] == nil {
            if let m = analyzer.cached(a) { masks[a.id] = m }
        }
        let missing = media.filter { masks[$0.id] == nil }
        if !missing.isEmpty {
            // decodes keep running after the popover closes (prefetch is a waiter of its own): reopening is instant
            QuickCutPrefetch.start(missing, analyzer: analyzer)
            for a in missing where running[a.id] == nil { startAnalysis(a) }
        }
        replan()
    }

    private func startAnalysis(_ a: MediaAsset) {
        let id = a.id, analyzer = self.analyzer
        let onProgress: @Sendable (Double) -> Void = { [weak self] f in
            let me = self
            Task { @MainActor in me?.noteProgress(id, f) }
        }
        running[id] = Task { [weak self] in
            let mask = try? await analyzer.analyze(a, progress: onProgress)
            guard let self, !Task.isCancelled else { return }
            self.running[id] = nil
            // unreadable media: an empty mask (nothing cut) so the analysis still completes
            self.masks[id] = mask ?? .empty
            self.replan()
        }
    }

    /// Awaits the analyses running now (tests).
    func waitForAnalyses() async {
        while let t = running.values.first { await t.value }
    }

    private func noteProgress(_ id: MediaID, _ f: Double) {
        guard masks[id] == nil, !isClosed else { return }
        partial[id] = f
        updateProgress()
    }

    private func updateProgress() {
        let done = media.filter { masks[$0.id] != nil }.count
        if analysed != done { analysed = done }
        if total != media.count { total = media.count }
        let running = media.reduce(0.0) { $0 + (masks[$1.id] == nil ? (partial[$1.id] ?? 0) : 0) }
        let f = media.isEmpty ? 1 : min(1, (Double(done) + running) / Double(media.count))
        if abs(f - progress) > 0.005 || f == 1 { progress = f }
    }

    func replan() {
        guard let store, !isClosed else { return }
        if store.session.revision != revision { refresh(); return }
        plan = QuickCut.plan(store.project, targets: targets, maxBlank: value, masks: masks)
        if count != plan.count { count = plan.count }
        let r = plan.removed
        if removed != r { removed = r }
        updateProgress()
        planRevision &+= 1
        store.engine.skipRanges = Self.skipRanges(plan)
    }

    /// What playback jumps over: the main-track slices (they ripple: skipping them plays the result). Slices on other
    /// tracks close up inside their clip without moving the timeline, so they are skipped only when the plan has no
    /// main-track cuts at all (a voice-over only project) — then skipping is the closest preview.
    static func skipRanges(_ plan: QuickCutPlan) -> [TimeRange] {
        let main = plan.items.filter(\.onMainTrack)
        let items = main.isEmpty ? plan.items : main
        let all = items.flatMap(\.slices).sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in all {
            if let last = out.last, r.start <= last.end { out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end)) }
            else { out.append(r) }
        }
        return out
    }

    // MARK: Apply / close

    /// Applies the plan as one undo step, toasts the result and closes. False when there is nothing to cut.
    @discardableResult
    public func apply() -> Bool {
        guard let store, !isClosed else { return false }
        if store.session.revision != revision { refresh() }
        let plan = self.plan
        guard plan.count > 0 else { return false }
        close()
        guard store.perform(ApplyQuickCut(plan)) else { return false }
        store.showToast(Self.toastText(count: plan.count, removed: plan.removed))
        return true
    }

    /// Cancels: nothing changes (analyses started by `QuickCutPrefetch` keep filling the cache).
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for t in running.values { t.cancel() }
        running.removeAll()
        store?.engine.skipRanges = []
        if let store, store.timelineUI.quickCut === self { store.timelineUI.quickCut = nil }
    }

    // MARK: Text

    public var canApply: Bool { count > 0 }

    public var scopeText: String {
        switch scope {
        case .all: return tr("quickcut.scope.all")
        case .selected(0): return tr("quickcut.scope.noneSelected")
        case .selected(let n): return n == 1 ? tr("quickcut.scope.one") : tr("quickcut.scope.many", n)
        }
    }

    public var summaryText: String {
        if count == 0 {
            if targets.isEmpty { return tr("quickcut.summary.noClips") }
            return isAnalysing ? tr("quickcut.summary.waiting") : tr("quickcut.summary.none", Self.seconds(value))
        }
        let secs = Self.seconds(removed.seconds)
        return count == 1 ? tr("quickcut.summary.one", secs) : tr("quickcut.summary.many", count, secs)
    }

    public var progressText: String { tr("quickcut.analysing", analysed, total) }

    static func toastText(count: Int, removed: Time) -> String {
        count == 1 ? tr("quickcut.toast.one", seconds(removed.seconds)) : tr("quickcut.toast.many", count, seconds(removed.seconds))
    }

    /// "0.5" / "0,5" (one decimal, the UI language's separator).
    static func seconds(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return L10n.shared.language.hasPrefix("fr") ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// Parses "1.2", "1,2", "1.2 s", "1,2s".
    static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("s") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }

    // MARK: Test dump

    var dump: [String: Any] {
        var slices: [String: [[Double]]] = [:]
        for (id, rs) in plan.slicesByClip { slices[id.description] = rs.map { [$0.start.seconds, $0.end.seconds] } }
        return ["open": true, "value": value, "count": count, "removed": removed.seconds, "scope": scopeText,
                "summary": summaryText, "analysed": analysed, "total": total, "analysing": isAnalysing,
                "targets": targets.count, "canApply": canApply, "slicedClips": plan.slicesByClip.count,
                "skipRanges": store?.engine.skipRanges.count ?? 0, "slices": slices]
    }
}

/// Background Quick cut analysis started on import and when the popover opens (utility QoS, never blocks the UI).
/// Tasks are kept so quitting / the end of a UI test can stop them (`AppShutdown.stopBackgroundWork`).
@MainActor
public enum QuickCutPrefetch {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    /// Starts analysing the audio / video media among `assets` not analysed yet.
    public static func start(_ assets: [MediaAsset], analyzer: QuickCutAnalyzer = .shared) {
        let todo = assets.filter { ($0.kind == .video || $0.kind == .audio) && $0.hasAudio }
        guard !todo.isEmpty else { return }
        let id = UUID()
        let task = analyzer.prefetch(todo)
        tasks[id] = task
        Task { @MainActor in
            await task.value
            tasks[id] = nil
        }
    }

    public static func cancelAll() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }
}
