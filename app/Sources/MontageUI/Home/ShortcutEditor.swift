import SwiftUI
import AppKit
import MontageCore

/// Shortcut window (UX.md §8.2, [50]–[52]): Help ▸ Keyboard shortcuts / ⌨ in the title bar, and Settings ▸ Shortcuts.
/// Categories Timeline · Player · Basic · Other, layout preset (CapCut / Final Cut Pro / Premiere Pro), click a binding to
/// record a new one, conflicts ask "… already belongs to …. Override it?", Reset to defaults, Save / Cancel.
struct ShortcutEditorView: View {
    @Bindable var app: AppModel
    @State private var keymap = Keymap(url: nil)
    @State private var confirmClose = false

    var dirty: Bool { keymap.preset != Keymap.shared.preset || keymap.overrides != Keymap.shared.overrides }

    var body: some View {
        DialogCard(title: tr("keymap.title"), width: 760, onClose: close) {
            VStack(spacing: 14) {
                ShortcutList(keymap: keymap, compact: false)
                    .frame(height: 520)
                ShortcutFooterControls(keymap: keymap)
                DialogFooter(okEnabled: dirty, onCancel: close, onOK: save)
            }
            .padding(16)
        }
        .testID("shortcuts")
        .onAppear { keymap = Keymap.shared.copy() }
        .alert(tr("keymap.unsaved.title"), isPresented: $confirmClose) {
            Button(tr("common.close"), role: .destructive) { app.modal = nil }
            Button(tr("common.save")) { save() }
        } message: { Text(loc: "keymap.unsaved.message") }
    }

    func close() { if dirty { confirmClose = true } else { app.modal = nil } }
    func save() { Keymap.shared.adopt(keymap); app.modal = nil; app.store.showToast(tr("settings.saved")) }
}

/// Preset picker + Reset to defaults.
struct ShortcutFooterControls: View {
    @Bindable var keymap: Keymap
    var body: some View {
        HStack(spacing: 10) {
            Text(loc: "keymap.preset").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 2) {
                ForEach(KeymapPreset.allCases, id: \.self) { p in
                    Button { keymap.selectPreset(p) } label: {
                        Text(verbatim: tr(p.nameKey)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(keymap.preset == p ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(keymap.preset == p ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .testID("keymap.preset.\(p.rawValue)")
                }
            }
            .padding(2).background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            if keymap.isModified { Text(loc: "keymap.customized").font(Theme.Fonts.hint).foregroundStyle(Theme.accent) }
            Spacer()
            Button(tr("keymap.reset")) { keymap.selectPreset(.capcut) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(keymap.preset == .capcut && !keymap.isModified)
                .testID("keymap.reset")
        }
    }
}

/// The two-column category list with recording.
struct ShortcutList: View {
    @Bindable var keymap: Keymap
    let compact: Bool
    @State private var category: ShortcutCategory = .timeline
    @State private var recording: String?
    @State private var search = ""
    @State private var pending: (id: String, binding: KeyBinding, conflicts: [KeymapEntry])?
    @State private var monitor: Any?

    var rows: [KeymapEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? keymap.entries(in: category) : keymap.entries
        return base.filter { q.isEmpty || tr($0.titleKey).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || (keymap.binding(for: $0.id)?.display.localizedCaseInsensitiveContains(q) ?? false) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(ShortcutCategory.allCases, id: \.self) { c in
                        Button { category = c; search = "" } label: {
                            Text(verbatim: tr(c.nameKey)).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(category == c && search.isEmpty ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(category == c && search.isEmpty ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .testID("keymap.category.\(c.rawValue)")
                    }
                }
                .padding(2).background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField(tr("keymap.search"), text: $search).textFieldStyle(.plain).font(.system(size: 12))
                        .testID("keymap.search")
                }
                .padding(.horizontal, 8).frame(width: 200, height: 30)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            ScrollView {
                let list = rows
                let half = (list.count + 1) / 2
                HStack(alignment: .top, spacing: 24) {
                    column(Array(list.prefix(half)))
                    column(Array(list.dropFirst(half)))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if list.isEmpty {
                    Text(loc: "keymap.noResults").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(30)
                }
                Color.clear.frame(height: 0).lockHorizontalScroll()   // U1-2: vertical only
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.inset.opacity(compact ? 0 : 0.6), in: RoundedRectangle(cornerRadius: 8))
            if let p = pending {
                // inline conflict prompt ("⌘B shortcut already belongs to Split. Override it?")
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color(hex: 0xE8B33A))
                    Text(loc: "keymap.conflict.message", p.binding.display, p.conflicts.map { tr($0.titleKey) }.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(tr("common.cancel")) { pending = nil }.buttonStyle(SecondaryButtonStyle()).testID("keymap.conflict.cancel")
                    Button(tr("keymap.conflict.override")) {
                        keymap.assign(p.binding, to: p.id)
                        pending = nil
                    }
                    .buttonStyle(AccentButtonStyle()).testID("keymap.conflict.override")
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Color(hex: 0xE8B33A).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xE8B33A).opacity(0.4)))
                .testID("keymap.conflict")
            } else {
                Text(loc: recording == nil ? "keymap.hint" : "keymap.recordingHint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    func column(_ items: [KeymapEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { e in row(e) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    func row(_ e: KeymapEntry) -> some View {
        let b = keymap.binding(for: e.id)
        let changed = b != keymap.presetBinding(e.id)
        return HStack(spacing: 6) {
            Text(verbatim: tr(e.titleKey)).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if changed { Circle().fill(Theme.accent).frame(width: 5, height: 5).help(tr("keymap.changed")) }
            Spacer(minLength: 6)
            Button { toggleRecording(e.id) } label: {
                Group {
                    if recording == e.id {
                        Text(loc: "keymap.pressKeys").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    } else if let b {
                        KeyCaps(binding: b)
                    } else {
                        Text(loc: "keymap.unbound").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 8).frame(minWidth: 70, minHeight: 24)
                .background(recording == e.id ? Theme.accent.opacity(0.15) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(recording == e.id ? Theme.accent : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("keymap.clickToRecord"))
            .testID("keymap.binding.\(e.id)")
            Menu {
                Button(tr("keymap.unbind")) { keymap.set(e.id, nil) }.disabled(b == nil)
                Button(tr("keymap.resetOne")) { keymap.reset(e.id) }.disabled(!changed)
            } label: { Image(systemName: "ellipsis").font(.system(size: 10)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Theme.textTertiary)
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator.opacity(0.6)).frame(height: 0.5) }
    }

    func toggleRecording(_ id: String) {
        if recording == id { stopRecording(); return }
        stopRecording()
        recording = id
        Keymap.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let esc = e.keyCode == 53 && e.modifierFlags.intersection(KeyBinding.relevantModifiers).isEmpty
            let key = ShortcutRegistry.key(for: e).map { KeyBinding($0, e.modifierFlags) }
            let consumed: Bool = MainActor.assumeIsolated {
                if esc { stopRecording(); return true }  // esc cancels
                guard let b = key, let id = recording else { return false }
                stopRecording()
                record(b, for: id)
                return true
            }
            return consumed ? nil : e
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        Keymap.isRecording = false
    }

    func record(_ b: KeyBinding, for id: String) {
        let c = keymap.conflicts(for: b, excluding: id)
        if c.isEmpty { keymap.set(id, b) } else { pending = (id, b, c) }
    }
}

/// Key glyphs: modifier symbols, named keys as small white rounded key caps (UX.md §8.2).
struct KeyCaps: View {
    let binding: KeyBinding
    var body: some View {
        let s = binding.display
        let mods = String(s.prefix { "⌃⌥⇧⌘".contains($0) })
        let key = String(s.dropFirst(mods.count))
        HStack(spacing: 3) {
            if !mods.isEmpty { Text(verbatim: mods).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary) }
            if key.count > 1 && !["←", "→", "↑", "↓", "⌫"].contains(key) {
                Text(verbatim: key).font(.system(size: 10, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Text(verbatim: key).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}
