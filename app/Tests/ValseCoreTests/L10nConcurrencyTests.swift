import Testing
import Foundation
@testable import ValseCore

/// L10n under concurrent readers + language switches + bundle registration (check_clean flake: OwnerUIFixesU1Tests got
/// nil from `L10n.shared.strings(for: "fr")`). The old implementation published the new language / bundle list before
/// the matching table, ran reloads unserialized (a slow reload could overwrite a newer one) and could cache a table
/// loaded from an older bundle set; each of those makes a reader below see a wrong or incomplete table.
/// Uses a private instance: it never touches `L10n.shared`.
@Suite struct L10nConcurrencyTests {
    /// Thread-safe scratch state shared by the stress threads.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _registered: [Int] = []
        private var _failures: [String] = []
        private var _writersLeft: Int
        init(writers: Int) { _writersLeft = writers }
        var registered: [Int] { lock.withLock { _registered } }
        var writersDone: Bool { lock.withLock { _writersLeft == 0 } }
        var failures: [String] { lock.withLock { _failures } }
        func didRegister(_ i: Int) { lock.withLock { _registered.append(i) } }
        func writerFinished() { lock.withLock { _writersLeft -= 1 } }
        func fail(_ s: String) { lock.withLock { if _failures.count < 20 { _failures.append(s) } } }
    }

    /// A minimal resource bundle with one key per language: "stress.<i>" = "<lang> <i>".
    static func makeBundle(_ i: Int, in dir: URL) throws -> Bundle {
        let url = dir.appendingPathComponent("Stress\(i).bundle")
        for lang in ["en", "fr"] {
            let lproj = url.appendingPathComponent("\(lang).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try "\"stress.\(i)\" = \"\(lang) \(i)\";\n".write(to: lproj.appendingPathComponent("Stress.strings"), atomically: true, encoding: .utf8)
        }
        return try #require(Bundle(url: url))
    }

    /// Runs `bodies` on dedicated threads (not the cooperative pool) and resumes when all of them returned.
    static func onThreads(_ bodies: [@Sendable () -> Void]) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for body in bodies {
                group.enter()
                Thread { body(); group.leave() }.start()
            }
            group.notify(queue: .global()) { done.resume() }
        }
    }

    @Test func readersAlwaysSeeACompleteTableOfTheLanguageTheyAskFor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-stress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = 40
        let bundles = try (0..<count).map { try Self.makeBundle($0, in: dir) }
        #expect(L10n.load("fr", from: [bundles[0]])["stress.0"] == "fr 0")

        let l = L10n(bundles: [CoreResources.bundle], language: "en")
        let box = Box(writers: 3)
        let expected = ["en": "Split", "fr": "Fractionner"]
        var bodies: [@Sendable () -> Void] = []
        // two language flippers + one registrar
        for w in 0..<2 {
            bodies.append {
                for k in 0..<150 { l.setLanguageForSession((k + w) % 2 == 0 ? "fr" : "en") }
                box.writerFinished()
            }
        }
        bodies.append {
            for (i, b) in bundles.enumerated() {
                l.register(b)
                box.didRegister(i)
                if i % 2 == 0 { l.register(b) }   // idempotent
            }
            box.writerFinished()
        }
        // readers: every bundle registered before the read must be in the table, in the language asked for
        for r in 0..<4 {
            bodies.append {
                var n = 0
                repeat {
                    n += 1
                    let lang = (n + r) % 2 == 0 ? "fr" : "en"
                    let done = box.registered
                    let t = l.strings(for: lang)
                    if t["cmd.split"] != expected[lang] { box.fail("strings(for: \(lang))[cmd.split] = \(t["cmd.split"] ?? "nil")") }
                    for i in done where t["stress.\(i)"] != "\(lang) \(i)" {
                        box.fail("strings(for: \(lang)) misses registered bundle \(i): \(t["stress.\(i)"] ?? "nil")"); break
                    }
                    let s = l.string("cmd.split")
                    if s != "Split" && s != "Fractionner" { box.fail("string(cmd.split) = \(s)") }
                } while !box.writersDone
            }
        }
        await Self.onThreads(bodies)
        #expect(box.failures.isEmpty, "\(box.failures)")

        // final state: no lost update, every bundle present in both languages and in the active table
        for lang in ["en", "fr"] {
            let t = l.strings(for: lang)
            #expect((0..<count).allSatisfy { t["stress.\($0)"] == "\(lang) \($0)" }, "\(lang) table misses registered bundles")
        }
        let lang = l.language
        #expect((0..<count).allSatisfy { l.string("stress.\($0)") == "\(lang) \($0)" })
        #expect(l.keys(for: "fr").isSuperset(of: (0..<count).map { "stress.\($0)" }))
    }
}
