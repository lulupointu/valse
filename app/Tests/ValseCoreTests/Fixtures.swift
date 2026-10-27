import Foundation
@testable import ValseCore

/// Small builders for Core tests.
enum Fx {
    static func video(_ name: String = "v", seconds: Double = 10, size: Size2 = .hd1080) -> MediaAsset {
        MediaAsset(name: name, kind: .video, url: URL(fileURLWithPath: "/tmp/\(name).mp4"), duration: Time(seconds),
                   pixelSize: size, frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: UUID().uuidString)
    }
    static func audio(_ name: String = "a", seconds: Double = 30) -> MediaAsset {
        MediaAsset(name: name, kind: .audio, url: URL(fileURLWithPath: "/tmp/\(name).m4a"), duration: Time(seconds),
                   pixelSize: .zero, frameRate: nil, hasVideo: false, hasAudio: true, contentHash: UUID().uuidString)
    }

    /// Project with `n` main-track clips of `seconds` each (media of 10 s).
    static func project(mainClips n: Int, seconds: Double = 4) -> (Project, [ClipID]) {
        var p = Project(name: "Test")
        var ids: [ClipID] = []
        for i in 0..<n {
            let a = video("v\(i)")
            p.media.append(a)
            var c = TimelineOps.makeClip(for: a, at: Time(1000))  // dropped at the end
            c.duration = Time(seconds)
            try! TimelineOps.insert(c, into: &p)
            ids.append(c.id)
        }
        return (p, ids)
    }

    static func main(_ p: Project) -> [Clip] { p.timeline.mainTrack!.clips }
}
