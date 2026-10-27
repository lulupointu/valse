import Foundation
import ValseEngine

/// Clean stop of background work on app quit / at the end of a UI test.
///
/// Quitting while a Core ML / Metal job was mid-inference crashed in the frameworks' atexit teardown (MPSGraph logging
/// on a worker thread while `exit` ran the C++ static destructors; seen with LaMa AI remove). Quit now cancels every
/// `JobQueue` job (AI, proxies, analyses: their loops check cancellation between frames, sidecars are terminated by
/// their cancellation handlers) and every running export, then waits for the job bodies to return. If something is
/// still running at the timeout, `exit` leaves through `_exit`, which skips that teardown.
@MainActor
public enum AppShutdown {
    /// The editor store whose exports are stopped too (set by the app shell).
    public static weak var store: EditorStore?
    /// True when the last `stopBackgroundWork` timed out with job bodies still running.
    public private(set) static var workStillRunning = false

    public static func stopBackgroundWork(timeout: Double = 8) async {
        store?.exports.queue.cancelAll()
        store?.cancelPilotWork()
        QuickCutPrefetch.cancelAll()   // TL-048 background blank analyses
        let ok = await JobQueue.shared.shutdown(timeout: timeout)
        // readers of cancelled exports stuck inside AVFoundation: a bounded wait, never a hang at quit
        let readersOK = await ParkedReaders.shared.waitAll(timeout: 2)
        workStillRunning = !ok || !readersOK
        // let exports observe their cancellation and delete partial files
        if let q = store?.exports.queue {
            let deadline = Date().addingTimeInterval(2)
            while q.items.contains(where: \.isActive), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// Process exit that never runs framework teardown under live GPU/ANE work.
    public static func exit(_ code: Int32) -> Never {
        fflush(stdout); fflush(stderr)
        if workStillRunning { _exit(code) }
        Foundation.exit(code)
    }
}
