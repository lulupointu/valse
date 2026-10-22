import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// SP-009 frame-rate up-conversion, SP-010 time-lapse speeds.
@Suite struct FinisherSpeedRenderTests {
    @Test func smoothPlaybackInterpolatesBelowProjectRate() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.alternate(.black, .white), seconds: 1)   // 30 fps source
        p.project.settings.frameRate = .fps60
        #expect(FrameUpconversion.candidates(p.project) == [id])
        // t = 17/60 s → source frame 8.5 at 1× (black, next white)
        let t = 17.0 / 60
        #expect(TimeRemapTests.level(try await p.render(at: t)) < 10)
        p[id].smoothSlowMo = .frameBlending
        let v = TimeRemapTests.level(try await p.render(at: t))
        #expect(abs(v - 127.5) < 14, "v \(v)")
        // same rate as the project: nothing to interpolate, nothing changes
        p.project.settings.frameRate = .fps30
        #expect(FrameUpconversion.candidates(p.project).isEmpty)
        #expect(!FrameUpconversion.needsInterpolation(rate: 1, sourceRate: .fps30, projectRate: .fps30))
        #expect(FrameUpconversion.needsInterpolation(rate: 0.5, sourceRate: .fps60, projectRate: .fps30))
    }

    @Test func timeLapseSpeedsShowTheRightFrames() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 10)
        try TimelineOps.setSpeed(id, .constant(50), in: &p.project.timeline)
        #expect(abs(p[id].duration.seconds - 0.2) < 0.001)
        // output 0.1 s → source 5 s = frame 150
        let v = TimeRemapTests.level(try await p.render(at: 0.1))
        #expect(abs(v - TimeRemapTests.expectedLevel(frame: 150)) < 3, "v \(v)")
        try TimelineOps.setSpeed(id, .constant(100), in: &p.project.timeline)
        #expect(abs(p[id].duration.seconds - 0.1) < 0.001)
    }
}

/// Finisher rows: TL-032 / AU-023 scrub audio grains, AU-040 notification sounds, AU-024 device lists.
@Suite struct FinisherAudioTests {
    static func toneProject() async throws -> Project {
        // one file per call: the suite's tests run in parallel, and a shared file could be probed while another test
        // was still writing it (no asset → index out of range crashed the whole test process)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fin-scrub-tone-\(UUID().uuidString).m4a")
        try await SyntheticMedia.writeAudio(to: url, seconds: 3, hz: 440)
        var p = Project()
        let (assets, _) = await MediaProbe.probeAll([url])
        try #require(assets.count == 1)
        p.media = assets
        try TimelineOps.insert(TimelineOps.makeClip(for: assets[0], at: .zero), into: &p)
        return p
    }

    @Test func scrubGrainDecodesAudibleClips() async throws {
        var p = try await Self.toneProject()
        let src = ScrubAudio.sources(in: p, at: Time(1))
        #expect(src.count == 1)
        #expect(abs(src[0].sourceTime.seconds - 1) < 0.001)
        let buf = try #require(await Self.grain(src))
        #expect(buf.frameLength == AVAudioFrameCount(ScrubAudio.grain * 44_100))
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(buf.floatChannelData![0][i])) }
        #expect(peak > 0.05)
        // muted / solo-silenced tracks and gaps give no grain
        let ti = p.timeline.tracks.firstIndex { !$0.clips.isEmpty }!
        p.timeline.tracks[ti].isMuted = true
        #expect(ScrubAudio.sources(in: p, at: Time(1)).isEmpty)
        p.timeline.tracks[ti].isMuted = false
        p.timeline.tracks.append(Track(kind: .audio))
        p.timeline.tracks[p.timeline.tracks.count - 1].isSolo = true
        #expect(ScrubAudio.sources(in: p, at: Time(1)).isEmpty)
        #expect(ScrubAudio.sources(in: try await Self.toneProject(), at: Time(10)).isEmpty)
    }

    @Test func notificationChimesAreValidWav() throws {
        for k in [NotificationSounds.Kind.success, .failure] {
            let d = try #require(NotificationSounds.wav(k))
            #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
            let p = try AVAudioPlayer(data: d)
            #expect(p.duration > 0.3 && p.duration < 0.6)
        }
    }

    /// Blocking AVAssetReader work runs on a GCD thread, not on the test's cooperative thread: many blocking audio
    /// tests at once exhausted the cooperative pool and deadlocked AVFoundation (copyNextSampleBuffer never returned).
    static func grain(_ src: [ScrubAudio.Source]) async -> AVAudioPCMBuffer? {
        await withCheckedContinuation { (c: CheckedContinuation<UncheckedSendable<AVAudioPCMBuffer?>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
                c.resume(returning: UncheckedSendable(ScrubAudio.mix(src, format: fmt)))
            }
        }.value
    }

    static func peak(_ b: AVAudioPCMBuffer) -> Float {
        var m: Float = 0
        for i in 0..<Int(b.frameLength) { m = max(m, abs(b.floatChannelData![0][i])) }
        return m
    }

    /// TL-018: the track volume scales the audio (scrub grains here; the composition/export path bakes the same gain in
    /// `CompoundFlattening.decodeTracks`, unit-tested in Core).
    @Test func trackVolumeScalesTheMix() async throws {
        var p = try await Self.toneProject()
        let full = Self.peak(try #require(await Self.grain(ScrubAudio.sources(in: p, at: Time(1)))))
        let ti = p.timeline.tracks.firstIndex { !$0.clips.isEmpty }!
        p.timeline.tracks[ti].volume = 0.5
        let src = ScrubAudio.sources(in: p, at: Time(1))
        #expect(abs(src[0].gain - 0.5) < 1e-6)
        let half = Self.peak(try #require(await Self.grain(src)))
        #expect(full > 0.05)
        #expect(abs(half / full - 0.5) < 0.05, "full \(full) half \(half)")
    }

    @Test func deviceListsHaveUniqueUIDs() {
        let outs = AudioDevices.outputs()
        #expect(Set(outs.map(\.uid)).count == outs.count)
        #expect(AudioDevices.id(forUID: "no-such-device", in: outs) == nil)
        #expect(AudioDevices.id(forUID: nil, in: outs) == nil)
    }
}

/// SE-018 support package.
@Suite struct FinisherSupportPackageTests {
    @Test func zipHasEnvironmentLogSettingsAndProject() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fin-support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settings)
        let crashes = root.appendingPathComponent("reports")
        try fm.createDirectory(at: crashes, withIntermediateDirectories: true)
        try Data("crash".utf8).write(to: crashes.appendingPathComponent("Montage-2026-10-19.ips"))
        try Data("other".utf8).write(to: crashes.appendingPathComponent("Safari-2026-10-19.ips"))
        var c = SupportPackage.Contents(projectJSON: Data("{\"name\":\"x\"}".utf8), projectName: "x")
        c.settingsURL = settings; c.crashReportsDirectory = crashes
        c.includeLog = false   // `log show` is slow; covered by the UI script
        let cc = c, out = root.appendingPathComponent("out")
        let zip = try await withCheckedThrowingContinuation { (k: CheckedContinuation<URL, Error>) in
            DispatchQueue.global().async { k.resume(with: Result { try SupportPackage.build(cc, into: out, date: Date(timeIntervalSince1970: 0)) }) }
        }
        #expect(zip.pathExtension == "zip" && fm.fileExists(atPath: zip.path))
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-l", zip.path]; p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let list = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for f in ["environment.txt", "settings.json", "project/project.json", "crashes/Montage-2026-10-19.ips"] {
            #expect(list.contains(f), "missing \(f)")
        }
        #expect(!list.contains("Safari"))
    }
}

/// MI-018 FCPXML import (round trip through W11's exporter).
@Suite struct FinisherFCPXMLImportTests {
    @Test func roundTripsMainTrackLanesTitlesAndGaps() throws {
        var p = Project()
        let a = MediaAsset(name: "A", kind: .video, url: URL(fileURLWithPath: "/tmp/fin-a.mov"), duration: Time(20),
                           pixelSize: Size2(1920, 1080), frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "a")
        let m = MediaAsset(name: "M", kind: .audio, url: URL(fileURLWithPath: "/tmp/fin-m.m4a"), duration: Time(30),
                           pixelSize: .zero, frameRate: nil, hasVideo: false, hasAudio: true, contentHash: "m")
        p.media = [a, m]
        p.timeline.mainTrackMagnet = false
        var c1 = Clip(content: .media(a.id), start: 0, duration: 4); c1.sourceStart = 2
        let c2 = Clip(content: .media(a.id), start: 6, duration: 3)
        p.timeline.tracks[p.timeline.mainTrackIndex!].clips = [c1, c2]
        p.timeline.tracks.append(Track(kind: .text, clips: [Clip(content: .text(TextContent(string: "Hello")), start: 1, duration: 2)]))
        p.timeline.tracks.insert(Track(kind: .audio, clips: [Clip(content: .media(m.id), start: 0, duration: 9)]), at: 0)
        let xml = TimelineInterchange.fcpxml(p, name: "RT")
        let seq = try FCPXMLImport.parse(Data(xml.utf8))
        #expect(seq.name == "RT" && seq.frameRate == .fps30)
        #expect(seq.assets.count == 2)
        var media: [String: MediaAsset] = [:]
        for (k, v) in seq.assets { media[k] = v.url.lastPathComponent == "fin-a.mov" ? a : m }
        let tl = FCPXMLImport.timeline(seq, media: media)
        let main = tl.mainTrack!.clips
        #expect(main.count == 2)
        #expect(main.map(\.start) == [Time(0), Time(6)] && main.map(\.duration) == [Time(4), Time(3)])
        #expect(abs(main[0].sourceStart.seconds - 2) < 0.001)
        #expect(tl.tracks.contains { $0.kind == .text && $0.clips.first.map { if case .text(let t) = $0.content { return t.string == "Hello" }; return false } == true })
        let au = try #require(tl.tracks.first { $0.kind == .audio })
        #expect(au.clips.count == 1 && au.clips[0].duration == Time(9))
        #expect(TimelineOps.validate(tl).isEmpty)
        #expect(throws: (any Error).self) { try FCPXMLImport.parse(Data("<xmeml/>".utf8)) }
    }
}

@Suite struct FinisherXMEMLImportTests {
    @Test func readsFCP7XMLTracks() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xmeml><xmeml version="5"><sequence><name>Cut</name>
        <rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate><media>
        <video><format><samplecharacteristics><width>1920</width><height>1080</height></samplecharacteristics></format>
        <track><clipitem id="c1"><name>A</name><start>0</start><end>50</end><in>25</in><out>75</out>
        <file id="f1"><name>A.mov</name><pathurl>file:///tmp/A.mov</pathurl></file></clipitem>
        <clipitem id="c2"><name>A</name><start>75</start><end>100</end><in>0</in><out>25</out><file id="f1"/></clipitem></track>
        <track><clipitem id="c3"><start>10</start><end>20</end><in>0</in><out>10</out><file id="f2"><pathurl>file:///tmp/B.png</pathurl></file></clipitem></track>
        </video><audio><track><clipitem id="a1"><start>0</start><end>100</end><in>0</in><out>100</out><file id="f3"><pathurl>file:///tmp/M.wav</pathurl></file></clipitem></track></audio>
        </media></sequence></xmeml>
        """
        let s = try FCPXMLImport.parse(Data(xml.utf8))
        #expect(s.name == "Cut" && s.frameRate == .fps25 && s.size == Size2(1920, 1080))
        #expect(s.assets.count == 3)
        let v = s.items.filter { $0.lane == 0 }
        #expect(v.map(\.start) == [Time(0), Time(3)] && v.map(\.duration) == [Time(2), Time(1)] && v[0].sourceStart == Time(1))
        #expect(s.items.contains { $0.lane == 1 } && s.items.contains { $0.lane == -1 && $0.duration == Time(4) })
    }
}
