import Foundation
import ValseCore
import ValseEffects
import Perception

/// Bubbles saved by the user (TX-BUBBLE2 round 3, "Save bubble", Bubble ▸ Yours): the bubble style only (shape, fill,
/// outline, neon, shadow, tail, padding), never a text style. App-wide (not per project), JSON in Application Support
/// next to the text presets (`TextPresetStore`), so they persist across launches; UI tests use their sandboxed
/// support directory.
@MainActor @Perceptible
final class BubblePresetStore {
    static let shared = BubblePresetStore(url: ValsePaths.supportDirectory.appendingPathComponent("bubble-presets.json"))
    /// Group id of the saved bubbles (the "Yours" pill, `TextUIState.bubbleGroup`).
    static let group = "text.bubble.group.yours"

    struct Preset: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var style: TextBubbleStyle
    }

    private(set) var presets: [Preset] = []
    @PerceptionIgnored let url: URL

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([Preset].self, from: d) { presets = p }
    }

    /// Next "Bubble N" not in use.
    func nextName() -> String {
        var n = presets.count + 1
        while presets.contains(where: { $0.name == tr("text.bubble.savedName", n) }) { n += 1 }
        return tr("text.bubble.savedName", n)
    }

    /// Newest first.
    @discardableResult
    func add(style: TextBubbleStyle, name: String) -> Preset {
        let p = Preset(name: name, style: style)
        presets.insert(p, at: 0)
        save()
        return p
    }

    func remove(_ id: UUID) { presets.removeAll { $0.id == id }; save() }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = presets.firstIndex(where: { $0.id == id }), !n.isEmpty else { return }
        presets[i].name = n
        save()
    }

    /// Tiny file, rare action: written right away (atomic), so a quit right after saving keeps it.
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(presets) { try? d.write(to: url, options: .atomic) }
    }
}
