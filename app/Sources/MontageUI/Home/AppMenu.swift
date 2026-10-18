import AppKit
import MontageCore
import MontageEngine

/// The menu bar (UX.md §8.1): CapCut's commands in a conventional, richer Mac layout (Montage · File · Edit · Clip ·
/// Timeline · Marker · View · Window · Help). Titles are localized; key equivalents come from the user keymap
/// (`Keymap.binding(for:)`), so a rebind in the shortcut editor shows (and works) here immediately.
///
/// Key handling: `ShortcutRegistry` (app key monitor) runs first for editor shortcuts. Menus only match ⌘/⌃ combos
/// (`menuHasKeyEquivalent`): single-key bindings (B, M, Space…) are displayed but never stolen from text fields.
@MainActor
public final class AppMenuBuilder: NSObject, NSMenuDelegate {
    unowned let app: AppModel
    var store: EditorStore { app.store }
    /// Hooks the app delegate provides (panels it owns).
    public var importMedia: () -> Void = {}

    private var bindings: [ObjectIdentifier: KeyBinding] = [:]

    public init(app: AppModel) { self.app = app }

    var inEditor: Bool { app.screen == .editor && app.modal == nil }

    // MARK: Items

    private func item(_ titleKey: String, id: String? = nil, enabled: @escaping @MainActor () -> Bool = { true },
                      checked: (@MainActor () -> Bool)? = nil, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuTarget(action: action, enabled: enabled, checked: checked)
        let i = NSMenuItem(title: tr(titleKey), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        i.target = target
        i.representedObject = target
        if let id, let b = Keymap.shared.binding(for: id) {
            i.keyEquivalent = b.menuKeyEquivalent
            i.keyEquivalentModifierMask = b.modifierFlags
            bindings[ObjectIdentifier(i)] = b
        }
        return i
    }

    /// A `ShortcutRegistry` command (same action, title and binding as the key monitor).
    private func reg(_ id: String, _ titleKey: String? = nil, checked: (@MainActor () -> Bool)? = nil) -> NSMenuItem {
        let s = ShortcutRegistry.all.first { $0.id == id }
        return item(titleKey ?? s?.titleKey ?? id, id: id, enabled: { [unowned self] in self.inEditor }, checked: checked) { [unowned self] in
            guard let s = ShortcutRegistry.all.first(where: { $0.id == id }) else { return }
            s.action(self.store)
        }
    }

    /// An editor command that isn't in the registry (rebindable through `Keymap.menuCommands`).
    private func ed(_ id: String, _ action: @escaping @MainActor (EditorStore) -> Void) -> NSMenuItem {
        item(id, id: id, enabled: { [unowned self] in self.inEditor }) { [unowned self] in action(self.store) }
    }

    /// Text-aware edit command: the focused text field gets the standard selector, else the editor command runs.
    /// `multilineOnly` (undo/redo): single-line fields (inspector numbers, names) commit on Return, so ⌘Z there undoes
    /// the edit in the project, like CapCut; only multi-line text editors keep their own typing undo.
    private func textAware(_ id: String, _ selector: Selector, regID: String?, multilineOnly: Bool = false,
                           home: (@MainActor (AppModel) -> Void)? = nil,
                           _ fallback: @escaping @MainActor (EditorStore) -> Void) -> NSMenuItem {
        item(id, id: regID ?? id) { [unowned self] in
            if let r = NSApp.keyWindow?.firstResponder as? NSText, !(multilineOnly && (r as? NSTextView)?.isFieldEditor == true),
               NSApp.sendAction(selector, to: nil, from: nil) { return }
            if self.inEditor { fallback(self.store) } else if self.onHome, let home { home(self.app) }
        }
    }

    var onHome: Bool { app.screen == .home && app.modal == nil }

    /// A registry command that acts on the selected projects when Home is showing (Edit ▸ Duplicate / Delete).
    private func homeAware(_ id: String, _ titleKey: String? = nil, home: @escaping @MainActor (AppModel) -> Void) -> NSMenuItem {
        let s = ShortcutRegistry.all.first { $0.id == id }
        return item(titleKey ?? s?.titleKey ?? id, id: id, enabled: { [unowned self] in
            self.inEditor || (self.onHome && !self.app.selectedIDs.isEmpty)
        }) { [unowned self] in
            if self.onHome { home(self.app); return }
            ShortcutRegistry.all.first { $0.id == id }?.action(self.store)
        }
    }

    private func menu(_ titleKey: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem()
        let m = NSMenu(title: tr(titleKey))
        m.delegate = self
        items.forEach(m.addItem)
        item.submenu = m
        item.title = tr(titleKey)
        return item
    }

    private func sub(_ titleKey: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: tr(titleKey), action: nil, keyEquivalent: "")
        let m = NSMenu(title: tr(titleKey))
        m.delegate = self
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    // MARK: Build

    public func build() -> NSMenu {
        bindings = [:]
        let main = NSMenu()
        let home: @MainActor () -> Bool = { [unowned self] in self.app.screen == .editor }
        main.addItem(menu("menu.app", [
            item("menu.about") { [unowned self] in self.app.modal = .settings(.about) },
            .separator(),
            item("menu.settings", id: "menu.settings") { [unowned self] in self.app.modal = .settings(.general) },
            .separator(),
            item("menu.home", id: "menu.home", enabled: home) { [unowned self] in self.app.backToHome() },
            .separator(),
            item("menu.hide", id: "menu.hide") { NSApp.hide(nil) },
            item("menu.quit", id: "menu.quit") { NSApp.terminate(nil) },
        ]))
        let recents = ProjectLibrary.shared.recentURLs().map { u in
            let i = NSMenuItem(title: ProjectPackage.summary(of: u)?.name ?? u.deletingPathExtension().lastPathComponent,
                               action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            let t = MenuTarget(action: { [unowned self] in self.app.open(u) }, enabled: { true }, checked: nil)
            i.target = t; i.representedObject = t; i.toolTip = u.path
            return i
        }
        main.addItem(menu("menu.file", [
            item("menu.new", id: "menu.new") { [unowned self] in
                if self.app.screen == .editor { Task { await self.store.closeProject(); self.app.newProject() } } else { self.app.newProject() }
            },
            item("menu.open", id: "menu.open") { [unowned self] in self.app.openPanel() },
            sub("menu.openRecent", recents.isEmpty ? [item("menu.openRecent.none", enabled: { false }) {}] : recents),
            .separator(),
            item("menu.import", id: "menu.import", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.importMedia() },
            item("menu.importProject", id: "menu.importProject") { [unowned self] in self.app.importProjectPanel() },
            .separator(),
            item("menu.save", id: "menu.save", enabled: { [unowned self] in self.inEditor }) { [unowned self] in
                self.store.save(); self.store.showToast(tr("toast.saved"))
            },
            item("menu.packProject", id: "menu.packProject", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.app.packPanel() },
            item("menu.versions", id: "menu.versions", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.app.modal = .versions },
            item("menu.relink", id: "menu.relink", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.app.modal = .relink },
            item("menu.projectSettings", id: "menu.projectSettings", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.app.modal = .projectSettings },
            .separator(),
            item("menu.export", id: "menu.export", enabled: { [unowned self] in self.inEditor && self.store.project.duration > .zero }) { [unowned self] in
                self.store.openExport()
            },
            ed("export.menu.selected") { $0.exportSelectedClips() },
            ed("export.menu.range") { $0.exportInOutRange() },
            ed("menu.exportFrame") { $0.exportStillFrame() },
            sub("export.menu.timeline", TimelineInterchange.Format.allCases.map { f in
                item("export.timeline.\(f.rawValue)", enabled: { [unowned self] in self.inEditor }) { [unowned self] in self.store.exportTimeline(f) }
            }),
        ]))
        main.addItem(menu("menu.edit", [
            textAware("menu.undo", Selector(("undo:")), regID: nil, multilineOnly: true) { $0.undo() },
            textAware("menu.redo", Selector(("redo:")), regID: nil, multilineOnly: true) { $0.redo() },
            .separator(),
            textAware("menu.cut", #selector(NSText.cut(_:)), regID: "cut") { $0.cutSelection() },
            textAware("menu.copy", #selector(NSText.copy(_:)), regID: "copy") { $0.copySelection() },
            textAware("menu.paste", #selector(NSText.paste(_:)), regID: "paste") { $0.paste() },
            homeAware("duplicate") { $0.duplicate($0.selectedEntries) },
            homeAware("delete", "menu.delete") { $0.trashOrDeleteSelection() },
            item("home.rename", enabled: { [unowned self] in self.onHome && self.app.selectedIDs.count == 1 }) { [unowned self] in
                self.app.renamingID = self.app.selectedIDs.first
            },
            textAware("shortcut.selectAll", #selector(NSText.selectAll(_:)), regID: "selectAll",
                      home: { $0.selectedIDs = Set($0.visibleEntries.map(\.id)) }) { $0.selectAll() },
            reg("deselect"),
            .separator(),
            reg("copyAttributes"),
            reg("pasteAttributes"),
            .separator(),
            reg("split", "menu.split"),
            reg("splitAll"),
            reg("deleteLeft"),
            reg("deleteRight"),
        ]))
        main.addItem(menu("menu.clip", [
            ed("menu.freeze") { $0.freezeFrame() },
            ed("menu.reverse") { $0.reverseSelection() },
            ed("menu.mirror") { $0.mirrorSelection() },
            ed("menu.rotate") { $0.rotateSelection() },
            .separator(),
            reg("speedPanel"),
            reg("toggleClip"),
            reg("extractAudio"),
            .separator(),
            reg("group"),
            reg("ungroup"),
        ]))
        main.addItem(menu("menu.timeline", [
            reg("selectMode", checked: { [unowned self] in self.store.timelineUI.tool == .select }),
            reg("splitMode", checked: { [unowned self] in self.store.timelineUI.tool == .split }),
            .separator(),
            reg("magnet", checked: { [unowned self] in self.store.project.timeline.mainTrackMagnet }),
            reg("snapping", checked: { [unowned self] in self.store.project.timeline.snapping }),
            reg("linkage", checked: { [unowned self] in self.store.project.timeline.linkage }),
            reg("previewAxis", checked: { [unowned self] in self.store.timelineUI.previewAxis }),
            .separator(),
            reg("zoomIn", "menu.zoomIn"),
            reg("zoomOut", "menu.zoomOut"),
            reg("zoomFit"),
            .separator(),
            reg("selectLeft"),
            reg("selectRight"),
            reg("selectByClip"),
            reg("inPoint"),
            reg("outPoint"),
            .separator(),
            reg("home"),
            reg("end"),
            reg("prevCut"),
            reg("nextCut"),
            .separator(),
            ed("menu.renderPreview") { $0.renderPreview(range: nil) },
            .separator(),
            ed("timelines.new") { $0.newTimeline() },
            item("timelines.newWithSelection", enabled: { [unowned self] in self.inEditor && !self.store.selection.isEmpty }) { [unowned self] in
                self.store.newTimeline(withSelection: true)
            },
            item("timelines.next", enabled: { [unowned self] in self.inEditor && self.store.timelineSlots.count > 1 }) { [unowned self] in self.store.cycleTimeline(1) },
            item("timelines.previous", enabled: { [unowned self] in self.inEditor && self.store.timelineSlots.count > 1 }) { [unowned self] in self.store.cycleTimeline(-1) },
        ]))
        main.addItem(menu("menu.marker", [
            reg("marker"),
            reg("markerColor"),
            reg("nextMarker"),
            reg("prevMarker"),
        ]))
        main.addItem(menu("menu.view", [
            reg("playPause"),
            reg("shuttleBack"),
            reg("shuttleStop"),
            reg("shuttleForward"),
            reg("prevFrame"),
            reg("nextFrame"),
            .separator(),
            reg("playerZoomIn"),
            reg("playerZoomOut"),
            reg("playerZoomFit"),
            reg("rulers", checked: { [unowned self] in self.store.playerUI.showRulers }),
            reg("guides", checked: { [unowned self] in self.store.playerUI.showGuides }),
            item("player.loop", enabled: { [unowned self] in self.inEditor }, checked: { [unowned self] in self.store.playerUI.loopEnabled }) { [unowned self] in
                self.store.toggleLoop()
            },
            reg("playerFullscreen"),
            .separator(),
            item("menu.language.system", checked: { L10n.shared.languagePreference == "system" }) { L10n.shared.setLanguagePreference("system") },
            item("menu.language.en", checked: { L10n.shared.languagePreference == "en" }) { L10n.shared.setLanguagePreference("en") },
            item("menu.language.fr", checked: { L10n.shared.languagePreference == "fr" }) { L10n.shared.setLanguagePreference("fr") },
        ]))
        main.addItem(menu("menu.window", [
            item("menu.minimize", id: "menu.minimize") { NSApp.keyWindow?.miniaturize(nil) },
            item("menu.fullscreen", id: "menu.fullscreen") { NSApp.keyWindow?.toggleFullScreen(nil) },
        ]))
        main.addItem(menu("menu.help", [
            item("menu.shortcuts", id: "menu.shortcuts") { [unowned self] in self.app.modal = .shortcuts },
            item("menu.licenses") { [unowned self] in self.app.modal = .settings(.about) },
        ]))
        return main
    }

    // MARK: NSMenuDelegate

    /// Only ⌘/⌃ combos are matched by the menu bar (bare keys stay with the key monitor and text fields).
    public func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                     action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(KeyBinding.relevantModifiers)
        guard mods.contains(.command) || mods.contains(.control), !Keymap.isRecording, let b = KeyBinding(event: event) else { return false }
        for i in menu.items {
            guard bindings[ObjectIdentifier(i)] == b, let t = i.target as? MenuTarget, t.enabled() else { continue }
            target.pointee = t
            action.pointee = i.action
            return true
        }
        return false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        for i in menu.items {
            if let t = i.target as? MenuTarget, let c = t.checked { i.state = c() ? .on : .off }
        }
    }
}

/// Closure target with validation (enabled / checked).
@MainActor
final class MenuTarget: NSObject, NSMenuItemValidation {
    let action: @MainActor () -> Void
    let enabled: @MainActor () -> Bool
    let checked: (@MainActor () -> Bool)?
    init(action: @escaping @MainActor () -> Void, enabled: @escaping @MainActor () -> Bool, checked: (@MainActor () -> Bool)?) {
        self.action = action; self.enabled = enabled; self.checked = checked
    }
    @objc func fire(_ sender: Any?) { action() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let checked { item.state = checked() ? .on : .off }
        return enabled()
    }
}
