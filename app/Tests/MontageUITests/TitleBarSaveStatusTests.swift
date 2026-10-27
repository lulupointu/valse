import Testing
import Foundation
import MontageCore
@testable import MontageUI

/// VALSE-APP round 12: the title bar's inline rename and the quiet save status (the failure's reason and fix are
/// BUG-ERROR-COPY's `saveFailure` banner).
@MainActor @Suite(.serialized) struct TitleBarSaveStatusTests {
    @Test func renameIsOneUndoStepAndIgnoresBlankOrUnchangedNames() {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.load(project: Project(name: "0127"))
        s.renameProject("   ")
        s.renameProject("0127")
        #expect(s.projectName == "0127" && !s.canUndo)
        s.renameProject("  Road trip  ")
        #expect(s.projectName == "Road trip" && s.canUndo)
        s.undo()
        #expect(s.projectName == "0127")
    }

    @Test func aFailureStaysUntilASaveSucceeds() {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.saveEnded(ok: false, explicit: false)
        #expect(s.saveStatus == .failed)
        s.saveEnded(ok: false, explicit: false)
        #expect(s.saveStatus == .failed)
        s.saveEnded(ok: true, explicit: false)
        #expect(s.saveStatus != .failed)
    }

    @Test func quietFastAutosavesNeverChangeTheTitleBar() {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.saveBegan()
        s.saveEnded(ok: true, explicit: false)
        #expect(s.saveStatus == .idle)
    }
}
