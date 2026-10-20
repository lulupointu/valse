import SwiftUI
import Perception
import MontageCore

/// Saved compound presets (TL-021), one JSON file each in Application Support/Montage/CompoundPresets.
@MainActor @Perceptible
final class CompoundPresetLibrary {
    static let shared = CompoundPresetLibrary()
    private(set) var presets: [CompoundPreset] = []
    var directory: URL { MontagePaths.supportDirectory.appendingPathComponent("CompoundPresets", isDirectory: true) }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        presets = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CompoundPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    /// Returns false when the library is full (99).
    @discardableResult
    func save(_ p: CompoundPreset) -> Bool {
        guard presets.count < CompoundPreset.maxCount else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(p), (try? d.write(to: directory.appendingPathComponent("\(p.id.uuidString).json"), options: .atomic)) != nil
        else { return false }
        reload()
        return true
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        reload()
    }
}

extension EditorStore {
    /// Right-click a compound ▸ Save preset.
    public func saveCompoundPreset(_ clipID: ClipID) {
        guard let c = project.timeline.clip(clipID), case .compound(let cid) = c.content,
              let preset = CompoundPreset.make(cid, from: project, name: c.name ?? project.compound(cid)?.name) else { return }
        if CompoundPresetLibrary.shared.save(preset) { showToast(tr("preset.saved", preset.name)) }
        else { showToast(tr("preset.full", CompoundPreset.maxCount), error: true) }
    }

    /// Media ▸ Subprojects ▸ Presets ⊕: the preset becomes a subproject of this project and is added at the playhead.
    public func addCompoundPreset(_ preset: CompoundPreset) {
        let t = playhead
        let box = ResultBox(ClipID())
        if edit("cmd.addPreset", { p in
            let cid = try Subprojects.importProject(preset.asProject, name: preset.name, into: &p)
            box.value = try Subprojects.insert(cid, at: t, in: &p)
        }) { selection = [box.value] }
    }
}
