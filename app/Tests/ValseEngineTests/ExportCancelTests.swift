@preconcurrency import AVFoundation
import Foundation
import Testing
import ValseCore
import ValseEngine
import ValseTestSupport

/// A user's cancel of an export whose read is stuck inside AVFoundation (copyNextSampleBuffer never returning) must not
/// hang: the export is abandoned at once (cancelled, partial file removed) and its reader stays parked — never freed or
/// cancelled while being read — until the copy returns; then it is cancelled and released (DX-C, ReaderCancel).
///
/// FLAKY-ENG: the test used to wait for the stuck read with a 30 s poll budget, then assert the cancel took < 1 s.
/// Under load the export only reached its 5th read late: it first waits for an `ExportGate` slot (≤ cores/2 exports
/// at once in the process, the other ValseEngineTests exports hold them, each slow on a loaded machine) — 30 s ran out
/// ("the injected read never blocked", 5 flakes at load 9-86, all ~40 s into the test). The test now awaits EVENTS:
/// the stuck read itself (or the export's end, which shows its error), the cancelled export's return, and the
/// parked reader's clean-up (`ParkedReaders.waitUntilCleanedUp`). "At once" is checked by causality instead of a
/// stopwatch: the cancelled export returns while the read is still blocked (the gate is released only afterwards), so
/// it cannot have waited for it. A watchdog thread turns a deadlock into a failure (it only fires if the export waits
/// for the stuck read, i.e. never returns: not a speed budget).
@Suite struct ExportCancelTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var copies = 0
        func copy() -> Int { lock.withLock { copies += 1; return copies } }
        var count: Int { lock.withLock { copies } }
    }

    /// First event wins: the injected read blocked, or the export ended before it did.
    final class FirstEvent: @unchecked Sendable {
        enum Event: Sendable { case readBlocked, exportEnded }
        private let lock = NSLock()
        private var value: Event?
        private var waiter: CheckedContinuation<Event, Never>?
        func fire(_ e: Event) {
            let w: CheckedContinuation<Event, Never>? = lock.withLock {
                guard value == nil else { return nil }
                value = e
                defer { waiter = nil }
                return waiter
            }
            w?.resume(returning: e)
        }
        func wait() async -> Event {
            await withCheckedContinuation { (c: CheckedContinuation<Event, Never>) in
                let v: Event? = lock.withLock { if value == nil { waiter = c }; return value }
                if let v { c.resume(returning: v) }
            }
        }
    }

    /// Releases the stuck read exactly once (by the test, or by the deadlock watchdog).
    final class Gate: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var opened = false, byWatchdog = false
        func block() { sem.wait() }
        @discardableResult func open(watchdog: Bool = false) -> Bool {
            let first: Bool = lock.withLock {
                guard !opened else { return false }
                opened = true; byWatchdog = watchdog
                return true
            }
            if first { sem.signal() }
            return first
        }
        var isOpen: Bool { lock.withLock { opened } }
        var openedByWatchdog: Bool { lock.withLock { byWatchdog } }
    }

    @Test func userCancelAbandonsAStuckReadAndReleasesItAfterTheCopyReturns() async throws {
        var p = TestProject()
        try await p.addVideo(.movingBox(.red, .white), seconds: 3, audioHz: 440)
        var s = ExportSettings(); s.resolution = .p480
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("valse-cancel-\(UUID().uuidString).\(s.fileExtension)")
        let gate = Gate(), reads = Box(), event = FirstEvent()
        // the 5th video read of THIS export blocks (a stuck AVFoundation read) until the test releases it
        Exporter.testWillCopy = { id, label in
            guard id == url.path, label == "export.video", reads.copy() == 5 else { return }
            event.fire(.readBlocked)
            gate.block()
        }
        defer { Exporter.testWillCopy = nil; gate.open() }
        let project = p.project
        let task = Task {
            defer { event.fire(.exportEnded) }
            return try await Exporter.export(project: project, settings: s, to: url)
        }
        // No time budget: the export reaches its 5th read whenever it gets an ExportGate slot and decodes 5 frames;
        // if it ends first (an export error), that ends the wait and the error is reported.
        guard await event.wait() == .readBlocked else {
            var outcome = "completed"
            do { try await task.value } catch { outcome = "failed: \(error)" }
            Issue.record("the export ended before its 5th video read (\(outcome), reads \(reads.count))")
            return
        }

        // Deadlock watchdog (own thread: it must work even if the cooperative pool were stuck). It only fires when
        // the cancelled export still has not returned after 120 s, i.e. it is waiting for the read we hold.
        let returned = Gate()
        Thread.detachNewThread {
            let deadline = Date().addingTimeInterval(120)
            while !returned.isOpen && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if !returned.isOpen { gate.open(watchdog: true) }
        }
        task.cancel()
        await #expect(throws: ExportError.cancelled) { try await task.value }
        returned.open()
        #expect(!gate.isOpen, "the cancel returned only once the stuck read was released (watchdog: \(gate.openedByWatchdog))")
        #expect(!FileManager.default.fileExists(atPath: url.path), "partial output left behind")
        #expect(ParkedReaders.shared.isParked(url.path), "the stuck reader must stay parked while it is being read")
        #expect(!ParkedReaders.shared.wasCleanedUp(url.path), "nothing may cancel / release it before its copy returns")

        gate.open()   // the stuck copy returns
        await ParkedReaders.shared.waitUntilCleanedUp(url.path)
        #expect(ParkedReaders.shared.wasCleanedUp(url.path))
        #expect(!ParkedReaders.shared.isParked(url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
