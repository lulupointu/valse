import Testing
import Foundation
import MontageCore
@testable import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// W8 audio UI: localization of dynamic keys, inspector registration, store flows (voice changer, beats, recording).
@MainActor @Suite(.serialized) struct AudioUITests {
    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<600 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func dynamicAudioKeysAreLocalized() {
        MontageBootstrap.registerResources()
        var keys: [String] = VoiceEffects.all.map(\.nameKey) + VoiceEffects.all.flatMap { $0.params.map(\.nameKey) }
        keys += VoiceCategory.allCases.map(\.nameKey) + ChannelMode.allCases.map(\.nameKey) + VocalSeparation.allCases.map(\.nameKey)
        keys += SoundEffects.all.map(\.nameKey) + SoundEffects.categories.map { "sfx.category.\($0)" }
        keys += LoudnessNormalization.targets.map { "audio.loudness.target.\(Int(-$0))" }
        keys += EQEditor.presets.map { "audio.eq.\($0.id)" }
        keys += AudioInspector.sections.compactMap(\.titleKey) + AudioInspector.tabs.map(\.titleKey) + [AudioInspector.voiceSubTab.titleKey]
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    @Test func audioTabsShowVoiceChanger() async throws {
        var p = TestProject()
        let a = try await p.addAudio(seconds: 1)
        let v = try await p.addVideo(.solid(.red), seconds: 1, audioHz: 440)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [a]
        let audioTabs = InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id)
        #expect(audioTabs.contains("audioBasic") && audioTabs.contains("audioVoice"))
        #expect(audioTabs.firstIndex(of: "audioVoice")! < audioTabs.firstIndex(of: "speed")!)
        s.selection = [v]
        let ctx = InspectorContext(store: s)
        let tab = try #require(InspectorRegistry.tabs(for: ctx).first { $0.id == "audio" })
        #expect(InspectorRegistry.subTabs(of: tab, ctx: ctx).map(\.id) == ["basic", "voice"])
    }

    @Test func voiceChangerAppliesAndUndoes() async throws {
        var p = TestProject()
        let a = try await p.addAudio(seconds: 1)
        let b = try await p.addAudio(seconds: 1, hz: 220, target: .newTrack)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [a]
        s.applyVoice(VoiceEffects.descriptor("montage.voice.robot")!.makeEffect(), toAll: false)
        #expect(s.project.timeline.clip(a)?.audio.voice?.typeID == "montage.voice.robot")
        #expect(s.project.timeline.clip(b)?.audio.voice == nil)
        s.applyVoice(VoiceEffects.descriptor("montage.voice.echo")!.makeEffect(), toAll: true)
        #expect(s.project.timeline.clip(b)?.audio.voice?.typeID == "montage.voice.echo")
        s.undo()
        #expect(s.project.timeline.clip(b)?.audio.voice == nil)
        #expect(s.project.timeline.clip(a)?.audio.voice?.typeID == "montage.voice.robot")
    }

    @Test func autoBeatsWritesClipBeats() async throws {
        // 120 BPM clicks
        let click = AudioBuffer(seconds: 6, channels: 2) { _, t in
            let d = (t - 0.25).truncatingRemainder(dividingBy: 0.5)
            return t >= 0.25 && d < 0.02 ? Float(0.6 * sin(2 * .pi * 2000 * t) * exp(-d * 200)) : 0
        }
        var p = TestProject()
        let a = try await p.addAudio(click)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [a]
        s.autoBeats(level: 2)
        await waitUntil { s.project.timeline.clip(a)?.beats != nil }
        let beats = try #require(s.project.timeline.clip(a)?.beats)
        #expect(beats.count >= 9, "\(beats.count) beats")
        let inner = beats.filter { $0.seconds > 1 && $0.seconds < 5 }
        #expect(inner.allSatisfy { b in abs((b.seconds - 0.25).remainder(dividingBy: 0.5)) < 0.03 })
        s.autoBeats(level: nil)
        #expect(s.project.timeline.clip(a)?.beats == nil)
    }

    @Test func recordingIsInsertedAtStartOnAudioTrack() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.blue), seconds: 3)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        let url = TestMedia.directory.appendingPathComponent("rec-\(UUID().uuidString).caf")
        try AudioFileIO.write(AudioTestSignals.sine(300, seconds: 1), to: url, format: .wav16)
        s.insertRecording(url, at: Time(1))
        await waitUntil { s.project.timeline.tracks.contains { $0.kind == .audio } }
        let track = try #require(s.project.timeline.tracks.first { $0.kind == .audio })
        #expect(track.clips.count == 1 && track.clips[0].start == Time(1))
        #expect(abs(track.clips[0].duration.seconds - 1) < 0.02)
    }

    @Test func extractAudioFromVideoFile() async throws {
        let video = try await TestMedia.video(.solid(.red), seconds: 1, audioHz: 440)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString) (audio).m4a")
        try await AudioExtractor.extract(from: video, to: dst)
        let b = try await AudioFileIO.read(dst)
        #expect(abs(Double(b.frames) / 48000 - 1) < 0.05)
        #expect(abs(AudioTestSignals.dominantFrequency(b, lo: 300, hi: 600, from: 0.2, to: 0.8) - 440) < 3)
    }

    @Test func soundEffectsSynthesize() throws {
        for d in SoundEffects.all {
            let u = try SoundEffects.file(d)
            #expect(FileManager.default.fileExists(atPath: u.path), "\(d.id)")
        }
    }
}
