import Testing
import Foundation
@testable import MontageUI

/// SE-015: automatic-update state machine (no Sparkle, no network): background results stay silent, a user check
/// reports, a downloaded update shows the banner until "Later", "Restart to update" runs the backend's installer.
@MainActor @Suite struct UpdateControllerTests {
    func make() -> (UpdateController, PreviewBackend) {
        let c = UpdateController()
        let b = PreviewBackend(controller: c)
        c.attach(b)
        return (c, b)
    }

    @Test func unavailableWithoutBackend() {
        let c = UpdateController()
        #expect(!c.isAvailable)
        #expect(!c.automaticallyChecks)
        c.checkNow()
        #expect(c.state == .idle)
    }

    @Test func userCheckReportsUpToDate() {
        let (c, b) = make()
        #expect(c.isAvailable)
        c.checkNow()
        #expect(b.checks == 1)
        #expect(c.state == .upToDate)
        #expect(c.lastCheck != nil)
    }

    @Test func backgroundResultsStaySilent() {
        let (c, b) = make()
        b.checkNow()   // a scheduled check: the controller never asked, nothing to show
        #expect(c.state == .idle)
    }

    @Test func readyShowsBannerUntilLater() {
        let (c, _) = make()
        var installed = 0
        c.updateReady(version: "0.3.0") { installed += 1 }
        #expect(c.showsBanner)
        c.bannerDismissedFor = "0.3.0"
        #expect(!c.showsBanner)
        c.installNow()
        #expect(installed == 1)
        // a newer version shows the banner again
        c.updateReady(version: "0.4.0") {}
        #expect(c.showsBanner)
        // no new check once an update waits to install
        c.checkNow()
        #expect(c.state == .ready(version: "0.4.0"))
    }

    @Test func settingsReachTheBackend() {
        let (c, b) = make()
        c.automaticallyChecks = false
        #expect(!b.automaticallyChecks)
        c.interval = .hourly
        #expect(b.checkInterval == 3600)
        b.checkInterval = 90_000
        #expect(c.interval == .daily)
    }
}
