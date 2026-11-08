import Testing
import Foundation
@testable import ValseUI

/// BUG-PLAYER-FULLSCREEN-EXIT: leaving the player full screen only leaves the native (Spaces) full screen when the
/// player full screen entered it itself. Uses a fake window: no real window is ever made full screen.
@MainActor @Suite(.serialized) struct PlayerFullscreenExitTests {
    final class FakeWindow: NativeFullscreenWindow {
        var isNativeFullscreen: Bool
        var toggles = 0
        init(fullscreen: Bool) { isNativeFullscreen = fullscreen }
        func toggleNativeFullscreen() { toggles += 1; isNativeFullscreen.toggle() }
    }

    func store(_ w: FakeWindow?) -> EditorStore {
        let s = EditorStore()
        s.playerUI.fullscreenCoordinator.windowProvider = { w }
        return s
    }

    @Test func windowedAppEntersAndLeavesNativeFullscreenWithThePlayer() {
        let w = FakeWindow(fullscreen: false), s = store(w)
        s.setPlayerFullscreen(true)
        #expect(s.playerUI.isFullscreen && w.isNativeFullscreen && w.toggles == 1)
        s.setPlayerFullscreen(false)
        #expect(!s.playerUI.isFullscreen && !w.isNativeFullscreen && w.toggles == 2)
    }

    @Test func appAlreadyInItsOwnSpaceStaysFullscreenAfterExit() {
        let w = FakeWindow(fullscreen: true), s = store(w)
        s.togglePlayerFullscreen()
        #expect(s.playerUI.isFullscreen && w.toggles == 0)
        s.togglePlayerFullscreen()   // the exit button, ⇧⌘F and esc all end here
        #expect(!s.playerUI.isFullscreen && w.isNativeFullscreen && w.toggles == 0)
    }

    @Test func userLeavingNativeFullscreenTheplayerEnteredEndsThePlayerFullscreen() {
        let w = FakeWindow(fullscreen: false), s = store(w)
        s.setPlayerFullscreen(true)
        w.isNativeFullscreen = false                       // green button / ⌃⌘F
        s.playerUI.fullscreenCoordinator.nativeFullscreenDidExit()
        #expect(!s.playerUI.isFullscreen && w.toggles == 1)
        #expect(!s.playerUI.fullscreenCoordinator.ownsNativeFullscreen)
    }

    @Test func userLeavingAPreexistingNativeFullscreenKeepsThePlayerAndExitTogglesNothing() {
        let w = FakeWindow(fullscreen: true), s = store(w)
        s.setPlayerFullscreen(true)
        w.isNativeFullscreen = false
        s.playerUI.fullscreenCoordinator.nativeFullscreenDidExit()
        #expect(s.playerUI.isFullscreen)
        w.isNativeFullscreen = true                        // and back into its Space by hand
        s.setPlayerFullscreen(false)
        #expect(w.isNativeFullscreen && w.toggles == 0)
    }

    @Test func ownExitDoesNotReportAUserExitAndNoWindowIsHarmless() {
        let w = FakeWindow(fullscreen: false), s = store(w)
        s.setPlayerFullscreen(true)
        s.setPlayerFullscreen(false)
        s.playerUI.fullscreenCoordinator.nativeFullscreenDidExit()   // the notification of our own exit
        #expect(!s.playerUI.isFullscreen && w.toggles == 2)
        let none = store(nil)
        none.setPlayerFullscreen(true)
        #expect(none.playerUI.isFullscreen)
        none.setPlayerFullscreen(false)
        #expect(!none.playerUI.isFullscreen)
    }
}
