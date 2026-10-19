import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine
import MontageEffects

/// Text ▸ Fonts (MI-021 font book, F3): imported fonts (import up to 9 at once, remove, show in Finder), favourites and
/// every installed font with live previews and search. A click applies the font to the selected text clip.
struct FontBookPanel: View {
    let store: EditorStore
    @Bindable private var ui = TextUIState.shared
    @State private var search = ""

    var body: some View {
        let _rev = ui.fontsRevision
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (String) -> Bool = { q.isEmpty || $0.lowercased().contains(q) }
        let families = _rev >= 0 ? FontCatalog.families : []
        let imported = families.filter(\.isImported).map(\.name)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $search, placeholder: tr("text.font.search"))
                Button { importFonts() } label: { Label(tr("fontbook.import"), systemImage: "plus") }
                    .buttonStyle(AccentButtonStyle()).testID("fontbook.import")
            }
            .padding(12)
            HintText(text: tr("fontbook.hint")).padding(.horizontal, 12).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    section(tr("text.font.imported"), imported.filter(match), removable: true,
                            empty: q.isEmpty ? tr("fontbook.noImported") : nil)
                    let fav = ui.favoriteFonts.filter(match)
                    if !fav.isEmpty { section(tr("text.font.favorites"), fav, removable: false, empty: nil) }
                    section(tr("text.font.all"), families.filter { !$0.isImported }.map(\.name).filter(match), removable: false, empty: nil)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.importFonts([url]) }
                }
            }
            return true
        }
        .testID("fontbook")
    }

    @ViewBuilder func section(_ title: String, _ names: [String], removable: Bool, empty: String?) -> some View {
        Section {
            if names.isEmpty, let empty {
                Text(verbatim: empty).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).padding(.horizontal, 12).padding(.vertical, 8)
            }
            ForEach(names, id: \.self) { row($0, removable: removable) }
        } header: {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(IStyle.caption)
                .padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
        }
    }

    func row(_ name: String, removable: Bool) -> some View {
        let fav = ui.favoriteFonts.contains(name)
        return HStack(spacing: 10) {
            Text(verbatim: "Aa").font(previewFont(name, size: 20)).foregroundStyle(Theme.textPrimary).frame(width: 36)
            Text(verbatim: name).font(previewFont(name, size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
            Button {
                if fav { ui.favoriteFonts.removeAll { $0 == name } } else { ui.favoriteFonts.append(name) }
            } label: {
                Image(systemName: fav ? "star.fill" : "star").font(.system(size: 12)).foregroundStyle(fav ? IStyle.curve : IStyle.iconDim)
            }
            .buttonStyle(.plain).help(tr("text.font.favorite")).testID("fontbook.favorite.\(name)")
            if removable {
                Button { NSWorkspace.shared.activateFileViewerSelecting(FontLibrary.files(ofFamily: name)) } label: {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(IStyle.iconDim)
                }
                .buttonStyle(.plain).help(tr("fontbook.reveal"))
                Button { store.removeImportedFont(name) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(IStyle.iconDim)
                }
                .buttonStyle(.plain).help(tr("fontbook.remove")).testID("fontbook.remove.\(name)")
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { store.applyFontFromBook(name) }
        .testID("fontbook.row.\(name)")
    }

    func importFonts() {
        let p = NSOpenPanel()
        p.allowedContentTypes = FontLibrary.extensions.compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = true
        p.message = tr("fontbook.hint")
        p.begin { r in
            guard r == .OK else { return }
            let urls = p.urls
            Task { @MainActor in store.importFonts(urls) }
        }
    }
}

/// Text ▸ Yours ▸ Favorites (MI-024, F3): starred text effects, text templates and fonts in one place.
struct TextFavoritesSection: View {
    let store: EditorStore
    var body: some View {
        let lib = AssetLibraryStore.shared
        let effects = lib.favoriteIDs(AssetLibraryStore.textEffectsNamespace).compactMap { id in Registries.textStyles(.effect).first { $0.id == id } }
        let templates = lib.favoriteIDs(AssetLibraryStore.textTemplatesNamespace).compactMap { id in Registries.textTemplates.all.first { $0.id == id } }
        let fonts = TextUIState.shared.favoriteFonts
        VStack(alignment: .leading, spacing: 10) {
            Text(loc: "asset.nav.favorites").font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            if effects.isEmpty && templates.isEmpty && fonts.isEmpty {
                Text(loc: "text.favorites.empty").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            }
            if !effects.isEmpty || !templates.isEmpty {
                LazyVGrid(columns: TextAssetTab.columns, spacing: 12) {
                    ForEach(effects) { d in
                        TextAssetTile(title: d.displayName, payload: DragPayload.textStyle(d.id),
                                      favorite: (AssetLibraryStore.textEffectsNamespace, d.id), add: { store.applyTextStyle(d) }) {
                            TextPreviewImage(key: "fx:\(d.id)", content: TextPreviewImage.style(d, sample: "ART"), fontPx: 44)
                        }
                    }
                    ForEach(templates) { d in
                        TextAssetTile(title: tr(d.nameKey), payload: DragPayload.textTemplate(d.id),
                                      favorite: (AssetLibraryStore.textTemplatesNamespace, d.id), add: { store.addTextTemplate(d) }) {
                            TextPreviewImage(key: "template:\(d.id)", content: d.makeContent(), fontPx: 34)
                        }
                    }
                }
            }
            ForEach(fonts, id: \.self) { name in
                HStack {
                    Text(verbatim: name).font(previewFont(name, size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(IStyle.curve)
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(Theme.segmentSelected, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { store.applyFontFromBook(name) }
                .testID("text.favfont.\(name)")
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        .testID("text.favorites")
    }
}

extension EditorStore {
    /// Font book click: the font goes on the selected text clip (else a hint).
    func applyFontFromBook(_ family: String) {
        guard let c = singleSelectedClip, case .text = c.content else { showToast(tr("fontbook.selectText")); return }
        TextUIState.shared.noteRecent(family)
        applyTextRunStyle(c.id, TextRunStyle(fontName: family), nameKey: "cmd.textFont")
    }

    func removeImportedFont(_ family: String) {
        let n = FontLibrary.remove(family: family)
        TextUIState.shared.fontsRevision += 1
        if TextUIState.shared.favoriteFonts.contains(family) { TextUIState.shared.favoriteFonts.removeAll { $0 == family } }
        showToast(tr(n > 0 ? "fontbook.removed" : "fontbook.removeFailed", family))
    }
}
