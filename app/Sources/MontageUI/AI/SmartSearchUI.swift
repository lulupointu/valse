import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

/// Media ▸ smart search (AI-028): "Search by content or dialogue" field over the media grid. Typing indexes the
/// project's media in the background (Vision labels + on-screen text, cached) and filters/sorts the cards.
struct SmartSearchField: View {
    let store: EditorStore
    var body: some View {
        let ai = store.ai
        HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(IStyle.caption)
            TextField(tr("media.smartSearch"), text: Binding(get: { ai.mediaQuery }, set: { store.setMediaQuery($0) }))
                .textFieldStyle(.plain).font(Theme.Fonts.row).testID("media.search")
            if ai.mediaIndexing { ProgressView().controlSize(.mini) }
            if !ai.mediaQuery.isEmpty { SmallIconButton(symbol: "xmark.circle.fill", help: tr("ai.cancel")) { store.setMediaQuery("") } }
        }
        .padding(.horizontal, 8).frame(height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
    }
}

extension EditorStore {
    func setMediaQuery(_ q: String) {
        ai.mediaQuery = q
        ai.mediaQueryEN = nil
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        indexMediaIfNeeded()
        if L10n.shared.language != "en" {
            let lang = L10n.shared.language
            Task {
                let r = try? await CaptionTranslator.translate([(0, q)], from: lang, to: "en")
                if ai.mediaQuery == q { ai.mediaQueryEN = r?[0] }
            }
        }
    }

    func indexMediaIfNeeded() {
        let todo = project.media.filter { !MediaIndex.shared.isIndexed($0) }
        guard !todo.isEmpty, !ai.mediaIndexing else { return }
        ai.mediaIndexing = true
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "media.indexing", priority: 0) { progress in
                for (i, a) in todo.enumerated() {
                    try Task.checkCancellation()
                    try? await MediaIndex.shared.index(a)
                    progress.report(Double(i + 1) / Double(todo.count))
                }
            }
            _ = await JobQueue.shared.wait(id)
            ai.mediaIndexing = false
            ai.mediaIndexRevision += 1
        }
    }

    /// Media matching the smart search, best first (nil = no query).
    func smartSearchResults(_ items: [MediaAsset]) -> [MediaAsset]? {
        let q = ai.mediaQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        _ = ai.mediaIndexRevision
        let en = ai.mediaQueryEN
        return items.map { ($0, MediaIndex.shared.score($0, query: q, english: en)) }.filter { $0.1 > 0.3 }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
