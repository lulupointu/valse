import Testing
import Foundation
@testable import MontageCore

/// AU-030 / AI-006: TTS emotion / style presets (prosody → SSML, clip post-processing, persistence).
@Suite struct TTSStyleTests {
    @Test func neutralIsIdentity() {
        let p = TTSStyle.neutral.prosody
        #expect(p == TTSProsody())
        var a = AudioProps()
        p.apply(to: &a)
        #expect(a == AudioProps())
    }

    @Test func ssmlSplitsSentencesWithPausesAndProsody() {
        let s = TTSStyle.calm.prosody.ssml("Bonjour à tous. Voici la suite. Fin")
        #expect(s.hasPrefix("<speak>") && s.hasSuffix("</speak>"))
        #expect(s.components(separatedBy: "<prosody ").count - 1 == 3)
        // a pause between sentences, none after the last
        #expect(s.components(separatedBy: "<break time=\"450ms\"/>").count - 1 == 2)
        #expect(!s.hasSuffix("<break time=\"450ms\"/></speak>"))
        // calm: 0.85 rate, 0.92 pitch
        #expect(s.contains("rate=\"85%\" pitch=\"-8%\""))
    }

    @Test func styleStacksOnUserSpeedAndPitchAndClamps() {
        let s = TTSStyle.excited.prosody.ssml("Go.", rate: 2, pitch: 1.2)
        #expect(s.contains("rate=\"200%\""))   // 2 × 1.2 clamped to 2
        #expect(s.contains("pitch=\"+50%\""))  // 1.2 × 1.25
        let low = TTSStyle.calm.prosody.ssml("Go.", rate: 0.5, pitch: 0.5)
        #expect(low.contains("rate=\"50%\" pitch=\"-50%\""))
    }

    @Test func exclamationsGetAPitchLift() {
        let s = TTSStyle.cheerful.prosody.ssml("C'est parti ! On commence.")
        // 1.15 × 1.08 = 1.242 on the exclamation, 1.15 elsewhere
        #expect(s.contains("pitch=\"+24%\">C&apos;est parti !</prosody>"))
        #expect(s.contains("pitch=\"+15%\">On commence.</prosody>"))
        #expect(TTSProsody.isExclamation("« Super ! »"))
        #expect(!TTSProsody.isExclamation("Vraiment ?"))
    }

    @Test func ssmlEscapesMarkup() {
        let s = TTSStyle.serious.prosody.ssml("Tom & Jerry <b>\"live\"</b>")
        #expect(s.contains("Tom &amp; Jerry &lt;b&gt;&quot;live&quot;&lt;/b&gt;"))
        #expect(!s.contains("<b>"))
    }

    @Test func everyStyleHasAValidAudioChainRecipe() {
        for st in TTSStyle.allCases {
            let p = st.prosody
            if let eq = p.eq {
                #expect(eq.count == AudioEQ.frequencies.count)
                #expect(eq.allSatisfy { AudioEQ.gainRange.contains($0) })
            }
            #expect(TTSProsody.rateRange.contains(p.rate) && TTSProsody.pitchRange.contains(p.pitch))
            #expect(p.gainDB <= 0)   // never boost synthetic speech that already peaks near full scale
        }
        var a = AudioProps()
        TTSStyle.calm.prosody.apply(to: &a)
        #expect(abs(AudioProps.decibels(a.volume) - -2) < 0.01)
        #expect(a.eq?.gains == TTSStyle.calm.prosody.eq)
    }

    @Test func placedSpeechCarriesStyleAndPostProcessing() throws {
        var (project, _) = Fx.project(mainClips: 1)
        var tl = project.timeline
        let tid = TimelineOps.addTrack(.text, to: &tl)
        let text = Clip(content: .text(TextContent(string: "Bonjour.")), start: Time(1), duration: Time(2))
        tl.tracks[tl.trackIndex(tid)!].clips.append(text)
        project.timeline = tl
        let asset = Fx.audio("tts", seconds: 1.5)
        let id = try TTSOps.placeSpeech(asset, info: TTSInfo(sourceText: text.id, voice: "v", text: "Bonjour.", style: .serious), in: &project)
        let speech = try #require(project.timeline.clip(id))
        #expect(speech.tts?.style == .serious)
        #expect(speech.audio.eq?.gains == TTSStyle.serious.prosody.eq)
        // regenerating as neutral resets the post-processing (new clip, no EQ left over)
        let id2 = try TTSOps.placeSpeech(asset, info: TTSInfo(sourceText: text.id, voice: "v", text: "Bonjour."), in: &project)
        let speech2 = try #require(project.timeline.clip(id2))
        #expect(speech2.audio.eq == nil && speech2.audio.volume == 1 && speech2.tts?.style == .neutral)
    }

    @Test func persistenceRoundTripAndOldFiles() throws {
        let info = TTSInfo(sourceText: ClipID(), voice: "com.apple.voice.compact.fr-FR.Thomas", rate: 1.2, pitch: 0.9, text: "Salut",
                           autoUpdate: false, style: .excited)
        let data = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(TTSInfo.self, from: data) == info)
        // a W10 file (no style key) decodes as neutral; an unknown style too
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "style")
        let old = try JSONDecoder().decode(TTSInfo.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(old.style == .neutral && old.rate == 1.2 && old.autoUpdate == false)
        obj["style"] = "whispering"
        #expect(try JSONDecoder().decode(TTSInfo.self, from: try JSONSerialization.data(withJSONObject: obj)).style == .neutral)
    }
}
