import Testing
import Foundation
@testable import MontageCore

/// CAP-NOSPEAKER: projects saved while speaker ID existed (`Project.speakers`, `CaptionData.speaker`) still open; the
/// removed keys are ignored.
@Suite struct CaptionLegacyDecodeTests {
    @Test func oldProjectWithSpeakersStillOpens() throws {
        var p = Project(name: "old")
        var cap = TextContent(string: "Salut")
        cap.caption = CaptionData(words: [CaptionWord("Salut", start: 0, end: 0.5)], origin: .auto)
        try TimelineOps.insert(Clip(content: .text(cap), start: 1, duration: 1), into: &p)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.montage")
        try ProjectPackage.save(p, to: url)
        let json = url.appendingPathComponent("project.json")
        var text = try String(contentsOf: json, encoding: .utf8)
        // what the speaker-ID build wrote: a project-level speaker list and a speaker tag on the caption
        #expect(text.contains("\"origin\""))
        text = text.replacingOccurrences(of: "\"origin\"", with: "\"speaker\":\"2\",\"origin\"")
        guard let brace = text.firstIndex(of: "{") else { Issue.record("no JSON object"); return }
        text.insert(contentsOf: "\"speakers\":[{\"id\":\"1\",\"name\":\"Alice\",\"color\":{\"r\":1,\"g\":1,\"b\":1,\"a\":1}},{\"id\":\"2\"}],",
                    at: text.index(after: brace))
        try text.write(to: json, atomically: true, encoding: .utf8)
        let q = try ProjectPackage.load(from: url)
        let clips = q.timeline.tracks.flatMap(\.clips)
        #expect(clips.count == 1)
        #expect(clips.first.flatMap(CaptionOps.text)?.caption?.words.count == 1)
        #expect(clips.first.flatMap(CaptionOps.text)?.string == "Salut")
    }
}
