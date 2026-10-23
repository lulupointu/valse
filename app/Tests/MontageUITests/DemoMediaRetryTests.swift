import Testing
import Foundation
@testable import MontageUI

/// FLAKY-FIN: building the demo media under load failed two back-to-back encoder attempts (UI-test setup "Code=62");
/// the writes are now retried with backoff.
@Suite struct DemoMediaRetryTests {
    final class Counter: @unchecked Sendable { var n = 0 }

    @Test func transientFailuresAreRetried() async throws {
        let c = Counter()
        try await DemoProject.withEncoderRetries {
            c.n += 1
            if c.n < 3 { throw NSError(domain: "Montage", code: 62) }
        }
        #expect(c.n == 3)
    }

    @Test func aPersistentFailureThrowsAfterFiveAttempts() async {
        let c = Counter()
        await #expect(throws: NSError.self) {
            try await DemoProject.withEncoderRetries {
                c.n += 1
                throw NSError(domain: "Montage", code: 62)
            }
        }
        #expect(c.n == 5)
    }
}
