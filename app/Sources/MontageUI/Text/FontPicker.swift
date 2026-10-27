import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine
import Perception

/// Text ▸ Basic ▸ Font: full-width button with the current family (+ ⇕ to step through fonts) that opens a searchable
/// list with live previews: Imported · Favourites · Recently used · All fonts, and "Import font…" (TX-002).
struct FontRow: View {
    let ctx: InspectorContext
    @State private var open = false

    var body: some View {
        WithPerceptionTracking {
            let font = currentFont
            InlineRow(label: tr("text.font")) {
                HStack(spacing: 4) {
                    Button { open.toggle() } label: {
                        Text(verbatim: FontCatalog.displayName(font) ?? tr("text.font.system"))
                            .font(previewFont(font, size: 12))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(IStyle.dropdown, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $open, arrowEdge: .leading) {
                        WithPerceptionTracking {
                            FontPickerList(selected: font) { name in apply(name) }.valsePopoverSurface()
                        }
                    }
                    StepperButton { d in step(d) }
                }
            }
        }
    }

    var currentFont: String {
        guard let c = ctx.clip, case .text(let t) = c.content else { return "" }
        if let sel = TextUIState.shared.selection[c.id], sel.length > 0, let f = t.commonStyle(in: sel).fontName { return f }
        return t.fontName
    }

    func apply(_ name: String) {
        guard let id = ctx.clip?.id else { return }
        TextUIState.shared.noteRecent(name)
        ctx.store.applyTextRunStyle(id, TextRunStyle(fontName: name), nameKey: "cmd.textFont")
    }

    func step(_ d: Int) {
        let all = [""] + FontCatalog.families.map(\.name)
        let cur = all.firstIndex(of: FontCatalog.displayName(currentFont) ?? "") ?? 0
        apply(all[(cur - d + all.count) % all.count])
    }
}

func previewFont(_ name: String, size: CGFloat) -> Font {
    name.isEmpty ? .system(size: size) : .custom(name, size: size)
}

struct FontPickerList: View {
    let selected: String
    let pick: (String) -> Void
    @Perception.Bindable private var ui = TextUIState.shared

    var body: some View {
        WithPerceptionTracking {
                    let _rev = ui.fontsRevision  // re-list after an import
            let q = ui.fontSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let all = _rev >= 0 ? FontCatalog.families : []
            let match: (String) -> Bool = { q.isEmpty || $0.lowercased().contains(q) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                    TextField(tr("text.font.search"), text: $ui.fontSearch).textFieldStyle(.plain).font(.system(size: 12))
                    PillButton(title: tr("text.font.import"), symbol: "plus") { importFonts() }
                }
                .padding(8)
                .background(IStyle.field)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if q.isEmpty || match(tr("text.font.system")) {
                            row("", title: tr("text.font.system"))
                        }
                        let imported = all.filter(\.isImported).map(\.name).filter(match)
                        if !imported.isEmpty { section(tr("text.font.imported"), imported) }
                        let fav = ui.favoriteFonts.filter(match)
                        if !fav.isEmpty { section(tr("text.font.favorites"), fav) }
                        let recent = ui.recentFonts.filter(match)
                        if !recent.isEmpty, q.isEmpty { section(tr("text.font.recent"), recent) }
                        section(tr("text.font.all"), all.filter { !$0.isImported }.map(\.name).filter(match))
                    }
                }
            }
            .frame(width: 280, height: 420)
            .background(Theme.panel)
        }
    }

    @ViewBuilder func section(_ title: String, _ names: [String]) -> some View {
        Section {
            ForEach(names, id: \.self) { name in WithPerceptionTracking { row(name, title: name) } }
        } header: {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(IStyle.caption)
                .padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
        }
    }

    func row(_ name: String, title: String) -> some View {
        let isSel = (FontCatalog.displayName(selected) ?? "") == name || selected == name
        let fav = TextUIState.shared.favoriteFonts.contains(name)
        return HStack {
            Text(verbatim: title).font(previewFont(name, size: 15)).foregroundStyle(isSel ? Theme.accent : Theme.textPrimary).lineLimit(1)
            Spacer()
            if !name.isEmpty {
                Image(systemName: fav ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(fav ? IStyle.curve : IStyle.iconDim)
                    .onTapGesture {
                        let ui = TextUIState.shared
                        if fav { ui.favoriteFonts.removeAll { $0 == name } } else { ui.favoriteFonts.append(name) }
                    }
                    .help(tr("text.font.favorite"))
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(isSel ? Theme.accentDim.opacity(0.35) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { pick(name) }
    }

    func importFonts() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = true
        p.begin { r in
            guard r == .OK else { return }
            let urls = p.urls
            Task { @MainActor in
                if let names = try? FontCatalog.importFonts(urls), let first = names.first {
                    TextUIState.shared.fontsRevision += 1
                    pick(first)
                }
            }
        }
    }
}
