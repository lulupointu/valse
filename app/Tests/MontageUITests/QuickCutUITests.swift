import Testing
import Foundation
@testable import MontageCore
@testable import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// TL-048 Quick cut popover logic: scope wording, value clamping / persistence, plan refresh when an analysis lands,
/// apply = one undo step, playback skip ranges.
@MainActor @Suite(.serialized) struct QuickCutUITests {
    static func video(_ name: String, seconds: Double = 10, url: URL? = nil) -> MediaAsset {
        MediaAsset(name: name, kind: .video, url: url ?? URL(fileURLWithPath: "/nonexistent/\(name).mp4"), duration: Time(seconds),
                   pixelSize: .hd1080, frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: UUID().uuidString)
    }

    /// Mask with speech in the given source spans.
    static func mask(_ seconds: Double, _ speech: [(Double, Double)]) -> QuickCutMask {
        let n = Int((seconds * 100).rounded())
        var m = [Bool](repeating: false, count: n)
        for (a, b) in speech { for k in Int((a * 100).rounded())..<min(n, Int((b * 100).rounded())) { m[k] = true } }
        return QuickCutMask(speech: m, hasDynamics: true)
    }

    /// Analyzer with its own cache folder; `masks` are written to its disk cache (what `cached` reads).
    static func analyzer(_ masks: [(MediaAsset, QuickCutMask)]) throws -> QuickCutAnalyzer {
        let dir = MontagePaths.cacheDirectory.appendingPathComponent("quickcut-ui-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (a, m) in masks { try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("\(a.contentHash).v1")) }
        return QuickCutAnalyzer(directory: dir)
    }

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "quickcut-tests-\(UUID().uuidString)")! }

    /// Main track with one 10 s clip per asset (speech 1–3 s and 6–9 s: blanks 0–1, 3–6, 9–10).
    static func store(_ assets: [MediaAsset]) -> (EditorStore, [ClipID]) {
        var p = Project(name: "QC")
        var ids: [ClipID] = []
        for a in assets {
            p.media.append(a)
            let c = TimelineOps.makeClip(for: a, at: Time(1000))
            try! TimelineOps.insert(c, into: &p)
            ids.append(c.id)
        }
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        return (s, ids)
    }

    static let speech = [(1.0, 3.0), (6.0, 9.0)]

    @Test func scopeWording() throws {
        let a = (0..<4).map { Self.video("v\($0)") }
        let (store, ids) = Self.store(a)
        let an = try Self.analyzer(a.map { ($0, Self.mask(10, Self.speech)) })
        let d = Self.defaults()
        let all = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(all.scope == .all && all.targets.count == 4 && all.scopeText == tr("quickcut.scope.all"))
        all.close()
        store.selection = [ids[1]]
        let one = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(one.scope == .selected(1) && one.targets.map(\.primary) == [ids[1]] && one.scopeText == tr("quickcut.scope.one"))
        one.close()
        store.selection = Set(ids.prefix(3))
        let three = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(three.scope == .selected(3) && three.scopeText == tr("quickcut.scope.many", 3))
        #expect(three.targetClips == Set(ids.prefix(3)))
        three.close()
        // a selection without media clips: nothing to cut
        let text = store.addGeneratorClip(.text(TextContent(string: "Hi")))!
        store.selection = [text]
        let none = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(none.scope == .selected(0) && none.targets.isEmpty && !none.canApply)
        #expect(none.summaryText == tr("quickcut.summary.noClips"))
        none.close()
    }

    @Test func valueIsClampedRoundedAndRemembered() throws {
        #expect(QuickCutSession.clamp(0.04) == 0.1)
        #expect(QuickCutSession.clamp(7) == 5)
        #expect(QuickCutSession.clamp(1.26) == 1.3)
        #expect(QuickCutSession.clamp(.nan) == 0.5)
        #expect(QuickCutSession.parse("1,2 s") == 1.2 && QuickCutSession.parse(" 0.8s") == 0.8 && QuickCutSession.parse("x") == nil)
        let a = [Self.video("v")]
        let (store, _) = Self.store(a)
        let an = try Self.analyzer([(a[0], Self.mask(10, Self.speech))])
        let d = Self.defaults()
        let s = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(s.value == 0.5)   // first launch
        s.setValue(2.04)
        #expect(s.value == 2 && d.double(forKey: QuickCutSession.defaultsKey) == 2)
        s.setUnit(1)
        #expect(s.value == 5)
        s.setUnit(-1)
        #expect(s.value == 0.1)
        s.setValue(2.5)
        s.close()
        // the next popover (any project) starts from the last value
        let again = QuickCutSession(store: store, defaults: d, analyzer: an)
        #expect(again.value == 2.5)
        again.close()
    }

    @Test func planFollowsTheValueAndMarksPlayback() throws {
        let a = [Self.video("v")]
        let (store, ids) = Self.store(a)
        let an = try Self.analyzer([(a[0], Self.mask(10, Self.speech))])
        let s = QuickCutSession(store: store, defaults: Self.defaults(), analyzer: an)
        // 0.5 s: the three blanks (0–1 at the start, 3–6, 9–10 at the end)
        #expect(s.count == 3 && !s.isAnalysing && s.canApply)
        #expect(s.plan.slices(for: ids[0]).count == 3)
        #expect(store.engine.skipRanges == QuickCutSession.skipRanges(s.plan) && store.engine.skipRanges.count == 3)
        let rev = s.planRevision
        s.setValue(1.5)   // only the 3 s pause is longer
        #expect(s.count == 1 && s.planRevision != rev)
        s.setValue(5)
        #expect(s.count == 0 && !s.canApply && s.summaryText == tr("quickcut.summary.none", QuickCutSession.seconds(5)))
        #expect(store.engine.skipRanges.isEmpty)
        s.setValue(0.5)
        s.close()
        #expect(store.engine.skipRanges.isEmpty && store.timelineUI.quickCut == nil)
        #expect(store.canUndo == false)   // opening, sliding, closing: no history
    }

    @Test func planFillsInWhenAnAnalysisFinishes() async throws {
        let speech = try await MediaProbe.probe(RealLikeMedia.speech)
        let cached = Self.video("cached")
        let (store, ids) = Self.store([cached, speech])
        let an = try Self.analyzer([(cached, Self.mask(10, Self.speech))])
        let s = QuickCutSession(store: store, defaults: Self.defaults(), analyzer: an)
        s.setValue(0.1)
        #expect(s.total == 2 && s.analysed == 1 && s.isAnalysing)
        #expect(s.plan.pending == [speech.id])
        #expect(!s.plan.slicesByClip.keys.contains(ids[1]))
        #expect(s.count == 3)   // the analysed clip's blanks are already there (0–1, 3–6, 9–10)
        await s.waitForAnalyses()
        #expect(s.analysed == 2 && !s.isAnalysing && s.progress == 1)
        #expect(s.plan.pending.isEmpty)
        #expect(an.cached(speech) != nil)
        s.close()
    }

    @Test func unreadableMediaStillCompletesTheAnalysis() async throws {
        let a = [Self.video("missing")]
        let (store, _) = Self.store(a)
        let s = QuickCutSession(store: store, defaults: Self.defaults(), analyzer: try Self.analyzer([]))
        #expect(s.isAnalysing && s.summaryText == tr("quickcut.summary.waiting"))
        await s.waitForAnalyses()
        #expect(!s.isAnalysing && s.count == 0)
        s.close()
    }

    @Test func applyIsOneUndoStepAndToasts() throws {
        let a = [Self.video("v0"), Self.video("v1")]
        let (store, _) = Self.store(a)
        let an = try Self.analyzer(a.map { ($0, Self.mask(10, Self.speech)) })
        let before = store.project
        let s = QuickCutSession(store: store, defaults: Self.defaults(), analyzer: an)
        store.timelineUI.quickCut = s
        let removed = s.removed, count = s.count
        #expect(count == 6)
        #expect(s.apply())
        #expect(store.timelineUI.quickCut == nil && store.engine.skipRanges.isEmpty)
        #expect(store.session.undoNameKey == "cmd.quickCut")
        #expect(abs((before.duration - store.project.duration).seconds - removed.seconds) < 0.01)
        #expect(store.toast?.message == QuickCutSession.toastText(count: count, removed: removed))
        store.undo()
        #expect(store.project.timeline == before.timeline && !store.canUndo)
    }

    @Test func editWhileOpenRefreshesThePlan() throws {
        let a = [Self.video("v0"), Self.video("v1")]
        let (store, ids) = Self.store(a)
        let an = try Self.analyzer(a.map { ($0, Self.mask(10, Self.speech)) })
        let s = QuickCutSession(store: store, defaults: Self.defaults(), analyzer: an)
        #expect(s.count == 6)
        store.perform(DeleteClips([ids[1]]))
        s.replan()
        #expect(s.count == 3 && s.targets.count == 1)
        s.close()
    }

    @Test func toastAndSummaryWording() {
        #expect(QuickCutSession.toastText(count: 12, removed: Time(18.4)) == tr("quickcut.toast.many", 12, QuickCutSession.seconds(18.4)))
        let fr = L10n(bundles: [UIResources.bundle], language: "fr")
        #expect(fr.string("quickcut.toast.many", [12, "18,4"]) == "12 blancs supprimés (−18,4 s)")
        let en = L10n(bundles: [UIResources.bundle], language: "en")
        #expect(en.string("quickcut.toast.many", [12, "18.4"]) == "Removed 12 blanks (−18.4 s)")
        #expect(en.string("quickcut.summary.many", [12, "18.4"]) == "12 blanks · −18.4 s")
    }

    @Test func tinySlicesAreDrawnAtLeastThreePointsWide() {
        let clip = CGRect(x: 100, y: 0, width: 200, height: 60)
        #expect(TimelineView.quickCutSliceRect(x0: 150, x1: 150.5, in: clip)?.width == 3)
        #expect(TimelineView.quickCutSliceRect(x0: 150, x1: 150.5, in: clip)?.midX == 150.25)
        #expect(TimelineView.quickCutSliceRect(x0: 299.5, x1: 300, in: clip)?.maxX == 300)   // stays inside the clip
        #expect(TimelineView.quickCutSliceRect(x0: 120, x1: 180, in: clip)?.width == 60)
        #expect(TimelineView.quickCutSliceRect(x0: 50, x1: 120, in: clip)?.minX == 100)
        #expect(TimelineView.quickCutSliceRect(x0: 310, x1: 320, in: clip) == nil)
    }

    @Test func engineSkipRangeLookup() {
        let e = PlaybackEngine(project: Project())
        e.skipRanges = [TimeRange(start: Time(1), end: Time(2)), TimeRange(start: Time(4), end: Time(4.5))]
        #expect(e.skipRange(containing: Time(0.5)) == nil)
        #expect(e.skipRange(containing: Time(0.99))?.start == Time(1))   // the boundary fires a hair early
        #expect(e.skipRange(containing: Time(1.5))?.end == Time(2))
        #expect(e.skipRange(containing: Time(2)) == nil)
        #expect(e.skipRange(containing: Time(4.2))?.end == Time(4.5))
        #expect(e.skipRange(containing: Time(9)) == nil)
        e.skipRanges = []
    }

    /// The owner's scissors-and-sparkles SVG (24-unit view box) maps onto the frame: geometry bounds x 3.5…23,
    /// y 1.5…19.5 in SVG units, scaled and centred.
    @Test func quickCutGlyphFollowsTheSVG() {
        let b = QuickCutShape().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        #expect(abs(b.minX - 3.5) < 0.01 && abs(b.maxX - 23) < 0.01, "\(b)")
        #expect(abs(b.minY - 1.5) < 0.01 && abs(b.maxY - 19.5) < 0.01, "\(b)")
        let big = QuickCutShape().path(in: CGRect(x: 10, y: 0, width: 48, height: 48)).boundingRect
        #expect(abs(big.minX - (10 + 7)) < 0.02 && abs(big.maxY - 39) < 0.02, "\(big)")
    }
}
