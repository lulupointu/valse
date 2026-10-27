import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseAI
@testable import ValseUI
import ValseTestSupport

/// BUG-ERROR-COPY: errors are classified into reasons the user can act on (full disk, network, permission…), and
/// messages never carry raw error domains / codes (those go to Copy Details and the log).
@MainActor @Suite(.serialized) struct ErrorCopyTests {
    init() { EngineResources.register(); AIResources.register(); UIResources.register() }
    // MARK: file errors

    @Test func fileErrorKindFollowsUnderlyingErrors() {
        #expect(FileErrorKind.classify(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(FileErrorKind.classify(POSIXError(.ENOSPC)) == .diskFull)
        #expect(FileErrorKind.classify(CocoaError(.fileWriteNoPermission)) == .noPermission)
        #expect(FileErrorKind.classify(CocoaError(.fileWriteVolumeReadOnly)) == .readOnlyVolume)
        // URLSession / AVFoundation wrap the POSIX error
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(FileErrorKind.classify(wrapped) == .diskFull)
        #expect(FileErrorKind.classify(NSError(domain: "AVFoundationErrorDomain", code: -11800)) == .other)
    }

    @Test func offlineVolumeIsNamed() {
        #expect(FileErrorKind.offlineVolumeName(for: URL(fileURLWithPath: "/Volumes/NoSuchDrive-\(UUID().uuidString.prefix(6))/a.valse")) != nil)
        #expect(FileErrorKind.offlineVolumeName(for: URL(fileURLWithPath: "/tmp/a.valse")) == nil)
    }

    // MARK: model downloads (R7 / R8)

    @Test func modelFailureReasons() {
        #expect(ModelFailureReason.classify(URLError(.notConnectedToInternet)) == .network)
        #expect(ModelFailureReason.classify(URLError(.timedOut)) == .network)
        #expect(ModelFailureReason.classify(ModelError.httpStatus(503)) == .network)
        #expect(ModelFailureReason.classify(ModelError.checksumMismatch) == .damaged)
        #expect(ModelFailureReason.classify(ModelError.diskFull) == .diskFull)
        #expect(ModelFailureReason.classify(ModelError.io("x")) == .io)
        #expect(ModelFailureReason.classify(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        let full = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(ModelFailureReason.classify(full) == .diskFull)
        #expect(ModelFailureReason.classify(NSError(domain: "x", code: 1)) == .io)
        // a full disk says how much to free, and is not "check your connection"
        let size = ByteCountFormatter.string(fromByteCount: 574_000_000, countStyle: .file)
        let msg = ModelFailureReason.diskFull.message(bytes: 574_000_000)
        #expect(msg.contains(size))
        #expect(msg != ModelFailureReason.network.message(bytes: 574_000_000))
        #expect(!ModelFailureReason.notInstalled.message(bytes: 0).contains("missing"))
    }

    // MARK: export (R12 / R13 / R15)

    @Test func exportFailureKeepsCodesOutOfTheMessage() {
        let generic = ExportQueue.failure(ExportError.failed("writer: AVFoundationErrorDomain -11800"), title: "Trip")
        #expect(generic.message == tr("export.error.failed", "Trip"))
        #expect(!generic.message.contains("-11800"))
        #expect(generic.detail?.contains("-11800") == true)
        #expect(ExportQueue.failure(ExportError.failed("AVFoundationErrorDomain -11807"), title: "Trip").message == tr("export.error.space"))
        #expect(ExportQueue.failure(CocoaError(.fileWriteNoPermission), title: "Trip").message == tr("export.error.noPermission"))
        #expect(ExportQueue.failure(CocoaError(.fileWriteOutOfSpace), title: "Trip").message == tr("export.error.space"))
        #expect(ExportQueue.failure(ExportError.encoderUnavailable("mp3"), title: "Trip").message.contains("MP3"))
        let missing = ExportQueue.failure(ExportError.missingMedia(["a.mov"]), title: "Trip")
        #expect(missing.message.contains("a.mov") && missing.detail == nil)
    }

    // MARK: save (R11)

    @Test func saveFailureIsPersistentUntilASaveSucceeds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("errcopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let s = EditorStore(project: TestProject(canvas: Size2(320, 180)).project)
        s.autosaveEnabled = false
        s.saveAs(blocker.appendingPathComponent("Trip.valse"))   // a file is in the way: the save fails
        #expect(s.saveFailure == .other)
        #expect(s.toast == nil)   // a banner, not a 2.5 s toast
        #expect(SaveFailure.other.message(project: "Trip").contains("Trip"))
        s.saveAs(dir.appendingPathComponent("Trip.valse"))
        #expect(s.saveFailure == nil)
        s.close()
        #expect(SaveFailure.classify(CocoaError(.fileWriteOutOfSpace), url: dir) == .diskFull)
        if case .driveOffline(let name) = SaveFailure.classify(CocoaError(.fileNoSuchFile), url: URL(fileURLWithPath: "/Volumes/GoneDrive-x1/T.valse")) {
            #expect(name == "GoneDrive-x1")
        } else { Issue.record("expected driveOffline") }
    }

    // MARK: editing (R28)

    @Test func splitOutsideAClipSaysTheRule() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        _ = try await p.addVideo(.solid(.red), seconds: 2)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        #expect(throws: EditError.cannotSplitHere) { var pr = s.project; try SplitClips([], at: Time(30)).apply(to: &pr) }
        #expect(tr(EditError.cannotSplitHere.messageKey) != EditError.cannotSplitHere.messageKey)
    }
}
