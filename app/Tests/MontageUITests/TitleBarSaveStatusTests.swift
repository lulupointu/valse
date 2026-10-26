import Testing
import Foundation
import MontageCore
@testable import MontageUI

/// VALSE-APP round 12: the title bar's inline rename and the quiet save status.
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

    @Test func aFullDiskGetsItsOwnReason() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(EditorStore.saveFailureKey(full) == "save.failed.diskFull")
        #expect(EditorStore.saveFailureKey(posix) == "save.failed.diskFull")
        #expect(EditorStore.saveFailureKey(wrapped) == "save.failed.diskFull")
        #expect(EditorStore.saveFailureKey(other) == "save.failed.generic")
    }

    @Test func aFailureStaysUntilASaveSucceeds() {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.saveEnded(failureKey: "save.failed.diskFull", explicit: false)
        #expect(s.saveStatus == .failed("save.failed.diskFull"))
        s.saveEnded(failureKey: "save.failed.diskFull", explicit: false)
        #expect(s.saveStatus == .failed("save.failed.diskFull"))
        s.saveEnded(failureKey: nil, explicit: false)
        // tests run quiet (no timed "Saved"); the failure is cleared either way
        #expect(s.saveStatus != .failed("save.failed.diskFull"))
    }

    @Test func quietFastAutosavesNeverChangeTheTitleBar() {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.saveBegan()
        s.saveEnded(failureKey: nil, explicit: false)
        #expect(s.saveStatus == .idle)
    }
}
