import SwiftUI
import AppKit
import Observation
import MontageCore

/// P1 project switcher ("I should have an easy way to access all my projects when I am in a project"): the centred
/// title-bar project name opens a searchable list of every project (⌘⇧O, File ▸ Switch Project…). Picking one switches
/// in the same window, CapCut-style (auto-save + close the current one, "Saved to project"); ⌘-Return / ⌥-click / ⧉
/// opens it in a new window (PM-014). Footer: New project (⌘N) · All projects = Home (⌘⇧H).
/// Ordering, status and the pre-close checks are the pure `ProjectSwitcherModel` (MontageCore).
@MainActor @Observable
public final class ProjectSwitcher {
    /// The switcher of this window's `AppModel` (the title bar has no `AppModel`).
    public static weak var active: ProjectSwitcher?

    @ObservationIgnored weak var app: AppModel?
    public private(set) var isOpen = false
    public var query = "" { didSet { if query != oldValue { queryChanged() } } }
    /// Query the rows are filtered with (= `query`, debounced 80 ms above 1000 projects).
    public private(set) var effectiveQuery = ""
    public var selected: Int?
    /// Lock / drive status per project path, taken when the popover opens (and after the listing refreshes).
    private(set) var statuses: [String: ProjectSwitcherModel.Status] = [:]
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init() {}

    // MARK: Rows

    public var rows: [ProjectSwitcherModel.Row] {
        guard let app else { return [] }
        let st = statuses
        return ProjectSwitcherModel.rows(app.entries, current: app.screen == .editor ? app.store.packageURL : nil, search: effectiveQuery,
                                         heldElsewhere: { st[$0.path] == .otherWindow }, offline: { st[$0.path] == .offline })
    }

    func refreshStatuses() {
        guard let app else { return }
        var s: [String: ProjectSwitcherModel.Status] = [:]
        for e in app.entries where e.trashedAt == nil {
            if ProjectSwitcherModel.isOffline(e.url) { s[e.url.path] = .offline } else if SessionLock.holderPID(e.url) != nil { s[e.url.path] = .otherWindow }
        }
        statuses = s
    }

    private func queryChanged() {
        debounce?.cancel()
        if (app?.entries.count ?? 0) <= 1000 { applyQuery(); return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.applyQuery()
        }
    }

    private func applyQuery() {
        effectiveQuery = query
        selected = ProjectSwitcherModel.initialSelection(rows)
    }

    // MARK: Open / close

    public func toggle() { if isOpen { close() } else { open() } }

    public func open() {
        guard let app, app.screen == .editor, app.modal == nil, !isOpen else { return }
        guard !app.store.session.isInGesture else { return }   // no switch in the middle of a drag
        refreshStatuses()
        query = ""
        effectiveQuery = ""
        selected = ProjectSwitcherModel.initialSelection(rows)
        isOpen = true
        app.refreshSoon(checkRecovery: false)   // in-memory entries now, the fresh listing a moment later
    }

    public func close() {
        guard isOpen else { return }
        debounce?.cancel()
        isOpen = false
        query = ""
        effectiveQuery = ""
        SnapshotRegistry.shared.modal = nil
        AppModel.endTextEditing()   // the search field gives the keyboard back to the editor
    }

    /// Opens row `i` here (or in a new window).
    public func activate(_ i: Int, newWindow: Bool = false) {
        let list = rows
        guard let app, list.indices.contains(i) else { return }
        let row = list[i]
        close()
        switch row.status {
        case .current: return
        case .otherWindow, .offline: app.open(row.entry.url)   // focus that window / explain, current project stays
        case .normal: if newWindow { app.openInNewWindow(row.entry.url) } else { app.open(row.entry.url) }
        }
    }

    public func newProject() { app?.newProjectFromAnywhere() }
    public func showHome() { close(); app?.backToHome() }

    /// Rename the current project: Project settings (Name), like Details ▸ Modify.
    func renameCurrent() { close(); app?.modal = .projectSettings }

    // MARK: Keys (app key monitor, before editor shortcuts; the search field's own key handlers call the same)

    func moveSelection(_ d: Int) { selected = ProjectSwitcherModel.move(selected, by: d, count: rows.count) }
    func submit(newWindow: Bool) { if let s = selected { activate(s, newWindow: newWindow) } }
    func escape() { if query.isEmpty { close() } else { query = "" } }

    /// Handles a key while the popover is open. True = consumed. Other keys go to the search field / menu bar, never
    /// to the editor shortcuts (typing goes to search).
    public func handle(_ e: NSEvent) -> Bool {
        guard isOpen, e.type == .keyDown else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 126: if mods.isEmpty { moveSelection(-1) }; return true            // ↑
        case 125: if mods.isEmpty { moveSelection(1) }; return true             // ↓
        case 36, 76: submit(newWindow: mods == .command); return true           // Return / ⌘-Return
        case 53: escape(); return true                                          // Esc
        default: break
        }
        // typing while the search field isn't focused still goes to the search
        guard !(e.window?.firstResponder is NSText), mods.subtracting(.shift).isEmpty else { return false }
        if e.keyCode == 51 { if !query.isEmpty { query.removeLast() }; return true }
        if let c = e.characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            query += c
            return true
        }
        return false
    }

    // MARK: Copy

    /// "Edited today 12:26" / "Edited yesterday" / "Edited 14 Oct" (app language).
    static func edited(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        if cal.isDate(d, inSameDayAs: now) {
            f.dateStyle = .none; f.timeStyle = .short
            return tr("switcher.edited", tr("switcher.today", f.string(from: d)))
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) {
            return tr("switcher.edited", tr("switcher.yesterday"))
        }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMy")
        return tr("switcher.edited", f.string(from: d))
    }

    /// UI tests use the sample library's fixed clock, so relative dates are the same on every run.
    static var now: Date { TestAnchors.isEnabled ? Date(timeIntervalSince1970: 1_768_478_400) : Date() }

    static func meta(_ r: ProjectSwitcherModel.Row, now: Date) -> String {
        var parts = [edited(r.entry.modifiedAt, now: now), HomeFormat.duration(r.entry.summary.duration)]
        if let d = r.disambiguation { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    /// `app.switcher` in the UI-test state dump.
    func stateDump() -> [String: Any] {
        [
            "isOpen": isOpen, "query": query, "selected": selected ?? -1,
            "rows": rows.map { ["name": $0.entry.name, "status": $0.status.rawValue, "current": $0.isCurrent] as [String: Any] },
        ]
    }
}

// MARK: - Title-bar button

/// The centred project name in the title bar: "1019 ⌄" (12 pt semibold + 9 pt chevron), click = the switcher.
struct ProjectSwitcherButton: View {
    @Bindable var store: EditorStore
    @State private var hover = false
    var body: some View {
        if let sw = ProjectSwitcher.active {
            Button { sw.toggle() } label: {
                HStack(spacing: 5) {
                    Text(verbatim: store.projectName)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(hex: 0x8A8A8E))
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(hover || sw.isOpen ? Color(hex: 0x2A2A2E) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tr("switcher.help"))
            .accessibilityLabel(Text(verbatim: store.projectName))
            .accessibilityHint(Text(verbatim: tr("switcher.help")))
            .testID("titlebar.projectSwitcher")
            // the name truncates before it reaches EditPilot / Export in narrow windows (160–420 pt)
            .containerRelativeFrame(.horizontal) { w, _ in min(420, max(160, w - 700)) }
        } else {
            Text(verbatim: store.projectName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Popover

/// In-window popover under the title (arrow-less, 6 pt below the title bar), over a transparent click-away backdrop.
/// In-window (not an NSPopover) so it renders in offscreen UI-test snapshots like the other in-window modals.
struct ProjectSwitcherOverlay: View {
    @Bindable var switcher: ProjectSwitcher
    var body: some View {
        if switcher.isOpen, let app = switcher.app {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).contentShape(Rectangle())
                    .onTapGesture { switcher.close() }
                    .accessibilityHidden(true)
                GeometryReader { g in
                    // whole-point x (crisp text, stable snapshots in odd-width windows)
                    ProjectSwitcherPopover(switcher: switcher, app: app)
                        .padding(.top, Theme.Metrics.titleBarHeight + 6)
                        .padding(.leading, ((g.size.width - 380) / 2).rounded(.down))
                }
            }
        }
    }
}

struct ProjectSwitcherPopover: View {
    @Bindable var switcher: ProjectSwitcher
    @Bindable var app: AppModel
    static let rowHeight: CGFloat = 52

    var body: some View {
        let rows = switcher.rows
        let now = ProjectSwitcher.now
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Color(hex: 0x333333)).frame(height: 1)
            if rows.isEmpty {
                Text(verbatim: tr("home.empty.search", switcher.effectiveQuery))
                    .font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A8E))
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .testID("switcher.empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                ProjectSwitcherRow(switcher: switcher, row: r, index: i, meta: ProjectSwitcher.meta(r, now: now),
                                                   isSelected: switcher.selected == i)
                                    .id(i)
                            }
                            if rows.count == 1, rows[0].isCurrent, switcher.effectiveQuery.isEmpty {
                                Text(loc: "switcher.empty.only").font(.system(size: 11)).foregroundStyle(Color(hex: 0x8A8A8E))
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .testID("switcher.empty")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 8 + (rows.count == 1 && rows[0].isCurrent ? 40 : 0), 7.5 * Self.rowHeight))
                    .onChange(of: switcher.selected) { _, s in if let s { proxy.scrollTo(s) } }
                }
            }
            Rectangle().fill(Color(hex: 0x333333)).frame(height: 1)
            footer
        }
        .frame(width: 380)
        .background(Color(hex: 0x1F1F22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0x333333)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(TestAnchors.isEnabled ? 0 : 0.45), radius: TestAnchors.isEnabled ? 0 : 18, y: 8)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { SnapshotRegistry.shared.modal = ($0, 0) }
        .onChange(of: app.entries) { _, _ in switcher.refreshStatuses() }
        .accessibilityElement(children: .contain)
        .testID("switcher.popover")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A8E))
                .accessibilityHidden(true)
            SwitcherSearchField(switcher: switcher, placeholder: tr("home.search.placeholder"))
                .frame(height: 22)
                .accessibilityLabel(Text(loc: "home.search.placeholder"))
                .testID("switcher.search")
            Text(verbatim: Keymap.shared.binding(for: "menu.switchProject")?.display ?? "")
                .font(.system(size: 11)).foregroundStyle(Color(hex: 0x6A6A6E))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("plus", "switcher.newProject", Keymap.shared.binding(for: "menu.new")?.display, id: "switcher.newProject") { switcher.newProject() }
            Rectangle().fill(Color(hex: 0x333333)).frame(width: 1, height: 20)
            footerButton("house", "switcher.home", Keymap.shared.binding(for: "menu.home")?.display, id: "switcher.home") { switcher.showHome() }
        }
        .frame(height: 36)
    }

    private func footerButton(_ icon: String, _ key: String, _ shortcut: String?, id: String, _ action: @escaping () -> Void) -> some View {
        FooterButton(icon: icon, title: tr(key), shortcut: shortcut, action: action).testID(id)
    }
}

private struct FooterButton: View {
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(verbatim: title)
                Spacer(minLength: 4)
                if let shortcut { Text(verbatim: shortcut).foregroundStyle(Color(hex: 0x6A6A6E)).accessibilityHidden(true) }
            }
            .font(.system(size: 12)).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hover ? Color(hex: 0x2A2A2E) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(verbatim: title))
    }
}

struct ProjectSwitcherRow: View {
    @Bindable var switcher: ProjectSwitcher
    let row: ProjectSwitcherModel.Row
    let index: Int
    let meta: String
    let isSelected: Bool
    @State private var hover = false

    var body: some View {
        let e = row.entry
        HStack(spacing: 10) {
            CoverView(entry: e).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: e.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: meta).font(.system(size: 11)).foregroundStyle(Color(hex: 0x8A8A8E)).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: ProjectSwitcherPopover.rowHeight)
        .background(isSelected ? Theme.accent.opacity(0.18) : (hover ? Color(hex: 0x2A2A2E) : .clear))
        .opacity(row.status == .offline ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            let opt = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            switcher.activate(index, newWindow: opt)
        }
        .contextMenu {
            if row.isCurrent { Button(tr("switcher.rename")) { switcher.renameCurrent() } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [e.name, meta, statusText].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { switcher.activate(index) }
        .testID("switcher.row.\(index)")
    }

    private var statusText: String? {
        switch row.status {
        case .normal, .current: return nil
        case .otherWindow: return tr("switcher.otherWindow")
        case .offline: return tr("switcher.offline")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.status {
        case .current:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        case .otherWindow:
            badge("macwindow.on.rectangle", tr("switcher.otherWindow"))
        case .offline:
            badge("eject", tr("switcher.offline"))
        case .normal:
            if hover {
                Button { switcher.activate(index, newWindow: true) } label: {
                    Image(systemName: "macwindow.badge.plus").font(.system(size: 13)).foregroundStyle(Color(hex: 0xC8C8CC))
                        .frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("switcher.newWindow"))
                .accessibilityLabel(Text(verbatim: tr("switcher.newWindow")))
                .testID("switcher.row.\(index).newWindow")
            }
        }
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(verbatim: text).font(.system(size: 10))
        }
        .foregroundStyle(Color(hex: 0x8A8A8E))
        .accessibilityHidden(true)
    }
}


/// The search field (AppKit, so its keys work whichever way they reach the field editor — real typing, or the UI test
/// driver delivering them straight to the field): ↑ / ↓ move the selection, Return / ⌘-Return open, Esc clears then closes.
/// Focused as soon as it is in the window ("typing goes to search").
struct SwitcherSearchField: NSViewRepresentable {
    @Bindable var switcher: ProjectSwitcher
    let placeholder: String

    func makeNSView(context: Context) -> FocusingTextField {
        let f = FocusingTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 12)
        f.textColor = .white
        f.cell?.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(srgbRed: 0x8A / 255.0, green: 0x8A / 255.0, blue: 0x8E / 255.0, alpha: 1), .font: NSFont.systemFont(ofSize: 12)])
        f.delegate = context.coordinator
        f.setAccessibilityIdentifier("switcher.search")
        return f
    }

    func updateNSView(_ f: FocusingTextField, context: Context) {
        context.coordinator.switcher = switcher
        if f.stringValue != switcher.query { f.stringValue = switcher.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(switcher: switcher) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var switcher: ProjectSwitcher
        init(switcher: ProjectSwitcher) { self.switcher = switcher }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            if switcher.query != f.stringValue { switcher.query = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): switcher.moveSelection(-1)
            case #selector(NSResponder.moveDown(_:)): switcher.moveSelection(1)
            // closing removes this field: do it after the field editor finished handling the key
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let nw = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                let sw = switcher
                DispatchQueue.main.async { sw.submit(newWindow: nw) }
            case #selector(NSResponder.cancelOperation(_:)):
                let sw = switcher
                DispatchQueue.main.async { sw.escape() }
            default: return false
            }
            return true
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
        }
    }
}
