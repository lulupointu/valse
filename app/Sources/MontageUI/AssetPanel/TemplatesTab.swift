import SwiftUI
import MontageCore

/// A video template card (TP-001). The templates team registers these with `TemplateLibrary.register`; the tab
/// (search, categories, Orientation / Clips / Duration filters, favourites, recent, hover preview) is generic.
public struct TemplateDescriptor: Identifiable, Sendable {
    public let id: String
    public let nameKey: String
    /// Category key (localized), e.g. "template.cat.trending".
    public let categoryKey: String
    /// Canvas width / height (9:16 portrait, 16:9 landscape, 1 square).
    public let aspect: Double
    public let clipCount: Int
    public let duration: Time
    public var featured: Bool
    public var tags: [String]
    public let cover: @Sendable () async -> CGImage?
    public var previewFrames: (@Sendable () async -> [CGImage])?
    /// Applies the template (e.g. opens it as a project / inserts its clips).
    public let apply: @MainActor (EditorStore) -> Void

    public init(id: String, nameKey: String, categoryKey: String, aspect: Double, clipCount: Int, duration: Time,
                featured: Bool = false, tags: [String] = [], cover: @escaping @Sendable () async -> CGImage?,
                previewFrames: (@Sendable () async -> [CGImage])? = nil, apply: @escaping @MainActor (EditorStore) -> Void) {
        self.id = id; self.nameKey = nameKey; self.categoryKey = categoryKey; self.aspect = aspect; self.clipCount = clipCount
        self.duration = duration; self.featured = featured; self.tags = tags; self.cover = cover; self.previewFrames = previewFrames
        self.apply = apply
    }
}

@MainActor
public enum TemplateLibrary {
    public private(set) static var all: [TemplateDescriptor] = []
    /// Category rail order (CapCut: Trending, Vlog, Travel, Selfie…).
    public static var categories: [String] = ["trending", "vlog", "travel", "birthday", "business", "lyrics", "intro", "social"]
        .map { "template.cat.\($0)" }

    public static func register(_ t: TemplateDescriptor) {
        all.removeAll { $0.id == t.id }
        all.append(t)
        if !categories.contains(t.categoryKey) { categories.append(t.categoryKey) }
    }

    public enum Orientation: String, CaseIterable, Sendable { case all, landscape, portrait, square }
    public enum Clips: String, CaseIterable, Sendable { case any, one, few, several, many }
    public enum Length: String, CaseIterable, Sendable { case any, short, medium, long, veryLong }

    public static func matches(_ t: TemplateDescriptor, _ o: Orientation, _ c: Clips, _ l: Length) -> Bool {
        let okO: Bool
        switch o {
        case .all: okO = true
        case .landscape: okO = t.aspect > 1.05
        case .portrait: okO = t.aspect < 0.95
        case .square: okO = abs(t.aspect - 1) <= 0.05
        }
        let okC: Bool
        switch c {
        case .any: okC = true
        case .one: okC = t.clipCount == 1
        case .few: okC = (2...3).contains(t.clipCount)
        case .several: okC = (4...5).contains(t.clipCount)
        case .many: okC = t.clipCount >= 6
        }
        let s = t.duration.seconds
        let okL: Bool
        switch l {
        case .any: okL = true
        case .short: okL = s < 15
        case .medium: okL = s >= 15 && s < 30
        case .long: okL = s >= 30 && s < 60
        case .veryLong: okL = s >= 60
        }
        return okO && okC && okL
    }
}

/// Asset panel ▸ Templates (UX.md §3.11).
struct TemplatesTab: View {
    let store: EditorStore
    @State private var orientation: TemplateLibrary.Orientation = .all
    @State private var clips: TemplateLibrary.Clips = .any
    @State private var length: TemplateLibrary.Length = .any

    var body: some View {
        let list = TemplateLibrary.all.filter { TemplateLibrary.matches($0, orientation, clips, length) }
        let sections = TemplateLibrary.categories.map { cat in
            LibrarySection(id: cat, title: tr(cat), items: list.filter { $0.categoryKey == cat }.map(item))
        }
        LibraryBrowser(tab: "templates", namespace: "templates", sections: sections, style: .wide(9.0 / 16.0),
                       searchPlaceholder: tr("templates.search"),
                       emptyHint: TemplateLibrary.all.isEmpty ? tr("templates.empty") : tr("templates.empty.filtered")) {
            HStack(spacing: 10) {
                filterMenu("templates.filter.orientation", $orientation, TemplateLibrary.Orientation.allCases)
                filterMenu("templates.filter.clips", $clips, TemplateLibrary.Clips.allCases)
                filterMenu("templates.filter.duration", $length, TemplateLibrary.Length.allCases)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    func item(_ t: TemplateDescriptor) -> LibraryItem {
        LibraryItem(id: t.id, title: tr(t.nameKey), subtitle: tr("templates.clips", t.clipCount), keywords: [tr(t.categoryKey)] + t.tags,
                    badge: Timecode.shortDuration(t.duration),
                    art: .async(key: "template.\(t.id)", load: { await t.cover() }, placeholder: "rectangle.stack"),
                    hoverFrames: t.previewFrames.map { f in { await f() } },
                    add: { [store] in t.apply(store) })
    }

    func filterMenu<V: RawRepresentable & Hashable>(_ key: String, _ value: Binding<V>, _ all: [V]) -> some View where V.RawValue == String {
        Menu {
            Picker(tr(key), selection: value) {
                ForEach(all, id: \.self) { v in Text(loc: "\(key).\(v.rawValue)").tag(v) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: tr(key)).foregroundStyle(Theme.textTertiary)
                Text(verbatim: tr("\(key).\(value.wrappedValue.rawValue)")).foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .testID("templates.filter.\(key.split(separator: ".").last ?? "")")
    }
}
