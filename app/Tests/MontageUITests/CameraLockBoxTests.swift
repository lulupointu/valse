import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageAI
@testable import MontageUI
import MontageTestSupport

/// AI-013 Custom box (Video ▸ Basic ▸ Camera tracking): picking "Custom box" while the default Face detection is still
/// running replaces it — the detection job is cancelled, the box tool takes over the canvas, and the cancelled
/// detection writes nothing. (The ai_camera_custom_box UI script can't check this deterministically: on its faceless
/// demo clip the detection ends after a load-dependent time, FLAKY-SYS-UI.)
@MainActor @Suite(.serialized) struct CameraLockBoxTests {
    @Test func customBoxCancelsARunningFaceDetection() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let v = try await p.addVideo(.movingBox(RGBA(0.2, 0.3, 0.5), RGBA(0.9, 0.9, 0.8)), seconds: 4)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        defer { s.endLockBox(); CameraLockUIState.shared.options = CameraLockOptions() }

        // Keep the detection from finishing before the box is picked: hold the heavy-work gate (a heavy job in a test
        // process waits for it, queued) from a task of its own, so the store's job does not inherit the hold.
        let (heldSignal, held) = AsyncStream<Void>.makeStream()
        let (goSignal, go) = AsyncStream<Void>.makeStream()
        let holder = Task.detached {
            await HeavyWorkGate.run {
                held.yield(())
                for await _ in goSignal { break }
            }
        }
        defer { go.finish() }
        for await _ in heldSignal { break }

        // ticking the section with the default target starts the Face detection
        s.cameraLock(v, options: CameraLockOptions(target: .face))
        let deadline = Date().addingTimeInterval(30)
        while s.ai.cameraJobs[v] == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let job = try #require(s.ai.cameraJobs[v], "the detection job was never registered")
        #expect(await JobQueue.shared.snapshot.first { $0.id == job }?.state == .queued)

        // Custom box: the running detection is replaced
        CameraLockUIState.shared.options.target = .custom
        CameraLockUIState.shared.options.customBox = nil
        s.beginLockBox(v)
        #expect(s.ai.cameraJobs[v] == nil)
        let tool = try #require(CameraLockUIState.shared.boxTool)
        #expect(tool.clipID == v)
        #expect(s.playerUI.canvasTool === tool)
        // (polled, not `wait`: a job that was NOT cancelled stays queued behind the held gate and would hang the test)
        var state = await JobQueue.shared.snapshot.first { $0.id == job }?.state
        let cancelDeadline = Date().addingTimeInterval(10)
        while state == .queued, Date() < cancelDeadline {
            try await Task.sleep(for: .milliseconds(10))
            state = await JobQueue.shared.snapshot.first { $0.id == job }?.state
        }
        #expect(state == .cancelled)

        go.yield(()); go.finish()
        await holder.value
        // the cancelled detection applied nothing (no keyframes, no camera lock, no undo step)
        #expect(s.project.timeline.clip(v)?.cameraLock == nil)
        #expect(s.session.undoStack.isEmpty)
    }
}
