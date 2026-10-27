import AppKit

/// U1-2: horizontal overflow of the Settings body (`settings.body`) for UI tests — `overflow` = document width minus
/// visible width (≤ 0 = nothing to scroll sideways), `scrollX` = current horizontal offset. nil when Settings is closed.
@MainActor enum SettingsScrollProbe {
    static func dump() -> [String: Any]? {
        guard let w = SyntheticEvents.testWindow, let content = w.contentView,
              let f = TestAnchors.shared.frame("settings.body") else { return nil }
        guard let sv = scrollViews(in: content).min(by: { distance($0, f, content) < distance($1, f, content) }),
              distance(sv, f, content) < 8 else { return nil }
        guard let dialog = TestAnchors.shared.frame("settings") else { return nil }
        // every scroll view inside the dialog (the body and any nested list): the worst sideways overflow / elasticity
        let inner = scrollViews(in: content).filter { rect($0, content).insetBy(dx: -1, dy: -1).intersects(dialog) }
        let worstOverflow = inner.map { ($0.documentView?.frame.width ?? 0) - $0.contentView.bounds.width }.max() ?? 0
        let elastic = inner.filter { $0.horizontalScrollElasticity != .none }.count
        let doc = sv.documentView?.frame.width ?? 0
        let visible = sv.contentView.bounds.width
        return ["overflow": Double(doc - visible), "scrollX": Double(sv.contentView.bounds.minX),
                "visibleWidth": Double(visible), "documentWidth": Double(doc),
                // sideways rubber-band: .none (2) = a trackpad swipe can't pull the content left / right at all
                "horizontalElasticity": sv.horizontalScrollElasticity.rawValue,
                "hasHorizontalScroller": sv.hasHorizontalScroller,
                "scrollViews": inner.count, "innerOverflow": Double(worstOverflow), "horizontallyElastic": elastic,
                "innerScrollX": inner.map { Double($0.contentView.bounds.minX) }.max() ?? 0]
    }

    private static func scrollViews(in v: NSView) -> [NSScrollView] {
        (v as? NSScrollView).map { [$0] + $0.subviews.flatMap(scrollViews) } ?? v.subviews.flatMap(scrollViews)
    }

    /// Size + position mismatch between a scroll view and an anchor frame (top-left window points).
    private static func distance(_ sv: NSScrollView, _ f: CGRect, _ content: NSView) -> CGFloat {
        let r = rect(sv, content)
        return abs(r.width - f.width) + abs(r.height - f.height) + abs(r.minX - f.minX) + abs(r.minY - f.minY)
    }

    private static func rect(_ sv: NSScrollView, _ content: NSView) -> CGRect {
        var r = sv.convert(sv.bounds, to: content)
        if !content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
        return r
    }
}
