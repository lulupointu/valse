import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// Asset panel ▸ Text (UX.md §3.5, screenshots 61/121): Add text · Yours · Text effects · Text template · AI writer
/// (auto / local captions moved to the Captions tab, C4). Tiles show the real rendered look; click / ⊕ / double-click adds or applies, drag
/// drops on the timeline.
struct TextAssetTab: View {
    let store: EditorStore
    @State private var nav: String
    @State private var search = ""

    init(store: EditorStore, initialNav: String = "add") {
        self.store = store
        _nav = State(initialValue: initialNav)
    }

    var body: some View {
        HStack(spacing: 0) {
            SubNav(items: [("add", tr("text.nav.add")), ("yours", tr("text.nav.yours")), ("effects", tr("text.nav.effects")),
                           ("templates", tr("text.nav.templates")), ("fonts", tr("fontbook.nav")),
                           ("writer", tr("writer.nav"))],   // captions: own tab (C4)
                   selection: $nav)
            Group {
                switch nav {
                case "fonts": FontBookPanel(store: store)   // MI-021 (F3)
                case "writer": AIWriterPanel(store: store)   // W10
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if nav == "effects" || nav == "templates" {
                                SearchField(text: $search, placeholder: tr(nav == "effects" ? "text.effects.search" : "text.templates.search"))
                            }
                            content
                        }
                        .padding(12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            TextPreviewCache.shared.prewarm(Registries.textStyles(.effect).map { ("fx:\($0.id)", TextPreviewImage.style($0, sample: "ART"), 44) }
                + Registries.textTemplates.all.map { ("template:\($0.id)", $0.makeContent(), 34) })
        }
    }

    static let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 10)]

    @ViewBuilder var content: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        switch nav {
        case "add":
            LazyVGrid(columns: Self.columns, spacing: 12) {
                TextAssetTile(title: tr("text.default"), payload: DragPayload.textStyle("montage.text.default"), add: { store.addDefaultText() }) {
                    Text(loc: "text.default").font(.system(size: 13)).foregroundStyle(.white).multilineTextAlignment(.center).padding(6)
                }
            }
        case "yours":
            let presets = TextPresetStore.shared.presets
            TextFavoritesSection(store: store)   // MI-024 (F3): ☆ text effects / templates / fonts
            if presets.isEmpty {
                EmptyState(symbol: "star", title: tr("text.yours.empty"))
            } else {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(presets) { p in
                        TextAssetTile(title: p.name, payload: DragPayload.textStyle("montage.text.default"), add: { store.applySavedPreset(p) }) {
                            TextPreviewImage(key: "saved:\(p.id)", content: { var t = p.content; t.string = "Aa"; t.fontSize = 0.1; return t }(), fontPx: 40)
                        }
                        .contextMenu { Button(tr("text.yours.delete")) { TextPresetStore.shared.remove(p.id) } }
                    }
                }
            }
        case "effects":
            ForEach(BuiltinTextStyles.effectGroups, id: \.self) { g in
                let items = Registries.textStyles(.effect).filter { $0.groupKey == g && (q.isEmpty || $0.displayName.lowercased().contains(q) || tr(g).lowercased().contains(q)) }
                if !items.isEmpty {
                    Text(verbatim: tr(g)).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    LazyVGrid(columns: Self.columns, spacing: 12) {
                        ForEach(items) { d in
                            TextAssetTile(title: d.displayName, payload: DragPayload.textStyle(d.id),
                                          favorite: (AssetLibraryStore.textEffectsNamespace, d.id), add: { store.applyTextStyle(d) }) {
                                TextPreviewImage(key: "fx:\(d.id)", content: TextPreviewImage.style(d, sample: "ART"), fontPx: 44)
                            }
                        }
                    }
                }
            }
        case "templates":
            let groups = BuiltinAssetTabs.grouped(Registries.textTemplates.all, \.groupKey)
            ForEach(groups, id: \.0) { g, items0 in
                let items = items0.filter { q.isEmpty || tr($0.nameKey).lowercased().contains(q) || tr(g).lowercased().contains(q) }
                if !items.isEmpty {
                    Text(verbatim: tr(g)).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    LazyVGrid(columns: Self.columns, spacing: 12) {
                        ForEach(items) { d in
                            TextAssetTile(title: tr(d.nameKey), payload: DragPayload.textTemplate(d.id),
                                          favorite: (AssetLibraryStore.textTemplatesNamespace, d.id), add: { store.addTextTemplate(d) }) {
                                TextPreviewImage(key: "template:\(d.id)", content: d.makeContent(), fontPx: 34)
                            }
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

/// 86 pt square tile with a rendered preview, hover ⊕, double-click to add, drag to the timeline.
struct TextAssetTile<Preview: View>: View {
    let title: String
    let payload: String
    /// MI-024 (F3): ☆ on hover (namespace, id) → Text ▸ Yours ▸ Favorites.
    var favorite: (ns: String, id: String)? = nil
    let add: () -> Void
    @ViewBuilder let preview: () -> Preview
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                    .overlay { preview() }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? Theme.accent : .clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if let f = favorite {
                    let on = AssetLibraryStore.shared.isFavorite(f.ns, f.id)
                    if hover || on {
                        Button { AssetLibraryStore.shared.toggleFavorite(f.ns, f.id) } label: {
                            Image(systemName: on ? "star.fill" : "star").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(on ? IStyle.curve : .white).frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain).padding(4).help(tr("text.font.favorite"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .testID("text.fav.\(f.id)")
                    }
                }
                if hover {
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain).padding(4).help(tr("asset.addToTrack"))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: add)
        .onDrag { NSItemProvider(object: payload as NSString) }
        .accessibilityElement(children: .combine)
        .testID("text.tile.\(favorite?.id ?? title)")
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(.isButton)
    }
}

/// Text ▸ Local captions: import SRT / LRC / ASS / VTT / TXT (≤ 3 MB), or type a script and split it into captions.
struct LocalCaptionsPanel: View {
    let store: EditorStore
    @State private var script = ""
    @State private var encoding = CaptionEncoding.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc: "text.nav.local").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            Text(loc: "captions.import.desc").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            Button(tr("captions.import")) { store.chooseCaptionFileToImport() }.buttonStyle(AccentButtonStyle())
            HStack(spacing: 10) {   // MI-020 (F3)
                Text(loc: "captions.encoding").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Dropdown(items: CaptionEncoding.allCases.map { ($0, tr($0.nameKey)) }, selection: encoding) { e in
                    encoding = e; CaptionEncoding.current = e
                }
                .frame(width: 220).testID("captions.encoding")
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            Text(loc: "captions.script").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            Text(loc: "captions.script.desc").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            TextEditor(text: $script)
                .font(.system(size: 12)).scrollContentBackground(.hidden).padding(6)
                .frame(minHeight: 90, maxHeight: 160)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                .testID("captions.script.editor")
            HStack(spacing: 8) {
                Button(tr("captions.script.split")) { store.addScriptCaptions(script, split: true); script = "" }
                    .buttonStyle(AccentButtonStyle()).disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(tr("captions.script.noSplit")) { store.addScriptCaptions(script, split: false); script = "" }
                    .buttonStyle(SecondaryButtonStyle()).disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            AlignScriptRow(store: store, script: $script)   // AI2 TX-030: time the script on the speech
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DragPayload {
    public static func textTemplate(_ id: String) -> String { "montage-text:template:\(id)" }
}

@MainActor
extension EditorStore {
    /// Timeline drop of a Text tab tile ("montage-text:<style id>" or "montage-text:template:<id>").
    public func addTextPayload(_ id: String) {
        if id.hasPrefix("template:"), let d = Registries.textTemplates[String(id.dropFirst("template:".count))] { addTextTemplate(d); return }
        guard let d = Registries.textStyles[id] else { addDefaultText(); return }
        selection = []          // a drop always adds a new text clip
        applyTextStyle(d)
    }
}
