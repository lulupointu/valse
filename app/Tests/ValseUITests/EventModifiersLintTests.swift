import Testing
import Foundation

/// FLAKY-UI4: actions read the modifiers of the event they handle (`EventModifiers.current`), never the hardware state
/// `NSEvent.modifierFlags` (a key held on the real keyboard flipped Return into ⇧Return in the caption search while UI
/// tests ran: cap_editor_tools). Source lint over ValseUI.
struct EventModifiersLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ValseUI")

    @Test func actionsReadTheEventsOwnModifiers() throws {
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "swift" { files.append(u) }
        }
        #expect(files.count > 100, "ValseUI sources not found at \(Self.sources.path)")
        var hits: [String] = []
        for f in files where f.lastPathComponent != "EventModifiers.swift" {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains("NSEvent.modifierFlags") {
                hits.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        #expect(hits.isEmpty, "use EventModifiers.current (the handled event's flags), not NSEvent.modifierFlags: \(hits)")
    }
}
