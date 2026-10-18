import SwiftUI
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// Media tab: Import (button, ⌘I, Finder drop) + grid of imported media cards (thumbnail, duration, "+" to add,
/// drag to the timeline).
struct MediaTab: View {
    @Bindable var store: EditorStore
    var kinds: Set<MediaKind> = [.video, .image, .audio]
    @State private var nav = "import"
    @State private var dropTargeted = false

    var items: [MediaAsset] { store.project.media.filter { kinds.contains($0.kind) } }

    var body: some View {
        HStack(spacing: 0) {
            SubNav(items: [("import", tr("media.nav.import")), ("library", tr("media.nav.library"))], selection: $nav)
            Group {
                if nav == "library" {
                    EmptyState(symbol: "books.vertical", title: tr("media.library.empty"))
                } else if items.isEmpty {
                    dropZone
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Button { ImportPanel.run(store) } label: {
                                Label(tr("media.import"), systemImage: "plus").font(.system(size: 12))
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 10)], spacing: 12) {
                                ForEach(items) { a in MediaCard(store: store, asset: a) }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { store.importFiles($0) }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2).padding(4) } }
    }

    var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle").font(.system(size: 26)).foregroundStyle(Theme.textPrimary.opacity(0.8))
            Text(loc: "media.import").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(loc: "media.dropHint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { ImportPanel.run(store) }
    }
}

/// Audio tab: imported audio (music/sound-effect libraries are a content workstream).
struct AudioTab: View {
    let store: EditorStore
    var body: some View { MediaTab(store: store, kinds: [.audio]) }
}

struct MediaCard: View {
    let store: EditorStore
    let asset: MediaAsset
    @State private var image: CGImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Theme.inset)
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                } else {
                    Image(systemName: asset.kind == .audio ? "waveform" : "film").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if asset.kind != .image {
                    Text(verbatim: Timecode.shortDuration(asset.duration)).font(.system(size: 10).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if store.proxyPending.contains(asset.contentHash) {
                    ProgressView().controlSize(.mini).padding(4).help(tr("job.proxy"))
                }
            }
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button { store.addToTimeline(asset.id) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain).padding(4).help(tr("asset.addToTrack"))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(hover ? Theme.accent : .clear, lineWidth: 1.5))
            Text(verbatim: asset.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.addToTimeline(asset.id) }
        .onDrag { NSItemProvider(object: DragPayload.media(asset.id) as NSString) }
        .task(id: asset.id) {
            if asset.kind == .audio { return }
            image = ThumbnailCache.shared.cached(asset, at: .zero, height: 96)
            if image == nil { image = await ThumbnailCache.shared.thumbnail(asset, at: .zero, height: 96) }
        }
    }
}

enum ImportPanel {
    @MainActor static func run(_ store: EditorStore) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.movie, .audio, .image, .folder]
        p.message = tr("media.importMessage")
        p.prompt = tr("media.import")
        if p.runModal() == .OK { store.importFiles(p.urls) }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
}

nonisolated final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func append(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}
