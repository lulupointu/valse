import AppKit
import Sparkle
import MontageUI

/// Automatic updates (SE-015) with Sparkle 2: the `UpdateController.Backend` the About panel and the update banner use.
///
/// - Feed: Info.plist `SUFeedURL` (the `appcast.xml` asset of the latest GitHub release, scripts/release.sh); every
///   archive is verified against `SUPublicEDKey` (EdDSA) and the app's code signature before it installs.
/// - Silent: the user driver below never shows a window. Updates download in the background and install when Montage
///   quits; `UpdateController.installNow` ("Restart to update") quits through the normal path (project saved, jobs
///   stopped) and relaunches. Background checks that fail (offline, server down) report nothing.
/// - "Check now" runs the same background flow; only its outcome is shown, inline in Settings ▸ About.
/// - Started only for a real .app bundle with a feed and a key, never for UI tests, screenshots or `swift run`.
@MainActor
final class SparkleUpdater: NSObject, UpdateController.Backend {
    private var updater: SPUUpdater!
    private let controller: UpdateController
    private let driver: SilentUserDriver

    static func startIfConfigured(controller: UpdateController = .shared) -> SparkleUpdater? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return nil }
        let u = SparkleUpdater(controller: controller)
        do {
            try u.updater.start()
        } catch {
            NSLog("Montage updater disabled: \(error.localizedDescription)")
            return nil
        }
        // A manual "Check now" downloads too, also when background checks are off: the update then installs on quit.
        u.updater.automaticallyDownloadsUpdates = true
        controller.attach(u)
        return u
    }

    private init(controller: UpdateController) {
        self.controller = controller
        driver = SilentUserDriver(controller: controller)
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    }

    // MARK: UpdateController.Backend

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var checkInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }
    var lastCheck: Date? { updater.lastUpdateCheckDate }

    func checkNow() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated {
            if case .ready = controller.state { return }
            controller.state = .downloading(version: v, progress: nil)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            // background checks stay silent; a user check shows "up to date"
            if controller.state == .checking { controller.state = .upToDate }
            controller.checkFinished()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        let noUpdate = (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == Int(SUError.noUpdateError.rawValue)
        MainActor.assumeIsolated {
            switch controller.state {
            case .checking: controller.state = noUpdate ? .upToDate : .failed(message: message)
            case .downloading: controller.state = .idle   // a failed background download retries at the next check
            default: break
            }
            controller.checkFinished()
        }
    }

    /// Downloaded and verified: Sparkle installs it when Montage quits; the banner offers to do it now.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallationBlock
        MainActor.assumeIsolated {
            controller.updateReady(version: v) { install() }
            controller.checkFinished()
        }
        return true
    }
}

/// Sparkle user driver that never shows UI: it answers every question the way a silent auto-updater would and forwards
/// progress to `UpdateController`. It is used when Sparkle cannot install on its own (e.g. the app folder needs an admin
/// password): the update still downloads, and "Restart to update" installs it (macOS asks for the password then).
@MainActor
final class SilentUserDriver: NSObject, SPUUserDriver {
    private let controller: UpdateController
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var version = ""

    init(controller: UpdateController) { self.controller = controller }

    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist SUEnableAutomaticChecks makes this unreachable; answer "check automatically" without asking.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // informational items have no archive to install
        if appcastItem.isInformationOnlyUpdate { reply(.dismiss); return }
        let v = appcastItem.displayVersionString
        nonisolated(unsafe) let reply = reply
        MainActor.assumeIsolated {
            version = v
            switch state.stage {
            case .notDownloaded:
                controller.state = .downloading(version: v, progress: nil)
                reply(.install)   // download now; showReadyToInstallAndRelaunch follows
            case .downloaded, .installing:
                controller.updateReady(version: v) { reply(.install) }
            @unknown default:
                reply(.dismiss)
            }
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    nonisolated func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()   // reported (for user checks only) by SparkleUpdater's didAbortWithError
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { expected = 0; received = 0 }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { expected = expectedContentLength }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            received += length
            guard expected > 0, case .downloading = controller.state else { return }
            controller.state = .downloading(version: version, progress: min(1, Double(received) / Double(expected)))
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {}
    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        nonisolated(unsafe) let reply = reply
        MainActor.assumeIsolated {
            controller.updateReady(version: version) { reply(.install) }
        }
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {}
    nonisolated func dismissUpdateInstallation() {}
}
