import Testing
import Foundation
@testable import MontageAI
@testable import MontageUI

/// OB-07: "Download required" popup → download (simulated, never the network) → the action runs; cancel paths.
@MainActor @Suite(.serialized) struct ModelDownloadFlowTests {
    /// A model that is never on disk (unique file name), so only the simulated manager state decides "installed".
    func spec() -> AIModelSpec {
        let u = UUID().uuidString
        return AIModelSpec(id: "test.\(u)", kind: .coreML, nameKey: "model.lama", descriptionKey: "model.lama.desc",
                           fileName: "montage-test-\(u).bin", url: URL(string: "https://invalid.example/\(u)")!,
                           bytes: 1_000_000, sha256: "", license: "MIT", runtimeMB: 1)
    }

    func finished(_ m: ModelManager, _ s: AIModelSpec) async -> AIModelState {
        await withCheckedContinuation { c in m.whenFinished(s) { c.resume(returning: $0) } }
    }

    @Test func installedRunsAtOnce() async {
        let m = ModelManager(); m.simulation = .complete
        let s = spec()
        m.download(s)
        #expect(await finished(m, s).isInstalled)
        let flow = ModelDownloadFlow(manager: m)
        var ran = 0
        flow.require([s]) { ran += 1 }
        #expect(ran == 1)
        #expect(flow.prompt == nil)
    }

    @Test func missingAsksAndCancelDoesNothing() {
        let m = ModelManager(); m.simulation = .complete
        let s = spec()
        let flow = ModelDownloadFlow(manager: m)
        var ran = 0
        flow.require([s]) { ran += 1 }
        #expect(flow.prompt?.specs.map(\.id) == [s.id])
        #expect(flow.prompt?.bytes == 1_000_000)
        flow.dismissPrompt()
        #expect(flow.prompt == nil)
        #expect(m.state(s) == .notInstalled)
        #expect(ran == 0)
        #expect(flow.pendingCount == 0)
    }

    @Test func downloadThenActionProceeds() async {
        let m = ModelManager(); m.simulation = .complete
        let s = spec()
        let flow = ModelDownloadFlow(manager: m)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            flow.require([s]) { c.resume() }
            flow.confirm()
            #expect(flow.prompt == nil)
            #expect(m.state(s).isBusy)
            #expect(flow.pendingCount == 1)
        }
        #expect(m.state(s).isInstalled)
        #expect(flow.proceeded == 1)
        #expect(flow.pendingCount == 0)
    }

    @Test func cancelNeedsConfirmation() async {
        let m = ModelManager(); m.simulation = .hold
        let s = spec()
        let flow = ModelDownloadFlow(manager: m)
        var ran = 0
        flow.require([s]) { ran += 1 }
        flow.confirm()
        flow.askCancel(s)
        #expect(flow.confirmingCancel.contains(s.id))
        #expect(m.state(s).isBusy)   // ✕ alone doesn't stop it
        flow.keepDownloading(s)
        #expect(!flow.confirmingCancel.contains(s.id))
        flow.askCancel(s)
        flow.confirmCancel(s)
        #expect(await finished(m, s) == .notInstalled)
        #expect(ran == 0)
        #expect(flow.pendingCount == 0)
        #expect(flow.confirmingCancel.isEmpty)
    }

    @Test func alreadyDownloadingWaitsWithoutPrompt() async {
        let m = ModelManager(); m.simulation = .complete
        let s = spec()
        m.download(s)
        let flow = ModelDownloadFlow(manager: m)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            flow.require([s]) { c.resume() }
            #expect(flow.prompt == nil)
        }
        #expect(flow.proceeded == 1)
    }
}
