import Foundation
import MontageCore
import MontageEngine

/// UI tests (C4): `"project": "demo-transcript:captions"` = the demo project with a caption track made from known words
/// on its 3 main-track clips (no speech model needed). `:partial` leaves the last clip without captions.
@MainActor
public enum TranscriptDemo {
    /// Word lists per main-track clip (media seconds).
    static let words: [[(String, Double, Double)]] = [
        [("Hello", 1.2, 1.5), ("euh", 1.6, 1.9), ("welcome", 2.0, 2.4), ("to", 2.45, 2.6), ("the", 2.65, 2.8), ("show.", 2.85, 3.2),
         ("Today", 4.8, 5.1)],
        [("we", 0.3, 0.5), ("we", 0.55, 0.75), ("talk", 0.8, 1.1), ("about", 1.15, 1.4), ("captions.", 1.45, 1.9)],
        [("um", 2.0, 2.3), ("so,", 2.4, 2.6), ("like,", 2.7, 3.0), ("it", 3.1, 3.2), ("works.", 3.25, 3.7)],
    ]

    public static func load(_ spec: String, into store: EditorStore) async throws {
        var p = try await DemoProject.make()
        let main = p.timeline.mainTrack?.clips ?? []
        var segments: [CaptionSegment] = []
        for (i, c) in main.prefix(spec.contains("partial") ? 2 : words.count).enumerated() {
            guard c.mediaID != nil else { continue }
            let ws = words[i].map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2, confidence: 0.95) }
            let origin = c.start.seconds - c.sourceStart.seconds
            let tl = ws.map { (text: $0.text, start: $0.start + origin, end: $0.end + origin) }
            if let a = tl.first, let b = tl.last {
                segments.append(CaptionSegment(text: tl.map(\.text).joined(separator: " "), start: a.start, end: b.end, words: tl))
            }
        }
        if spec.contains("captions"), let id = CaptionOps.addCaptionTrack(segments, to: &p) {
            SpeechCaptions.finish(trackID: id, in: &p)
        }
        store.load(project: p)
        store.ai.captionLanguage = nil
    }
}
