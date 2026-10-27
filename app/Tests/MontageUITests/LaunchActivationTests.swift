import Testing
@testable import MontageUI

/// VALSE-HOME bug 1: normal launches activate (and never touch the policy before `run`), headless runs never do.
@MainActor @Suite struct LaunchActivationTests {
    let exe = "/Applications/Montage.app/Contents/MacOS/Montage"

    @Test func normalBundledLaunchActivatesWithoutChangingThePolicy() {
        for args in [[exe], [exe, "--open", "/tmp/a.montage"], [exe, "--demo"], [exe, "--lang", "fr"],
                     [exe, "-NSDocumentRevisionsDebugMode", "YES"]] {
            let p = LaunchActivation.plan(arguments: args, isAppBundle: true)
            #expect(p.activates, "\(args)")
            #expect(p.policyBeforeRun == nil, "\(args): no setActivationPolicy before run (lost the launch activation)")
            #expect(p.policyAfterLaunch == nil, "\(args): Info.plist already makes the bundle .regular")
        }
    }

    @Test func unbundledDevBinaryBecomesRegularAfterLaunch() {
        let p = LaunchActivation.plan(arguments: ["/x/.build/debug/Montage"], isAppBundle: false)
        #expect(p.activates)
        #expect(p.policyBeforeRun == nil)
        #expect(p.policyAfterLaunch == .regular)
    }

    @Test func testSnapshotAndOffscreenRunsNeverActivate() {
        let runs: [[String]] = [
            [exe, "--uitest", "app/Tests/UIScripts/home_library.json"],
            [exe, "--background", "--window-id-file", "/tmp/w"],
            [exe, "--snapshot", "/tmp/s.png", "--quit-after", "24"],
            [exe, "--offscreen"],
            [exe, "--home-demo", "40", "--ui-state", "home"],
        ]
        for bundled in [true, false] {
            for args in runs {
                let p = LaunchActivation.plan(arguments: args, isAppBundle: bundled)
                #expect(!p.activates, "\(args)")
                #expect(p.policyBeforeRun == .accessory, "\(args): no Dock icon, no launch activation")
                #expect(p.policyAfterLaunch == nil, "\(args)")
            }
        }
    }

    @Test func flagValuesAndTheExecutablePathAreNotFlags() {
        // the executable itself is never read as a flag; a project path containing a flag-like word is a value
        #expect(LaunchActivation.plan(arguments: ["--uitest"], isAppBundle: true).activates)
        #expect(LaunchActivation.plan(arguments: [exe, "--open", "/tmp/--snapshot-notes.montage"], isAppBundle: true).activates)
    }
}
