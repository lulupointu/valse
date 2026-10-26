import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import Perception

/// Home screen (UX.md §2.1, [02]): sidebar (Home, Templates, folders, Trash), the "New project" hero, and the project
/// grid/list with search, sort, view toggle, hover "…" menus, multi-selection, drag & drop import, empty state.
struct HomeView: View {
    @Perception.Bindable var app: AppModel

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                HomeSidebar(app: app).frame(width: 215)
                ZStack(alignment: .top) {
                    switch app.section {
                    case .projects: ProjectsColumn(app: app)
                    case .templates: TemplatesPlaceholder(app: app)
                    }
                    HomeTopBar(app: app)
                }
            }
            .background(Theme.Valse.canvas)
            .overlay { ShortsWizardHost(app: app) }   // AI2 (AI-031)
            .overlay(alignment: .top) { ToastView(toast: app.store.toast).padding(.top, 54) }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                HomeDrop.load(providers) { urls in
                    let projects = urls.filter { ["montage", "zip"].contains($0.pathExtension.lowercased()) }
                    if !projects.isEmpty { app.importProjects(projects) }
                }
                return true
            }
            .task { if !app.hasScanned { await app.refresh() } } .task { await ValseDebugClock.shared.recordIfRequested() }   // review videos only (VALSE_DEBUG_FRAMES)
        }
    }
}

enum HomeDrop {
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let box = HomeURLBox()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { box.append(u) }; group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
    }
}

nonisolated final class HomeURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func append(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}

// MARK: - Sidebar

struct HomeSidebar: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ValseMark(small: true).frame(width: 42, height: 42).padding(.vertical, -4)
                    Text(verbatim: "Valse").font(Theme.Valse.Fonts.wordmark).foregroundStyle(Theme.Valse.cream)
                }
                .padding(.top, 40).padding(.bottom, 22).padding(.leading, 2)
                .accessibilityElement(children: .combine)
                Text(loc: "home.videoEditing").font(Theme.Valse.Fonts.overline).foregroundStyle(Theme.Valse.text3)
                    .textCase(.uppercase).tracking(0.6).padding(.leading, 8).padding(.bottom, 6)
                NavItem(symbol: "house", title: tr("home.nav.home"), selected: app.section == .projects && app.scope == .all, id: "home") {
                    app.section = .projects; app.scope = .all
                }
                NavItem(symbol: "clock", title: tr("home.nav.recents"), selected: app.section == .projects && app.scope == .recents, id: "recents") {
                    app.section = .projects; app.scope = .recents
                }
                NavItem(symbol: "rectangle.stack", title: tr("home.nav.templates"), selected: app.section == .templates, id: "templates") { app.section = .templates }
                Rectangle().fill(Theme.Valse.stroke).frame(height: 1).padding(.vertical, 12).padding(.horizontal, 8)
                HStack {
                    Text(loc: "home.folders").font(Theme.Valse.Fonts.overline).foregroundStyle(Theme.Valse.text3).textCase(.uppercase).tracking(0.6)
                    Spacer()
                    Button { app.modal = .newFolder } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Valse.text2).help(tr("home.folder.create")).testID("home.folder.add")
                }
                .padding(.leading, 8).padding(.trailing, 4).padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(app.folders.enumerated()), id: \.element.id) { i, f in
                            WithPerceptionTracking {
                                NavItem(symbol: "folder", title: f.name, selected: app.section == .projects && app.scope == .folder(f.id),
                                        badge: app.entries.filter { $0.folderID == f.id && $0.trashedAt == nil }.count, id: "folder.\(i)",
                                        tint: ValsePlayfulTint.folder(i)) {
                                    app.section = .projects; app.scope = .folder(f.id)
                                }
                                .contextMenu {
                                    Button(tr("home.folder.rename")) { app.modal = .renameFolder(f) }
                                    Button(tr("home.folder.delete")) { app.deleteFolder(f) }
                                }
                                .dropDestination(for: String.self) { ids, _ in
                                    app.move(app.entries.filter { ids.contains($0.id) }, to: f.id); return true
                                }
                            }
                        }
                        if app.folders.isEmpty {
                            Text(loc: "home.folders.empty").font(Theme.Valse.Fonts.caption).foregroundStyle(Theme.Valse.text3)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
                Spacer(minLength: 8)
                NavItem(symbol: "trash", title: tr("home.nav.trash"), selected: app.section == .projects && app.scope == .trash,
                        badge: app.trashCount, id: "trash") { app.section = .projects; app.scope = .trash }
                    .dropDestination(for: String.self) { ids, _ in app.trash(app.entries.filter { ids.contains($0.id) }); return true }
                NavItem(symbol: "gearshape", title: tr("settings.title"), selected: false, id: "settings") { app.modal = .settings(.general) }
                    .padding(.bottom, 14)
            }
            .padding(.horizontal, 14)
            .background(Theme.Valse.sidebar)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.Valse.stroke).frame(width: 1) }
        }
    }
}

struct NavItem: View {
    let symbol: String
    let title: String
    let selected: Bool
    var badge: Int = 0
    var id: String = ""
    /// Idle icon tint (folders rotate through the palette).
    var tint: Color? = nil
    let action: () -> Void
    @State private var hoverState = false
    var body: some View {
        WithPerceptionTracking {
            let hover = ValseDebugHover.merge(hoverState, "nav.\(id)")
            let r = ValseShape.control
            Button(action: action) {
                ValseTween(on: hover && !selected, response: 0.34, damping: 0.5) { p in
                    HStack(spacing: 10) {
                        Image(systemName: symbol).font(.system(size: 13, weight: selected ? .bold : .regular))
                            .foregroundStyle(selected ? Theme.Valse.ink : (tint ?? Theme.Valse.text2))
                            .scaleEffect(1 + 0.12 * p)
                            .frame(width: 18)
                        Text(verbatim: title).font(.system(size: 13, weight: selected ? .bold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if badge > 0 { Text(verbatim: "\(badge)").font(.system(size: 11, weight: selected ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(selected ? Theme.Valse.ink : Theme.Valse.text3) }
                    }
                }
                .foregroundStyle(selected ? Theme.Valse.ink : Theme.Valse.text2)
                .padding(.leading, 12).padding(.trailing, 10).frame(height: 34)
                .background(!selected && hover ? Theme.Valse.surface : .clear, in: RoundedRectangle(cornerRadius: r))
                // Selected = flat mint sticker on a solid teal offset block, ink + bold (block + offset + weight: not hue only).
                .valseSticker(selected, radius: r)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .valseHover($hoverState)
            .testID("home.nav.\(id)")
        }
    }
}

// MARK: - Top bar

struct HomeTopBar: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 14) {
                Spacer()
                IconButton("square.and.arrow.down", help: tr("home.importProject")) { app.importProjectPanel() }.testID("home.top.import")
                IconButton("keyboard", help: tr("keymap.title")) { app.modal = .shortcuts }.testID("home.top.shortcuts")
                IconButton("gearshape", help: tr("settings.title")) { app.modal = .settings(.general) }.testID("home.top.settings")
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .padding(.top, 2)
        }
    }
}

// MARK: - Main column

struct ProjectsColumn: View {
    @Perception.Bindable var app: AppModel

    var body: some View {
        WithPerceptionTracking {
            let list = app.visibleEntries
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SaveFolderBanner(app: app)   // PM-009
                    if app.scope == .all || app.scope == .recents {
                        NewProjectHero(app: app)
                        HomeFeatureRow(app: app)
                    }
                    ProjectsHeader(app: app, count: list.count)
                    if !app.hasScanned {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if list.isEmpty {
                        EmptyProjects(app: app)
                    } else if app.viewMode == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98, maximum: 118), spacing: 24, alignment: .top)], alignment: .leading, spacing: 22) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in WithPerceptionTracking { ProjectCard(app: app, entry: e, all: list).testID("home.card.\(i)") } }
                        }
                    } else {
                        ProjectListHeader(app: app)
                        LazyVStack(spacing: 5) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in WithPerceptionTracking { ProjectRow(app: app, entry: e, all: list).testID("home.row.\(i)") } }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 40)
            }
            .scrollIndicators(.automatic)
            .background(Theme.Valse.canvas)
            .contentShape(Rectangle())
            .onTapGesture { app.selectedIDs = []; app.renamingID = nil }
            .overlay(alignment: .bottom) { if app.selectedIDs.count > 1 { SelectionBar(app: app) } }
        }
    }
}

extension AppModel {
    var selectedEntries: [LibraryEntry] { visibleEntries.filter { selectedIDs.contains($0.id) } }

    /// ⌫ on Home: move the selection to the Trash (in the Trash: delete permanently).
    public func trashOrDeleteSelection() {
        let items = selectedEntries
        guard !items.isEmpty, renamingID == nil, modal == nil, screen == .home else { return }
        if scope == .trash { deletePermanently(items) } else { trash(items) }
    }

    /// Click handling: plain click opens, ⌘-click toggles, ⇧-click extends the selection.
    func click(_ e: LibraryEntry, in list: [LibraryEntry]) {
        let mods = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags  // the click's own modifiers
        if mods.contains(.command) {
            if selectedIDs.contains(e.id) { selectedIDs.remove(e.id) } else { selectedIDs.insert(e.id) }
        } else if mods.contains(.shift), let anchor = list.firstIndex(where: { selectedIDs.contains($0.id) }),
                  let i = list.firstIndex(of: e) {
            selectedIDs = Set(list[min(anchor, i)...max(anchor, i)].map(\.id))
        } else if scope == .trash {
            selectedIDs = [e.id]
        } else {
            open(e.url)
        }
    }

    /// The items a card's menu acts on: the selection if the card is in it, else the card.
    func targets(_ e: LibraryEntry) -> [LibraryEntry] { selectedIDs.contains(e.id) && selectedIDs.count > 1 ? selectedEntries : [e] }
}

/// The "+ New project" hero: one click → editor. The Custom chip opens the settings dialog. The ribbon draws itself in
/// once per launch, then idles (slow film, the loop swelling in 3/4); hover speeds the film up.
struct NewProjectHero: View {
    @Perception.Bindable var app: AppModel
    @State private var hoverState = false
    var body: some View {
        WithPerceptionTracking {
            let hover = ValseDebugHover.merge(hoverState, "hero")
            let r = ValseShape.hero
            Button { app.newProject() } label: {
                ZStack(alignment: .leading) {
                    let bg = hover ? Theme.Valse.raised : Theme.Valse.surface
                    bg
                    ValseHeroRibbon(hover: hover, background: bg)
                    HStack(spacing: 16) {
                        // "+" tile: pops up off a solid orange offset block and spins a quarter turn on hover (spring).
                        ValseTween(on: hover, response: 0.45, damping: 0.55) { p in
                            RoundedRectangle(cornerRadius: 14).fill(Theme.Valse.mustard).frame(width: 44, height: 44)
                                .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Valse.ink)
                                    .rotationEffect(.degrees(90 * p)))
                                .offset(x: -2 * p, y: -2 * p)
                                .valseHardShadow(Theme.Valse.orange, radius: 14, depth: 2 * max(0, p))   // 4 pt apart at rest-hover
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc: "home.newProject").font(Theme.Valse.Fonts.heroTitle).foregroundStyle(Theme.Valse.text)
                            Text(loc: "home.playful.hero.subtitle").font(.system(size: 12.5)).foregroundStyle(Theme.Valse.text2)
                        }
                    }
                    .padding(.leading, 28)
                }
                .frame(height: 164)
                .clipShape(RoundedRectangle(cornerRadius: r))
                .overlay(RoundedRectangle(cornerRadius: r).stroke(hover ? Theme.Valse.controlHover : Theme.Valse.stroke))
                .contentShape(Rectangle())
            }
            .buttonStyle(ValseSquashStyle())
            .valseHover($hoverState)
            .overlay(alignment: .topTrailing) {
                Button { app.modal = .newProject } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        Text(loc: "home.newProject.custom")
                    }
                }
                .buttonStyle(ValseSecondaryButtonStyle(compact: true))
                .help(tr("home.newProject.customHelp"))
                .testID("home.newProject.custom")
                .padding(14)
            }
            .accessibilityLabel(Text(loc: "home.newProject"))
            .testID("home.newProject")
        }
    }
}

/// Feature cards (CapCut's Agent Hub / Video Studio row): Templates entry point, Import project.
struct HomeFeatureRow: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 14) {
                FeatureCard(symbol: "rectangle.stack.badge.play", tint: Theme.Valse.teal, tileBlock: FeatureCard.tealShade, motion: .fan, debugID: "feature0", title: tr("home.nav.templates"), subtitle: tr("home.templates.subtitle")) { app.section = .templates }
                    .testID("home.feature.templates")
                FeatureCard(symbol: "square.and.arrow.down.on.square", tint: Theme.Valse.mustard, tileBlock: Theme.Valse.orange, motion: .drop, debugID: "feature1", title: tr("home.importProject"), subtitle: tr("home.importProject.subtitle")) { app.importProjectPanel() }
                    .testID("home.feature.import")
                // AI2 (AI-031): Long video to shorts wizard (ShortsWizard.swift)
                FeatureCard(symbol: "scissors.badge.ellipsis", tint: Theme.Valse.orange, tileBlock: Theme.Valse.burgundy, motion: .snip, debugID: "feature2", title: tr("shorts.title"), subtitle: tr("shorts.subtitle")) { ShortsWizardState.shared.present() }
                    .testID("home.feature.shorts")
                Spacer(minLength: 0)
            }
        }
    }
}

/// Round 5: a feature card is a flat key. Hover lifts it 2 pt up-left off a solid, muted block of its colour (zero
/// blur) and pops its icon tile a further 1.5 pt off the tile's own block, like the "+" tile on the hero; press pushes
/// the whole card down-right onto where its block was (the block disappears under it), release springs it back up.
/// Hover → press → release is one continuous spring (`ValseLift`), nothing clamped. No coloured outline: the border
/// only brightens to a cream hairline.
struct FeatureCard: View {
    let symbol: String
    var tint: Color = Theme.Valse.teal
    /// The icon tile's solid block: its darker warm partner (mustard on orange, as the "+" tile; orange on burgundy),
    /// teal on its own shade (teal half printed over ink: a red or orange fringe under teal read as misregistration).
    var tileBlock: Color = Theme.Valse.burgundy
    static let tealShade = Color(hex: 0x20604E)
    /// The icon's small themed motion while lifted.
    enum Motion { case fan, drop, snip }
    var motion: Motion = .fan
    var debugID = ""
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hoverState = false
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                FeatureCardFace(symbol: symbol, tint: tint, tileBlock: tileBlock, motion: motion, debugID: debugID,
                                title: title, subtitle: subtitle, hover: ValseDebugHover.merge(hoverState, debugID))
            }
            .buttonStyle(ValsePressReportingStyle())
            .valseHover($hoverState)
        }
    }
}

private struct FeatureCardFace: View {
    let symbol: String
    let tint: Color
    let tileBlock: Color
    let motion: FeatureCard.Motion
    let debugID: String
    let title: String
    let subtitle: String
    let hover: Bool
    @Environment(\.valsePressed) private var pressed
    @ObservedObject private var clock = ValseDebugClock.shared

    static let depth: CGFloat = 2, tileDepth: CGFloat = 1.5

    var body: some View {
        let r = ValseShape.card
        let state = clock.liftState(debugID) ?? ValseLift.state(hover: hover, pressed: pressed)
        let k = ValseLift.spring(to: state)
        let lit = state == .hover || state == .pressed
        ValseSpringValue(target: ValseLift.target(state), response: k.response, damping: k.damping,
                         debugEvents: clock.liftEvents(debugID)) { v in
            let up = max(0, v)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 11).fill(tint).frame(width: 34, height: 34)
                    .overlay(icon(up))
                    .offset(x: ValseLift.offset(up, depth: Self.tileDepth), y: ValseLift.offset(up, depth: Self.tileDepth))
                    .background(RoundedRectangle(cornerRadius: 11).fill(tileBlock)
                        .offset(x: ValseLift.block(v, depth: Self.tileDepth), y: ValseLift.block(v, depth: Self.tileDepth))
                        .opacity(ValseLift.showsBlock(v) ? 1 : 0))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(Theme.Valse.Fonts.cardTitle).foregroundStyle(Theme.Valse.text)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Text(verbatim: subtitle).font(Theme.Valse.Fonts.caption).foregroundStyle(Theme.Valse.text2).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(width: 300, height: 72)
            // flat fill: a wash of the card colour on the surface (no gradient), a touch stronger while lit
            .background(RoundedRectangle(cornerRadius: r).fill(tint.opacity(lit ? 0.14 : 0.10))
                .background(RoundedRectangle(cornerRadius: r).fill(Theme.Valse.surface)))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(lit ? Theme.Valse.cream.opacity(0.22) : Theme.Valse.stroke))
            .offset(x: ValseLift.offset(v, depth: Self.depth), y: ValseLift.offset(v, depth: Self.depth))
            .background(RoundedRectangle(cornerRadius: r).fill(tint.opacity(0.42))
                .offset(x: ValseLift.block(v, depth: Self.depth), y: ValseLift.block(v, depth: Self.depth))
                .opacity(ValseLift.showsBlock(v) ? 1 : 0))
        }
        // the lifted / pressed card and its block stay inside the hit area
        .contentShape(Rectangle().inset(by: -Self.depth))
    }

    /// One monotone motion per card, driven by the lift (0 at rest and while pressed, follows the spring's single
    /// small overshoot): the template stack fans out, the import arrow sinks into its tray, the scissors tilt into a cut.
    @ViewBuilder private func icon(_ up: Double) -> some View {
        let glyph = Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Valse.ink)
        switch motion {
        case .fan:
            ZStack {
                glyph.opacity(0.4 * min(1, up)).rotationEffect(.degrees(14 * up)).offset(x: 2.5 * up)
                glyph.rotationEffect(.degrees(-12 * up)).offset(x: -1.5 * up)
            }
        case .drop:
            glyph.offset(y: 2.5 * up)
        case .snip:
            glyph.rotationEffect(.degrees(-14 * up)).offset(x: 1.5 * up)
        }
    }
}

/// Press feedback for the hero: a small springy squash.
struct ValseSquashStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ValseSquash(pressed: configuration.isPressed) { configuration.label } }
}

private struct ValseSquash<Label: View>: View {
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        label()
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.6), value: pressed)
    }
}

/// The hero's ribbon, animated: draws itself in once per launch (2 s), then idles (film advancing slowly); hover speeds
/// the film up. The loop's shape never moves. Paused while the window is inactive; static final frame under Reduce
/// Motion, in UI tests and in plain screenshots.
struct ValseHeroRibbon: View {
    let hover: Bool
    let background: Color
    @ObservedObject private var clock = ValseDebugClock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var introStart: Date? = ValseHeroRibbon.introPlayed ? nil : Date()
    @State private var introDone = ValseHeroRibbon.introPlayed
    @State private var hoverChanged = Date.distantPast
    @State private var film = FilmPhase()
    @MainActor static var introPlayed = false

    static let introDuration = 2.0
    static let idleSpeed = 7.0, hoverSpeed = 34.0   // film, pt / s

    var body: some View {
        if let t = clock.t {
            // review clock: intro from t = 0, hover from VALSE_DEBUG_HOVER_AT
            let hv = max(0, t - clock.hoverAt)
            let extra = hover ? max(0, hv - 0.25) * (Self.hoverSpeed - Self.idleSpeed) : 0
            ribbon(trim: ValseMotion.easeInOut(t / Self.introDuration), phase: CGFloat(t * Self.idleSpeed + extra))
        } else if !ValseMotion.live(reduceMotion) {
            ribbon(trim: 1, phase: 0)
        } else {
            // Idle film paused while the window is inactive (no work in the background), but never the intro: it used to
            // freeze half drawn (or not drawn at all after an inactive launch) until the window was activated.
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activeState == .inactive && introDone)) { tl in
                let now = tl.date
                let trim = introStart.map { ValseMotion.easeInOut(now.timeIntervalSince($0) / Self.introDuration) } ?? 1
                let since = now.timeIntervalSince(hoverChanged)
                let ramp = hover ? ValseMotion.easeInOut(since / 0.5) : 1 - ValseMotion.easeInOut(since / 0.7)
                ribbon(trim: trim, phase: film.advance(to: now, speed: Self.idleSpeed + (Self.hoverSpeed - Self.idleSpeed) * ramp))
            }
            .onValueChange(of: hover) { _, _ in hoverChanged = Date() }
            .onAppear { Self.introPlayed = true }
            .task {
                guard let s = introStart, !introDone else { return }
                try? await Task.sleep(for: .seconds(max(0, Self.introDuration - Date().timeIntervalSince(s)) + 0.1))
                introDone = true
            }
        }
    }

    private func ribbon(trim: Double, phase: CGFloat) -> some View {
        ValseRibbon(width: 38, baseline: 46, entry: 520, turnRadius: 78, background: background,
                    loop: .init(fromTrailing: 196, height: 96, pitch: 13), trim: trim, phase: phase)
    }
}

/// Integrates the film position across speed changes (no jump when the hover speed ramps).
@MainActor final class FilmPhase {
    private var last: Date?
    private var value: CGFloat = 0
    func advance(to now: Date, speed: Double) -> CGFloat {
        if let l = last { value += CGFloat(min(0.1, max(0, now.timeIntervalSince(l))) * speed) }
        last = now
        return value
    }
}

/// "Projects" caption + search, sort, grid/list toggle (36×28 buttons, `#29292D`).
struct ProjectsHeader: View {
    @Perception.Bindable var app: AppModel
    let count: Int
    @FocusState private var searchFocused: Bool

    var title: String {
        switch app.scope {
        case .all: return tr("home.projects")
        case .recents: return tr("home.nav.recents")
        case .trash: return tr("home.nav.trash")
        case .folder(let id): return app.folders.first { $0.id == id }?.name ?? tr("home.projects")
        }
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                Text(verbatim: title).font(Theme.Valse.Fonts.pageTitle).foregroundStyle(Theme.Valse.text)
                if app.hasScanned {
                    Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Valse.mustard)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Theme.Valse.mustard.opacity(0.16), in: Capsule())
                }
                if app.scope == .trash {
                    Text(loc: "home.trash.hint", ProjectLibrary.trashRetentionDays).font(Theme.Valse.Fonts.caption).foregroundStyle(Theme.Valse.text3)
                }
                Spacer()
                if app.scope == .trash, count > 0 {
                    Button(tr("home.trash.empty")) { app.emptyTrash() }.buttonStyle(ValseSecondaryButtonStyle(compact: true)).testID("home.trash.empty")
                }
                if app.isSearching {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.Valse.text3)
                        TextField(tr("home.search.placeholder"), text: $app.search)
                            .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused).testID("home.search.field")
                            .onExitCommand { app.search = ""; app.isSearching = false }
                        Button { app.search = ""; app.isSearching = false } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.Valse.text3).testID("home.search.clear")
                    }
                    .padding(.horizontal, 8).frame(width: 220, height: 28)
                    .background(Theme.Valse.control, in: RoundedRectangle(cornerRadius: ValseShape.control))
                    .overlay(RoundedRectangle(cornerRadius: ValseShape.control).stroke(Theme.Valse.teal.opacity(searchFocused ? 0.9 : 0), lineWidth: 1.5))
                    .onAppear { searchFocused = true }
                } else {
                    HeaderButton(symbol: "magnifyingglass", help: tr("home.search")) { app.isSearching = true }.testID("home.search")
                        .keyboardShortcut("f", modifiers: .command)
                }
                Menu {
                    ForEach(LibrarySort.allCases.filter { $0 != .opened || app.scope == .recents }, id: \.self) { s in
                        WithPerceptionTracking {
                            Button { app.setSort(s) } label: {
                                if app.sort == s { Label(tr(s.nameKey), systemImage: app.ascending ? "chevron.up" : "chevron.down") } else { Text(verbatim: tr(s.nameKey)) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                        Text(verbatim: tr(app.sort.nameKey)).font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Valse.text)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.Valse.control, in: RoundedRectangle(cornerRadius: ValseShape.control))
                .help(tr("home.sort"))
                .testID("home.sort")
                // Segmented: a raised pill (shape cue) slides with a spring to the active mode; its glyph turns mint.
                HStack(spacing: 0) {
                    HeaderButton(symbol: "square.grid.2x2", help: tr("home.view.grid"), active: app.viewMode == .grid, segment: true) { app.setViewMode(.grid) }.testID("home.view.grid")
                    HeaderButton(symbol: "list.bullet", help: tr("home.view.list"), active: app.viewMode == .list, segment: true) { app.setViewMode(.list) }.testID("home.view.list")
                }
                .background(alignment: .leading) {
                    ValseTween(on: app.viewMode == .list, response: 0.36, damping: 0.62) { p in
                        RoundedRectangle(cornerRadius: 6).fill(Theme.Valse.controlHover).frame(width: 32, height: 24).offset(x: 32 * p)
                    }
                }
                .padding(2)
                .background(Theme.Valse.control, in: RoundedRectangle(cornerRadius: ValseShape.control))
            }
        }
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    var active = false
    var segment = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.Valse.mint : (hover ? Theme.Valse.text : Theme.Valse.text2))
                    .frame(width: segment ? 32 : 36, height: segment ? 24 : 28)
                    .background(segment ? .clear : (hover ? Theme.Valse.controlHover : Theme.Valse.control),
                                in: RoundedRectangle(cornerRadius: segment ? 6 : ValseShape.control))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .valseHover($hover)
            .help(help)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }
}

struct EmptyProjects: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            let searching = app.isSearching && !app.search.isEmpty
            Group {
                if app.scope == .all && !searching {
                    // First-run empty library (the hero above is the main way in): the mark, one line, import.
                    VStack(spacing: 12) {
                        ValseSwayingMark().frame(width: 120, height: 120)
                        Text(loc: "home.playful.empty.title").font(Theme.Valse.Fonts.pageTitle).foregroundStyle(Theme.Valse.text)
                        Text(verbatim: tr("home.playful.empty.body")).font(Theme.Valse.Fonts.body).foregroundStyle(Theme.Valse.text2)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            Button(tr("home.newProject")) { app.newProject() }.buttonStyle(ValsePrimaryButtonStyle()).testID("home.empty.new")
                            Button(tr("home.importProject")) { app.importProjectPanel() }.buttonStyle(ValseSecondaryButtonStyle())
                        }
                        .padding(.top, 6)
                    }
                    .padding(.vertical, 28).padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
                    .background {
                        // a quiet ribbon runs along the bottom of the empty floor
                        ZStack {
                            RoundedRectangle(cornerRadius: ValseShape.hero).fill(Theme.Valse.surface.opacity(0.6))
                            ValseRibbon(width: 22, baseline: 24, entry: 240, turnRadius: 44, background: Theme.Valse.canvas)
                                .opacity(0.6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: ValseShape.hero))
                    }
                    .padding(.top, 8)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: app.scope == .trash ? "trash" : (searching ? "magnifyingglass" : "film"))
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Theme.Valse.text3)
                        Text(verbatim: message).font(Theme.Valse.Fonts.body).foregroundStyle(Theme.Valse.text2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .testID("home.empty")
        }
    }
    var message: String {
        if app.isSearching && !app.search.isEmpty { return tr("home.empty.search", app.search) }
        switch app.scope {
        case .trash: return tr("home.empty.trash")
        case .folder: return tr("home.empty.folder")
        case .recents: return tr("home.empty.recents")
        case .all: return tr("home.empty")
        }
    }
}

/// Bottom bar when several projects are selected (round 5): a dark, precise front panel, not a sticker. Raised
/// surface, 1 pt hairline, a hard 3 pt ink shadow; the only colour is the count, a small mint counter on its teal
/// block (the selection sticker in miniature). Actions are flat keys in groups split by hairlines: file actions,
/// then the destructive one (orange glyph, orange block, orange when pressed), then close. Every key lifts off its
/// block on hover, is pushed in and lights mint (orange for Delete) while pressed, and springs back (`ValseLift`).
struct SelectionBar: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            let r: CGFloat = 12
            HStack(spacing: 0) {
                SelectionCount(n: app.selectedIDs.count).padding(.leading, 6).padding(.trailing, 14)
                ValseBarDivider()
                HStack(spacing: 2) {
                    if app.scope == .trash {
                        Button { app.restore(app.selectedEntries) } label: { ValseBarLabel(symbol: "arrow.uturn.backward", title: tr("home.restore")) }
                            .buttonStyle(ValseBarButtonStyle(debugID: "bar.restore")).testID("home.selection.restore")
                    } else {
                        MoveToFolderButton(app: app)
                        Button { app.duplicate(app.selectedEntries) } label: { ValseBarLabel(symbol: "plus.square.on.square", title: tr("home.duplicate")) }
                            .buttonStyle(ValseBarButtonStyle(debugID: "bar.duplicate")).testID("home.selection.duplicate")
                    }
                }
                .padding(.horizontal, 6)
                ValseBarDivider()
                Group {
                    if app.scope == .trash {
                        Button { app.deletePermanently(app.selectedEntries) } label: { ValseBarLabel(symbol: "trash", title: tr("home.deleteForever"), destructive: true) }
                            .buttonStyle(ValseBarButtonStyle(destructive: true, debugID: "bar.delete")).testID("home.selection.deleteForever")
                    } else {
                        Button { app.trash(app.selectedEntries) } label: { ValseBarLabel(symbol: "trash", title: tr("home.delete"), destructive: true) }
                            .buttonStyle(ValseBarButtonStyle(destructive: true, debugID: "bar.delete")).testID("home.selection.delete")
                    }
                }
                .padding(.horizontal, 6)
                ValseBarDivider()
                Button { app.selectedIDs = [] } label: { ValseBarLabel(symbol: "xmark", title: nil) }
                    .buttonStyle(ValseBarButtonStyle(debugID: "bar.close"))
                    .help(tr("common.cancel"))
                    .accessibilityLabel(Text(loc: "common.cancel"))
                    .testID("home.selection.close")
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 6).frame(height: 44)
            .background(Theme.Valse.raised, in: RoundedRectangle(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(Theme.Valse.cream.opacity(0.14)))
            .valseHardShadow(Theme.Valse.ink, radius: r, depth: 3)
            .modifier(ValseRiseIn())
            .padding(.bottom, 20)
        }
    }
}

/// "2 selected": the number on a mint counter block (ink, bold, tabular digits) sitting on a solid teal block, the
/// rest of the localized phrase in secondary text. Read as one phrase by VoiceOver.
private struct SelectionCount: View {
    let n: Int
    var body: some View {
        let full = trCount("home.selected", n)
        let digits = "\(n)"
        let rest = full.contains(digits) ? full.replacingOccurrences(of: digits, with: "").trimmingCharacters(in: .whitespaces) : full
        HStack(spacing: 8) {
            if full.contains(digits) {
                Text(verbatim: digits).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Theme.Valse.ink)
                    .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 22)
                    .background(Theme.Valse.mint, in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: -1, y: -1)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Valse.teal).offset(x: 1, y: 1))
            }
            Text(verbatim: rest).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Valse.text2).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: full))
    }
}

struct ValseBarDivider: View {
    var body: some View { Rectangle().fill(Theme.Valse.controlHover).frame(width: 1, height: 20) }
}

/// A selection bar key's content: glyph + label (or glyph only). Colours follow the key's state (`valsePressed`,
/// `isEnabled`): pressed keys light up, so their content turns ink.
struct ValseBarLabel: View {
    let symbol: String
    let title: String?
    var destructive = false
    var menu = false
    @Environment(\.valsePressed) private var pressed
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let text = !enabled ? Theme.Valse.text3.opacity(0.6) : (pressed ? Theme.Valse.ink : Theme.Valse.text)
        let glyph = !enabled ? text : (pressed ? Theme.Valse.ink : (destructive ? Theme.Valse.orange : Theme.Valse.text2))
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(glyph)
            if let title { Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(text).lineLimit(1).fixedSize() }
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(glyph) }
        }
        .padding(.horizontal, title == nil ? 0 : 10)
        .frame(minWidth: 28, minHeight: 28)
    }
}

/// Flat key of the selection bar (see `SelectionBar`): rest = text on the panel; hover = control fill lifted 1 pt
/// up-left off a solid teal (destructive: orange) block; pressed = pushed down-right onto it and lit mint (orange);
/// disabled = dimmed, no lift. Same springs as every Home lift (`ValseLift`).
struct ValseBarButtonStyle: ButtonStyle {
    var destructive = false
    var debugID = ""
    func makeBody(configuration: Configuration) -> some View {
        ValseBarKey(label: configuration.label, pressed: configuration.isPressed, destructive: destructive, debugID: debugID)
    }
}

private struct ValseBarKey<Label: View>: View {
    let label: Label
    let pressed: Bool
    let destructive: Bool
    let debugID: String
    @State private var hoverState = false
    @Environment(\.isEnabled) private var enabled
    @ObservedObject private var clock = ValseDebugClock.shared

    var body: some View {
        let state = clock.liftState(debugID)
            ?? ValseLift.state(hover: ValseDebugHover.merge(hoverState, debugID), pressed: pressed, enabled: enabled)
        let k = ValseLift.spring(to: state)
        let accent = destructive ? Theme.Valse.orange : Theme.Valse.teal
        let fill: Color = state == .pressed ? (destructive ? Theme.Valse.orange : Theme.Valse.mint)
            : (state == .hover ? Theme.Valse.controlHover : .clear)
        let r: CGFloat = 7
        ValseSpringValue(target: ValseLift.target(state), response: k.response, damping: k.damping,
                         debugEvents: clock.liftEvents(debugID)) { v in
            label
                .environment(\.valsePressed, state == .pressed)
                .background(fill, in: RoundedRectangle(cornerRadius: r))
                .offset(x: ValseLift.offset(v, depth: 1), y: ValseLift.offset(v, depth: 1))
                .background(RoundedRectangle(cornerRadius: r).fill(accent)
                    .offset(x: ValseLift.block(v, depth: 1.5), y: ValseLift.block(v, depth: 1.5))
                    .opacity(ValseLift.showsBlock(v) ? 1 : 0))
        }
        .contentShape(Rectangle())
        .valseHover($hoverState)
    }
}

/// "Move to ⌄" on the selection bar: a bar key that opens a native menu of folders above itself. A SwiftUI `Menu`
/// with the borderless style drew its own label (system colour, ignoring the bar's), so the key draws its label and
/// pops the NSMenu itself (UI tests: `{"click": "id:home.selection.moveTo", "menuItem": "<folder>"}`).
struct MoveToFolderButton: View {
    @Perception.Bindable var app: AppModel
    @State private var anchor = DropdownMenu.Anchor()
    var body: some View {
        WithPerceptionTracking {
            Button { HomeMoveMenu.show(app: app, items: app.selectedEntries, above: anchor.view) } label: {
                ValseBarLabel(symbol: "folder", title: tr("home.moveTo"), menu: true)
            }
            .buttonStyle(ValseBarButtonStyle(debugID: "bar.move"))
            .background(DropdownMenu.AnchorView(anchor: anchor))
            .accessibilityLabel(Text(verbatim: tr("home.moveTo")))
            .testID("home.selection.moveTo")
        }
    }
}

@MainActor
enum HomeMoveMenu {
    static func menu(app: AppModel, items: [LibraryEntry]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(PlayerMenuAction.item(tr("home.folder.none")) { app.move(items, to: nil) })
        if !app.folders.isEmpty { m.addItem(.separator()) }
        for f in app.folders { m.addItem(PlayerMenuAction.item(f.name) { app.move(items, to: f.id) }) }
        m.addItem(.separator())
        m.addItem(PlayerMenuAction.item(tr("home.folder.create") + "…") { app.modal = .newFolder })
        return m
    }

    static func show(app: AppModel, items: [LibraryEntry], above view: NSView?) {
        let m = menu(app: app, items: items)
        if let sink = DropdownMenu.uitestMenuSink { sink(m); return }
        if TestAnchors.isEnabled { return }   // UI tests never run a real (modal) menu tracking loop
        guard let view, view.window != nil else { m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil); return }
        // the bar sits at the bottom of the window: open upwards, the menu's bottom edge 4 pt above the key
        let h = m.size.height
        let y = view.isFlipped ? -4 - h : view.bounds.maxY + 4 + h
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

struct MoveToFolderItems: View {
    @Perception.Bindable var app: AppModel
    let items: [LibraryEntry]
    var body: some View {
        WithPerceptionTracking {
            Button(tr("home.folder.none")) { app.move(items, to: nil) }
            if !app.folders.isEmpty { Divider() }
            ForEach(app.folders) { f in WithPerceptionTracking { Button(f.name) { app.move(items, to: f.id) } } }
            Divider()
            Button(tr("home.folder.create") + "…") { app.modal = .newFolder }
        }
    }
}

/// Card / row context menu (UX.md §2.1 [04]: Rename · Duplicate · Delete, plus Montage's extra entries).
struct ProjectMenuItems: View {
    @Perception.Bindable var app: AppModel
    let entry: LibraryEntry
    var body: some View {
        WithPerceptionTracking {
            let items = app.targets(entry)
            if entry.trashedAt != nil {
                Button(tr("home.restore")) { app.restore(items) }
                Button(tr("home.deleteForever")) { app.deletePermanently(items) }
            } else {
                Button(tr("home.open")) { app.open(entry.url) }
                Button(tr("pm.window.openInNew")) { app.openInNewWindow(entry.url) }.disabled(items.count > 1)   // PM-014
                Button(tr("home.rename")) { app.renamingID = entry.id }.disabled(items.count > 1)
                Button(tr("home.duplicate")) { app.duplicate(items) }
                Menu(tr("home.moveTo")) { MoveToFolderItems(app: app, items: items) }
                Divider()
                Button(tr("menu.packProject") + "…") { app.packPanel(entry) }.disabled(items.count > 1)
                Button(tr("home.showInFinder")) { app.revealInFinder(entry) }
                Button(tr("home.details")) { app.modal = .details(entry) }.disabled(items.count > 1)
                Divider()
                Button(tr("home.delete")) { app.trash(items) }
            }
        }
    }
}

// MARK: - Card (grid)

struct ProjectCard: View {
    @Perception.Bindable var app: AppModel
    let entry: LibraryEntry
    let all: [LibraryEntry]
    @State private var hoverState = false

    var body: some View {
        WithPerceptionTracking {
            let hover = ValseDebugHover.merge(hoverState, all.first?.id == entry.id ? "card0" : "-")
            let selected = app.selectedIDs.contains(entry.id)
            let r = ValseShape.card
            VStack(alignment: .leading, spacing: 5) {
                // Hover: the cover lifts up-left off a solid block (hard offset, zero blur) with a cream hairline.
                // Selected: a 3 pt mint frame around the cover (the cover itself is never tinted) on a solid teal
                // offset block, a check badge, and the name on a mint label block.
                ValseTween(on: hover || selected, response: 0.4, damping: 0.6) { p in
                    let q = min(1, max(0, p))
                    CoverView(entry: entry)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: r))
                        .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(selected ? .clear : Theme.Valse.cream.opacity(0.08 + 0.27 * q)))
                        .overlay(RoundedRectangle(cornerRadius: r + 3).strokeBorder(selected ? Theme.Valse.mint : .clear, lineWidth: 3).padding(-3))
                        .offset(x: -2 * p, y: -2 * p)
                        .modifier(ValseHardShadow(color: selected ? Theme.Valse.teal : Theme.Valse.controlHover, radius: r + (selected ? 3 : 0),
                                                  depth: 2 * max(0, p), inset: selected ? 3 : 0))
                }
                    .overlay(alignment: .bottomTrailing) {
                        if hover || selected {
                            Menu { ProjectMenuItems(app: app, entry: entry) } label: {
                                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Valse.text)
                                    .frame(width: 26, height: 20)
                                    .background(Theme.Valse.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .padding(6)
                            .help(tr("home.more"))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if selected { ValseCheckBadge(size: 22).padding(7) }
                    }
                    .padding(.bottom, 3)
                if app.renamingID == entry.id {
                    InlineRenameField(initial: entry.name) { app.rename(entry, to: $0) } onCancel: { app.renamingID = nil }
                } else {
                    Text(verbatim: entry.name).font(.system(size: 13, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.Valse.ink : Theme.Valse.text).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, selected ? 5 : 0)
                        .background(selected ? Theme.Valse.mint : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, selected ? -5 : 0)   // the label block bleeds left so the text stays aligned
                        .onTapGesture(count: 2) { if entry.trashedAt == nil { app.renamingID = entry.id } }
                }
                Text(verbatim: "\(HomeFormat.bytes(entry.sizeBytes)) · \(HomeFormat.duration(entry.summary.duration))")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.Valse.text3).lineLimit(1)
            }
            .contentShape(Rectangle())
            .valseHover($hoverState)
            .onTapGesture { app.click(entry, in: all) }
            .contextMenu { ProjectMenuItems(app: app, entry: entry) }
            .draggable(entry.id)
            .help(entry.trashedAt == nil ? tr("home.card.help", HomeFormat.date(entry.modifiedAt)) : tr("home.card.trashedHelp"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: entry.name))
        }
    }
}

struct InlineRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 4).frame(height: 20)
                .background(Theme.Valse.control, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.Valse.teal))
                .focused($focused)
                .onSubmit { onCommit(text) }
                .onExitCommand(perform: onCancel)
                .testID("home.rename.field")
                .onAppear { text = initial; focused = true }
                .onValueChange(of: focused) { _, f in if !f { onCommit(text) } }
        }
    }
}

/// Async cover thumbnail (`cover.jpg`), cached; placeholder = dark tile with a film glyph.
struct CoverView: View {
    let entry: LibraryEntry
    @State private var image: NSImage?
    var body: some View {
        WithPerceptionTracking {
            // The fill rectangle sizes the view; the cover is an overlay so its aspect-fill never grows the card.
            Rectangle().fill(Theme.Valse.surface)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: entry.summary.clipCount == 0 ? "plus.rectangle.on.rectangle" : "film")
                            .font(.system(size: 20, weight: .light)).foregroundStyle(Theme.Valse.text3.opacity(0.7))
                    }
                }
                .clipped()
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: tr("ax.cover", entry.name)))   // SE-017
                .accessibilityAddTraits(.isImage)
            .task(id: "\(entry.id)|\(entry.modifiedAt.timeIntervalSince1970)") { image = await CoverCache.shared.image(for: entry) }
        }
    }
}

@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 400 }

    func image(for e: LibraryEntry) async -> NSImage? {
        guard let url = e.coverURL else { return nil }
        let key = "\(url.path)|\(e.modifiedAt.timeIntervalSince1970)" as NSString
        if let i = cache.object(forKey: key) { return i }
        // boxed: NSImage is only Sendable from macOS 14
        let img = await Task.detached(priority: .utility) { () -> UncheckedSendableBox<NSImage>? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
            else { return nil }
            return UncheckedSendableBox(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }.value?.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

// MARK: - List

struct ProjectListHeader: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                col(tr("home.col.name"), .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 72)
                col(tr("home.col.modified"), .modified).frame(width: 160, alignment: .leading)
                col(tr("home.col.duration"), .duration).frame(width: 90, alignment: .leading)
                col(tr("home.col.size"), .size).frame(width: 90, alignment: .leading)
                Text(loc: "home.col.format").frame(width: 140, alignment: .leading)
            }
            .font(Theme.Valse.Fonts.overline).foregroundStyle(Theme.Valse.text3).textCase(.uppercase)
            .padding(.horizontal, 10).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.Valse.stroke).frame(height: 1) }
        }
    }
    func col(_ t: String, _ s: LibrarySort) -> some View {
        Button { app.setSort(s) } label: {
            HStack(spacing: 3) {
                Text(verbatim: t)
                if app.sort == s { Image(systemName: app.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
        }
        .buttonStyle(.plain)
        .testID("home.col.\(s.rawValue)")
    }
}

struct ProjectRow: View {
    @Perception.Bindable var app: AppModel
    let entry: LibraryEntry
    let all: [LibraryEntry]
    @State private var hover = false
    var body: some View {
        WithPerceptionTracking {
            let selected = app.selectedIDs.contains(entry.id)
            let r = ValseShape.control
            HStack(spacing: 0) {
                CoverView(entry: entry).frame(width: 54, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Valse.stroke))
                    .overlay(alignment: .topLeading) {
                        if selected { ValseCheckBadge(size: 15).offset(x: -5, y: -5) }
                    }
                    .padding(.trailing, 16)
                Group {
                    if app.renamingID == entry.id {
                        InlineRenameField(initial: entry.name) { app.rename(entry, to: $0) } onCancel: { app.renamingID = nil }
                    } else {
                        Text(verbatim: entry.name).font(.system(size: 13, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? Theme.Valse.ink : Theme.Valse.text).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: HomeFormat.date(entry.modifiedAt)).frame(width: 160, alignment: .leading)
                Text(verbatim: HomeFormat.duration(entry.summary.duration)).monospacedDigit().frame(width: 90, alignment: .leading)
                Text(verbatim: HomeFormat.bytes(entry.sizeBytes)).frame(width: 90, alignment: .leading)
                Text(verbatim: HomeFormat.format(entry.summary)).lineLimit(1).frame(width: 140, alignment: .leading)
            }
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.Valse.ink.opacity(0.82) : Theme.Valse.text2)   // ≥ 7:1 on mint
            .padding(.leading, 12).padding(.trailing, 10).frame(height: 46)
            .background(!selected && ValseDebugHover.merge(hover, "row0") ? Theme.Valse.surface : .clear, in: RoundedRectangle(cornerRadius: r))
            // Selected = the flat mint sticker on a solid teal offset block + check badge on the thumbnail + bold ink name.
            .valseSticker(selected, radius: r)
            .contentShape(Rectangle())
            .valseHover($hover)
            .onTapGesture { app.click(entry, in: all) }
            .contextMenu { ProjectMenuItems(app: app, entry: entry) }
            .draggable(entry.id)
        }
    }
}

enum HomeFormat {
    /// File sizes in the app language (en "1.2 MB", fr "1,2 Mo"; decimal units like Finder).
    @MainActor static func bytes(_ n: Int64) -> String {
        let fr = L10n.shared.language.hasPrefix("fr")
        let units = fr ? ["octets", "Ko", "Mo", "Go", "To"] : ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(max(0, n)), i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) \(fr && n <= 1 ? "octet" : (!fr && n == 1 ? "byte" : units[0]))" }
        let f = NumberFormatter()
        f.locale = L10n.shared.locale
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = v < 10 ? 1 : 0
        return "\(f.string(from: NSNumber(value: v)) ?? "\(v)") \(units[i])"
    }
    /// CapCut card duration "00:00" (mm:ss, h:mm:ss beyond an hour).
    static func duration(_ t: Time) -> String {
        let s = Int(t.seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
    static func format(_ s: ProjectSummary) -> String {
        "\(Int(s.canvasSize.width))×\(Int(s.canvasSize.height)) · \(fps(s.frameRate))"
    }
    static func fps(_ r: FrameRate) -> String {
        r.denominator == 1 ? "\(r.numerator) fps" : String(format: "%.2f fps", r.fps)
    }
}

/// Templates entry point (content arrives with the templates workstream).
struct TemplatesPlaceholder: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.play").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.Valse.teal)
                Text(loc: "home.templates.title").font(Theme.Valse.Fonts.pageTitle).foregroundStyle(Theme.Valse.text)
                Text(loc: "home.templates.soon").font(Theme.Valse.Fonts.body).foregroundStyle(Theme.Valse.text2)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button(tr("home.newProject")) { app.newProject() }.buttonStyle(ValsePrimaryButtonStyle()).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Valse.canvas)
        }
    }
}

