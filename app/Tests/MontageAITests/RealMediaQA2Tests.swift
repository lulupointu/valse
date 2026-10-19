import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Opt-in QA pass, part 2: every video / text / agent AI feature end to end on REAL footage (`MONTAGE_QA_VIDEO`, a
/// person talking; optional `MONTAGE_QA_LONG_VIDEO` for the clipper). Builds a 9:16 project like the owner's, runs the
/// job, applies its edit, renders frames through the real compositor and writes them to `MONTAGE_QA_OUT` (default:
/// a temp folder) so a human can LOOK at them. Prints timings and quality numbers (`QA2 …` lines); asserts only gross
/// failures. Nothing runs without the variable, so `scripts/test.sh` is unaffected.
@Suite(.serialized) struct RealMediaQA2Tests {
    static var video: URL? { RealMediaQATests.video }
    static var longVideo: URL? {
        guard let p = ProcessInfo.processInfo.environment["MONTAGE_QA_LONG_VIDEO"], FileManager.default.fileExists(atPath: p) else { return video }
        return URL(fileURLWithPath: p)
    }
    static var out: URL {
        let d = ProcessInfo.processInfo.environment["MONTAGE_QA_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("montage-qa2")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static let render = CGSize(width: 360, height: 640)

    /// 9:16 1080×1920 project with the QA video on the main track (own cache key namespace: never the user's caches).
    static func project(_ url: URL, canvas: Size2 = Size2(1080, 1920), seconds: Double? = nil) async throws -> (TestProject, ClipID) {
        var p = TestProject(canvas: canvas)
        var a = try await MediaProbe.probe(url)
        a.contentHash = "qa-\(a.contentHash)"
        p.project.media.append(a)
        var clip = TimelineOps.makeClip(for: a, at: .zero)
        if let seconds { clip.duration = Time(min(seconds, a.duration.seconds)) }
        try TimelineOps.insert(clip, into: &p.project, target: .automatic)
        return (p, clip.id)
    }

    static func snap(_ p: TestProject, _ t: Double, _ name: String) async throws {
        let b = try await p.render(at: t, size: render)
        let u = out.appendingPathComponent("\(name).png")
        b.writePNG(u)
        print("QA2 frame \(name) @\(t)s → \(u.path)")
    }

    static func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        try await RealMediaQATests.time(body)
    }

    static func keyframes(_ c: Clip) -> String {
        c.keyframes.map { "\($0.key)=\($0.value.keyframes.count)" }.sorted().joined(separator: " ")
    }

    // MARK: Captions (AI-001 / TX-017, BUG2 layout on 9:16)

    @Test func autoCaptionsOnNineSixteen() async throws {
        guard let v = Self.video, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            var (p, _) = try await Self.project(v)
            let (r, t) = try await Self.time { try await CaptionGenerator.run(project: p.project, options: CaptionOptions(engine: .whisper)) }
            try r.command.apply(to: &p.project)
            let caps = p.project.timeline.allClips.filter { if case .text = $0.content { return true }; return false }
            print("QA2 captions: \(r.count) clips lang=\(r.language) engine=\(r.engine) took=\(t)s")
            for c in caps.prefix(12) {
                if case .text(let tc) = c.content {
                    print(String(format: "QA2 caption %.2f–%.2f size=%.0f “%@”", c.start.seconds, c.end.seconds, tc.fontSize, tc.string))
                }
            }
            #expect(r.count > 0)
            for (i, c) in caps.prefix(3).enumerated() { try await Self.snap(p, (c.start + c.duration * 0.5).seconds, "captions-\(i)") }
            // keyword highlight (AI-004) on the recognised lines
            let lines = caps.compactMap { c -> String? in if case .text(let tc) = c.content { return tc.string }; return nil }
            let (kw, tk) = await Self.time { await KeywordExtractor.keywords(lines, language: r.language) }
            print("QA2 keywords (\(OnDeviceLLM.isAvailable ? "LLM" : "statistical"), \(tk)s): \(kw.sorted())")
        }
    }

    @Test func alignScriptToSpeech() async throws {
        guard let v = Self.video, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            var (p, _) = try await Self.project(v)
            let wav = try await AudioExtractor.wav16k(v, range: nil)
            let tr = try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .whisper))
            let (o, t) = try await Self.time { try await ScriptAligner.run(script: tr.text, project: p.project, language: tr.language) }
            try o.command.apply(to: &p.project)
            print("QA2 align script: \(o.count) captions match=\(o.matchRatio) took=\(t)s")
            #expect(o.matchRatio > 0.6)
        }
    }

    // MARK: Cutout (CK-002/003/004, AI-015/016)

    @Test func personCutout() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 8)
            p.project.settings.backgroundColor = RGBA(0, 0.8, 0)
            let a = p.project.media[0]
            for (mode, name) in [(CutoutMode.person, "person"), (.subject, "subject")] {
                let (_, t) = try await Self.time { try await MatteGenerator.generate(a, mode: mode) }
                print("QA2 cutout \(name): took=\(t)s for \(a.duration.seconds)s media (rtf \(t / a.duration.seconds))")
                p[id].matte = ClipMatte(kind: mode.kind, feather: 0.1, edgeBlend: 0.5)
                try await Self.snap(p, 2, "cutout-\(name)")
                let b = try await p.render(at: 2, size: Self.render)
                // background replaced: some green, but not everything (the person stays)
                var green = 0, n = 0
                for y in stride(from: 0.05, to: 0.95, by: 0.05) { for x in stride(from: 0.05, to: 0.95, by: 0.05) {
                    let c = b[x, y]; n += 1; if c.g > 0.6 && c.r < 0.3 && c.b < 0.3 { green += 1 }
                } }
                print("QA2 cutout \(name): green fraction \(Double(green) / Double(n))")
                #expect(green > 0 && green < n)
            }
        }
    }

    // MARK: Reframe / camera tracking / motion tracking / AI movement (AI-012/013/014/025)

    @Test func reframeTo16x9() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 10)
            let (cmd, t) = try await Self.time { try await AutoReframe.run(project: p.project, clipID: id, options: ReframeOptions(ratio: "1:1")) }
            try cmd.apply(to: &p.project)
            print("QA2 reframe 9:16→1:1: took=\(t)s canvas=\(p.project.settings.canvasSize) keyframes: \(Self.keyframes(p[id]))")
            #expect(p.project.settings.canvasSize.width == p.project.settings.canvasSize.height)
            let sq = CGSize(width: 480, height: 480)
            for s in [1.0, 5.0, 9.0] {
                let b = try await p.render(at: s, size: sq); let u = Self.out.appendingPathComponent("reframe-\(Int(s)).png"); b.writePNG(u)
                print("QA2 frame reframe @\(s) → \(u.path)")
            }
        }
    }

    @Test func cameraTrackingFace() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 10)
            for target in [CameraLockOptions.Target.face, .body] {
                let (cmd, t) = try await Self.time {
                    try await CameraLockJob.run(project: p.project, clipID: id, options: CameraLockOptions(target: target, keepSize: true, zoom: 1.5))
                }
                try cmd.apply(to: &p.project)
                print("QA2 camera tracking \(target): took=\(t)s keyframes: \(Self.keyframes(p[id]))")
                try await Self.snap(p, 3, "cameralock-\(target)")
                var c = p[id]; CameraLock.remove(&c); p[id] = c
            }
        }
    }

    @Test func motionTrackingOnFace() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let (p, id) = try await Self.project(v, seconds: 10)
            let a = p.project.media[0]
            let range = p[id].sourceRange
            let (faces, tf) = try await Self.time { try await FaceTracker.analyze(a, range: range) }
            print("QA2 face tracks: \(faces.count) tracks, samples \(faces.map(\.count)) took=\(tf)s")
            #expect(!faces.isEmpty, "a face is visible")
            guard let first = faces.first?.first else { return }
            let (s, t) = try await Self.time { try await ObjectTracker.track(a, box: first.box, at: first.time, range: range) }
            let span = (s.last?.time ?? 0) - (s.first?.time ?? 0)
            print("QA2 motion tracking face box: \(s.count) samples over \(span)s took=\(t)s first=\(s.first?.box as Any) last=\(s.last?.box as Any)")
            #expect(span > range.duration.seconds * 0.5, "tracked through most of the clip")
        }
    }

    @Test func aiMovement() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 6)
            let (cmd, t) = try await Self.time { try await AIMovementJob.run(project: p.project, clipID: id, options: AIMovementOptions(preset: .dynamic)) }
            try cmd.apply(to: &p.project)
            print("QA2 AI movement dynamic: took=\(t)s keyframes: \(Self.keyframes(p[id]))")
            #expect(!p[id].keyframes.isEmpty)
            try await Self.snap(p, 1.5, "movement")
        }
    }

    // MARK: Face cover (AI-051 / ST-006)

    @Test func faceMosaic() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 6)
            let (_, t) = try await Self.time { try await MatteGenerator.generate(p.project.media[0], mode: .faces) }
            try FaceCover.apply(.mosaic, to: id, in: &p.project)
            print("QA2 face mosaic: faces matte took=\(t)s")
            try await Self.snap(p, 2, "face-mosaic")
        }
    }

    // MARK: Relight (AI-024 / CL-020), AI remove (AI-041), colour (CL-007/008), enhance (CL-019)

    @Test func relight() async throws {
        guard let v = Self.video, RelightDepth.hasModel else { print("skip: MONTAGE_QA_VIDEO / depth model"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 6)
            let s = RelightSettings.preset(.facial)
            let (_, t) = try await Self.time { try await RelightJob.run(p.project.media[0], settings: s) }
            print("QA2 relight facial (target \(s.target)): depth+matte took=\(t)s for \(p.project.media[0].duration.seconds)s media")
            try await Self.snap(p, 2, "relight-before")
            p[id].relight = s
            try await Self.snap(p, 2, "relight-facial")
        }
    }

    @Test func aiRemoveStill() async throws {
        guard let v = Self.video, LaMaInpainter.isAvailable else { print("skip: MONTAGE_QA_VIDEO / LaMa"); return }
        try await HeavyWorkGate.run {
            // a still frame of the footage (AI remove on images), stroke over the upper-left quarter
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: v)); g.appliesPreferredTrackTransform = true
            let img = try await g.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
            let png = Self.out.appendingPathComponent("remove-input.png")
            Bitmap(img).writePNG(png)
            var a = try await MediaProbe.probe(png); a.contentHash = "qa-\(a.contentHash)"
            let stroke = RemovalStroke(points: [Vec2(0.15, 0.2), Vec2(0.35, 0.25)], radius: 0.06)
            let (u, t) = try await Self.time { try await ObjectRemover.process(a, strokes: [stroke]) }
            print("QA2 AI remove (still \(img.width)×\(img.height)): took=\(t)s → \(u.path)")
            try? FileManager.default.removeItem(at: Self.out.appendingPathComponent("remove-output.png"))
            try FileManager.default.copyItem(at: u, to: Self.out.appendingPathComponent("remove-output.png"))
        }
    }

    @Test func aiRemoveVideo() async throws {
        guard let v = Self.video, LaMaInpainter.isAvailable else { print("skip: MONTAGE_QA_VIDEO / LaMa"); return }
        try await HeavyWorkGate.run {
            let (p, _) = try await Self.project(v)
            let a = p.project.media[0]
            let stroke = RemovalStroke(points: [Vec2(0.1, 0.1), Vec2(0.2, 0.12)], radius: 0.04)
            do {
                let (u, t) = try await Self.time { try await ObjectRemover.process(a, strokes: [stroke]) }
                print("QA2 AI remove video \(a.duration.seconds)s: took=\(t)s rtf=\(t / a.duration.seconds) → \(u.path)")
            } catch {
                print("QA2 AI remove video \(a.duration.seconds)s: error \(error)")
            }
        }
    }

    @Test func autoColor() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 6)
            try await Self.snap(p, 2, "color-before")
            for kind in [ColorLooks.Kind.auto, .correct] {
                let (cmd, t) = try await Self.time { try await ColorLooks.autoAdjust(project: p.project, clipID: id, kind: kind) }
                var q = p; try cmd.apply(to: &q.project)
                print("QA2 colour \(kind): took=\(t)s effects=\(q[id].effects.map(\.typeID))")
                try await Self.snap(q, 2, "color-\(kind)")
            }
        }
    }

    /// The owner's project is HDR (HLG): the same looks must not tint it (wall ≈ neutral like the SDR render).
    @Test func autoColorInHLGProject() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            var (p, id) = try await Self.project(v, seconds: 6)
            p.project.settings.colorSpace = .hdrHLG
            func wall(_ q: TestProject) async throws -> RGBA { try await q.render(at: 2, size: Self.render).average(x: 0.1, y: 0.05, w: 0.8, h: 0.2) }
            let before = try await wall(p)
            try await Self.snap(p, 2, "hlg-color-before")
            for kind in [ColorLooks.Kind.auto, .correct] {
                let cmd = try await ColorLooks.autoAdjust(project: p.project, clipID: id, kind: kind)
                var q = p; try cmd.apply(to: &q.project)
                let w = try await wall(q)
                print(String(format: "QA2 HLG colour %@: wall before %.3f %.3f %.3f after %.3f %.3f %.3f", kind.rawValue, before.r, before.g, before.b, w.r, w.g, w.b))
                try await Self.snap(q, 2, "hlg-color-\(kind)")
            }
        }
    }

    @Test func smartSearch() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let (p, _) = try await Self.project(v)
            let a = p.project.media[0]
            let (_, t) = try await Self.time { try await MediaIndex.shared.index(a) }
            let e = MediaIndex.shared.entry(a)
            print("QA2 media index: took=\(t)s labels=\(e.map { String(describing: $0).prefix(400) } ?? "nil")")
            for q in ["person", "personne", "femme", "voiture", "indoor"] {
                print("QA2 search “\(q)” score=\(MediaIndex.shared.score(a, query: q))")
            }
        }
    }

    // MARK: Language model features (AI-029 / AI-048 / AI-031)

    @Test func aiWriter() async throws {
        guard OnDeviceLLM.isAvailable, Self.video != nil else { print("skip: LLM / MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let (s, t) = try await Self.time {
                try await AIWriter.write(topic: "Une série Instagram sur une relation toxique", requirements: "ton sérieux, 4 phrases",
                                         kind: AIWriter.Kind.allCases[0], language: "fr")
            }
            print("QA2 AI writer fr (\(t)s): \(s)")
            #expect(!s.isEmpty)
            let (l, t2) = try await Self.time { try await AIWriter.revise(s, .shorter, language: "fr") }
            print("QA2 AI writer shorter (\(t2)s): \(l)")
        }
    }

    @Test func editPilotPlansOnRealProject() async throws {
        guard let v = Self.video, OnDeviceLLM.isAvailable else { print("skip: MONTAGE_QA_VIDEO / LLM"); return }
        try await HeavyWorkGate.run {
            let (p, _) = try await Self.project(v)
            for req in ["Ajoute des sous-titres et mets en valeur les mots clés", "Remove the silences and add a fade out at the end",
                        "Rends la vidéo carrée pour Instagram"] {
                let (plan, t) = await Self.time { await EditPilotPlanner.plan(req, project: p.project, selection: []) }
                print("QA2 EditPilot “\(req)” (\(plan.engine), \(t)s): \(plan.actions.map { String(describing: $0).prefix(80) })")
                #expect(!plan.actions.isEmpty)
            }
        }
    }

    @Test func clipperOnLongVideo() async throws {
        guard let v = Self.longVideo, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            var a = try await MediaProbe.probe(v); a.contentHash = "qa-\(a.contentHash)"
            let (h, t) = try await Self.time { try await AIClipper.highlights(a, options: .init()) }
            print("QA2 AI clipper on \(a.duration.seconds)s (LLM=\(OnDeviceLLM.isAvailable)): \(h.count) highlights in \(t)s: \(h.map { String(describing: $0).prefix(120) })")
        }
    }

    // MARK: Audio clean-up through the export mix (AU-007/008/009, AI-009/010/011)

    /// Noise floor (10th percentile) and speech level (90th percentile) of 50 ms RMS frames, dBFS.
    static func levels(_ url: URL) throws -> (floor: Double, speech: Double) {
        let x = try VoiceIsolationTests.readMono(url, seconds: 600)
        let n = 2400   // 50 ms at 48 kHz
        var r: [Double] = []
        var i = 0
        while i + n <= x.count {
            var s = 0.0; for j in i..<(i + n) { s += Double(x[j] * x[j]) }
            r.append(10 * log10(max(s / Double(n), 1e-12))); i += n
        }
        r.sort()
        guard !r.isEmpty else { return (-120, -120) }
        return (r[r.count / 10], r[r.count * 9 / 10])
    }

    @Test func audioCleanupInTheMix() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            AIEngineHooks.installAudioML(force: true)
            let (p, id) = try await Self.project(v, seconds: 15)
            let cases: [(String, (inout Clip) -> Void)] = [
                ("original", { _ in }),
                ("reduceNoise", { $0.audio.noiseReduction = 0.6 }),
                ("enhanceVoice", { $0.audio.enhanceVoice = 0.7 }),
                ("isolateVoice", { $0.audio.separation = .keepVocals }),
            ]
            for (name, edit) in cases {
                var q = p; var c = q[id]; edit(&c); q[id] = c
                let u = Self.out.appendingPathComponent("audio-\(name).wav")
                try? FileManager.default.removeItem(at: u)
                let (_, t) = try await Self.time { try await AudioExporter.export(project: q.project, settings: .init(format: .wav16), to: u) }
                let l = try Self.levels(u)
                print(String(format: "QA2 audio %@: floor %.1f dBFS speech %.1f dBFS (SNR %.1f dB) export %.1fs → %@", name, l.floor, l.speech,
                             l.speech - l.floor, t, u.path))
            }
        }
    }

    @Test func shortsFromLongVideo() async throws {
        guard let v = Self.longVideo, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_LONG_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            var a = try await MediaProbe.probe(v); a.contentHash = "qa-\(a.contentHash)"
            do {
                let (projects, t) = try await Self.time { try await LongToShorts.run(a, options: .init()) }
                print("QA2 shorts on \(a.duration.seconds)s: \(projects.count) projects in \(t)s (LLM=\(OnDeviceLLM.isAvailable))")
                for p in projects {
                    print("QA2 short \(p.name): \(String(format: "%.1f", p.timeline.duration.seconds))s \(p.settings.aspectPreset) clips=\(p.timeline.allClips.count)")
                }
            } catch { print("QA2 shorts on \(a.duration.seconds)s: error \(error)") }
        }
    }

    // MARK: Stabilize / slow-mo (AI-059, AI-018)

    @Test func stabilizeAnalysis() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let (path, t) = try await Self.time { try await StabilizationStore.analyze(v) }
            let amp = (path.x.map(abs).max() ?? 0, path.y.map(abs).max() ?? 0)
            print("QA2 stabilize analysis: took=\(t)s samples=\(path.x.count) max|x|,|y|=\(amp)")
            #expect(!path.x.isEmpty)
        }
    }

    @Test func smoothSlowMo() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            AIEngineHooks.install()
            var (p, id) = try await Self.project(v, seconds: 4)
            p[id].speed = .constant(0.25)
            p[id].duration = Time(4)
            p[id].smoothSlowMo = .opticalFlow
            AIEngineHooks.prepareOpticalFlow(width: 1080, height: 1920, wait: true)
            print("QA2 slow-mo: optical flow provider=\(AIEngineHooks.hasOpticalFlow)")
            let (_, t) = try await Self.time { try await Self.snap(p, 1.03, "slowmo") }
            print("QA2 slow-mo frame took=\(t)s")
        }
    }
}
