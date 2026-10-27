import SwiftUI
import ValseCore
import ValseEngine
import ValseAI
import Perception

/// Media ▸ smart search (AI-028): "Search by content or dialogue" field over the media grid. Typing indexes the
/// project's media in the background (Vision labels + on-screen text, cached) and filters/sorts the cards.
struct SmartSearchField: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let ai = store.ai
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(IStyle.caption)
                TextField(tr("media.smartSearch"), text: Binding.perceived(get: { ai.mediaQuery }, set: { store.setMediaQuery($0) }))
                    .textFieldStyle(.plain).font(Theme.Fonts.row).testID("media.search")
                if ai.mediaIndexing { ProgressView().controlSize(.mini) }
                if !ai.mediaQuery.isEmpty { SmallIconButton(symbol: "xmark.circle.fill", help: tr("ai.cancel")) { store.setMediaQuery("") } }
            }
            .padding(.horizontal, 8).frame(height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Media ▸ search, while a query is typed and the CLIP model isn't installed (AI-028): one line offering free-text
/// search ("Describe a scene — a dog on the beach") with the shared download / progress controls. Disappears once
/// installed, then the bin is re-indexed with image embeddings and the query re-run.
struct ClipSearchBanner: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let mm = ModelManager.shared
            let _ = mm.states
            let state = mm.state(ModelCatalog.clip)
            VStack(spacing: 0) {
                if !store.ai.mediaQuery.trimmingCharacters(in: .whitespaces).isEmpty && !state.isInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.accent)
                            HintText(text: tr("f4ai.clip.offer"))
                        }
                        ModelStateControls(spec: ModelCatalog.clip)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12).padding(.top, 8)
                    .testID("media.clipOffer")
                }
            }
            .onValueChange(of: state.isInstalled) { _, ok in
                guard ok else { return }
                store.indexMediaIfNeeded()
                store.prepareClipSearch(store.ai.mediaQuery)
            }
        }
    }
}

extension EditorStore {
    func setMediaQuery(_ q: String) {
        ai.mediaQuery = q
        ai.mediaQueryEN = nil
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        indexMediaIfNeeded()
        prepareClipSearch(q)
        if L10n.shared.language != "en" {
            let lang = L10n.shared.language
            Task {
                let r = try? await CaptionTranslator.translate([(0, q)], from: lang, to: "en")
                if ai.mediaQuery == q {
                    ai.mediaQueryEN = r?[0]
                    if let en = r?[0] { prepareClipSearch(en) }
                }
            }
        }
    }

    /// AI-028: embeds the query with CLIP off the main thread (free-text search), then refreshes the results.
    func prepareClipSearch(_ q: String) {
        guard ClipEmbedder.isInstalled else { return }
        Task {
            if await MediaIndex.shared.prepareClipQuery(q), !ai.mediaQuery.isEmpty { ai.mediaIndexRevision += 1 }
        }
    }

    func indexMediaIfNeeded() {
        let todo = project.media.filter { !MediaIndex.shared.isIndexed($0) }
        guard !todo.isEmpty, !ai.mediaIndexing else { return }
        ai.mediaIndexing = true
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "media.indexing", priority: 0, heavy: true) { progress in
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
        return MediaIndex.shared.search(items, query: q, english: en)
    }
}
