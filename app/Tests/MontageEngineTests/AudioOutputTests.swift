import Testing
import Foundation
import MontageCore
import MontageEngine

/// Tests never play sound on the user's speakers: the test scripts export MONTAGE_MUTE_AUDIO=1 (scripts/lib.sh).
@MainActor struct AudioOutputTests {
    @Test func testRunsAreSilent() {
        guard ProcessInfo.processInfo.environment["MONTAGE_MUTE_AUDIO"] == "1" else { return }   // plain `swift test`
        #expect(AudioOutput.isSilenced)
        #expect(AudioOutput.volume(0.6) == 0)
        #expect(PlaybackEngine(project: Project()).player.volume == 0)
    }
}
