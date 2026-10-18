import Foundation
import MontageCore

/// Compound clips (TL-021): create from the selection (⌥G) / undo compound clip. Rendering is nested in the compositor.
extension EditorStore {
    public func createCompound() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let name = tr("clip.compoundN", (project.compounds?.count ?? 0) + 1)
        let box = UncheckedSendableBox<ClipID?>(nil)
        if perform(Edit("cmd.compound") { p in box.value = try TimelineOps.createCompound(ids, name: name, in: &p) }),
           let id = box.value {
            selection = [id]
        }
    }

    public func explodeCompound() {
        guard let c = singleSelectedClip, case .compound = c.content else { return }
        let id = c.id
        perform(Edit("cmd.uncompound") { p in try TimelineOps.explodeCompound(id, in: &p) })
    }
}

nonisolated final class UncheckedSendableBox<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
