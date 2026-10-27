import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine

/// BUG-CAPTION-ERRORS: every speech failure reason maps to a translated title / body and the right fixes; engine
/// errors are classified instead of collapsing into "try again"; jobs keep the real error.
@Suite struct SpeechFailureTests {
    let en = L10n(bundles: [AIResources.bundle], language: "en")
    let fr = L10n(bundles: [AIResources.bundle], language: "fr")

    @Test func everyMessageAndRemedyKeyIsTranslated() {
        let enKeys = en.keys(for: "en"), frKeys = fr.keys(for: "fr")
        let missing = SpeechFailure.allKeys.filter { !enKeys.contains($0) || !frKeys.contains($0) }
        #expect(missing.isEmpty, "missing: \(missing)")
        // every sample's lines resolve (no raw key shown) in both languages
        for f in SpeechFailure.samples {
            for repeated in [false, true] {
                let m = f.message(uiLanguage: "fr", repeated: repeated)
                for line in [m.title, m.body, m.toast] {
                    #expect(enKeys.contains(line.key) && frKeys.contains(line.key), "\(f) → \(line.key)")
                    #expect(!line.text(fr).contains("%@"), "\(line.key) has unfilled arguments")
                }
            }
            for r in f.remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true) {
                #expect(enKeys.contains(r.title.key) && frKeys.contains(r.title.key), "\(r.name)")
            }
        }
    }

    /// The owner's rule: no internal names in user text, vous in French, no "try again" where a retry can't help.
    @Test func userTextHasNoJargon() {
        let banned = ["whisper.cpp", "whisper-cli", "runtime", "moteur", "SFSpeech", "SpeechAnalyzer", "scripts/", "exit", "domain"]
        for (lang, l) in [("en", en), ("fr", fr)] {
            for key in SpeechFailure.allKeys {
                let v = l.string(key, ["X", "X"]).lowercased()
                for b in banned { #expect(!v.contains(b.lowercased()), "\(lang) \(key): \(b)") }
                if lang == "fr" { #expect(!v.contains(" tu ") && !v.contains("réessaie"), "\(key) uses tu") }
            }
        }
        // retry is only offered for the unknown case
        let retrying = SpeechFailure.samples.filter { f in
            f.remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true).contains(.retry)
        }
        #expect(retrying.map(\.name) == ["other"])
    }

    @Test func messagesForTheIntelCase() {
        // Intel MacBook Pro, macOS 13, French: Apple can't, the speech model can
        let f = SpeechFailure.languageUnavailable(language: "fr", canAddDictation: false)
        let m = f.message(uiLanguage: "fr")
        #expect(m.title.text(fr) == "Ce Mac ne peut pas reconnaître seul la parole en français")
        #expect(m.body.text(fr).hasPrefix("Téléchargez le modèle vocal de Valse ("))
        #expect(f.message(uiLanguage: "en").title.text(en) == "This Mac can't recognize speech in French on its own")
        #expect(f.remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true) == [.downloadSpeechModel])
        // when dictation can add the language, it is the second way
        let d = SpeechFailure.languageUnavailable(language: "fr", canAddDictation: true)
        #expect(d.remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true) == [.downloadSpeechModel, .openSettings(.dictation)])
        // without the helper the download can't help: update Valse
        #expect(f.resolved(helperPresent: false) == .appIncomplete)
        #expect(d.resolved(helperPresent: false) == d)
        #expect(SpeechFailure.appIncomplete.remedies(helperPresent: false, modelInstalled: false, updatesAvailable: true) == [.checkForUpdates])
        #expect(SpeechFailure.appIncomplete.remedies(helperPresent: false, modelInstalled: false, updatesAvailable: false).isEmpty)
    }

    @Test func remediesPerReason() {
        func r(_ f: SpeechFailure, helper: Bool = true, model: Bool = false) -> [String] {
            f.remedies(helperPresent: helper, modelInstalled: model, updatesAvailable: true).map(\.name)
        }
        let id = MediaID()
        #expect(r(.nothingToCaption(trackChosen: true)) == ["allTracks"])
        #expect(r(.nothingToCaption(trackChosen: false)).isEmpty)
        #expect(SpeechFailure.mediaOffline(name: "a", media: id).remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true) == [.relink(id)])
        #expect(r(.noSoundInFile(name: "a")).isEmpty)
        #expect(r(.noSpeech(language: nil)).isEmpty)
        #expect(r(.noSpeech(language: "fr")) == ["detectLanguage"])
        #expect(r(.permissionDenied) == ["settings.speechRecognition", "useSpeechModel"])
        #expect(r(.permissionDenied, helper: false) == ["settings.speechRecognition"])
        #expect(r(.permissionDenied, model: true) == ["settings.speechRecognition"])
        #expect(r(.permissionRestricted) == ["download"])
        #expect(r(.speechModelNeeded) == ["download", "useAutomatic"])
        #expect(r(.speechModelDamaged) == ["redownload"])
        #expect(r(.notEnoughMemory) == ["lighterModel"])
        #expect(r(.diskFull) == ["settings.storage"])
        #expect(r(.other(detail: "x")) == ["retry"])
        #expect(SpeechFailure.other(detail: "x").remedies(helperPresent: true, modelInstalled: false, updatesAvailable: true, repeated: true) == [.copyDetails])
        #expect(SpeechFailure.other(detail: "x").message(repeated: true).body.key == "captions.failure.other.repeated.body")
    }

    @Test func noSpeechNamesTheForcedLanguage() {
        let m = SpeechFailure.noSpeech(language: "en").message(uiLanguage: "fr")
        #expect(m.body.text(fr).contains("en anglais"))
        #expect(SpeechFailure.noSpeech(language: "fr").message(uiLanguage: "en").body.text(en).contains("in French"))
        #expect(SpeechFailure.noSpeech(language: nil).message().body.key == "captions.failure.noSpeech.body")
    }

    @Test func mostActionableOrder() {
        let all: [SpeechFailure] = [.other(detail: "x"), .appIncomplete, .languageUnavailable(language: "fr", canAddDictation: false),
                                    .permissionDenied]
        // permission is the cheap fix when Whisper can't run
        #expect(SpeechFailure.mostActionable(all) == .permissionDenied)
        // when Whisper could run, the download / language reason comes first
        #expect(SpeechFailure.mostActionable(all, whisperUsable: true) == .languageUnavailable(language: "fr", canAddDictation: false))
        // input problems beat every engine problem; disk before permissions
        #expect(SpeechFailure.mostActionable(all + [.noSpeech(language: nil)]) == .noSpeech(language: nil))
        #expect(SpeechFailure.mostActionable(all + [.diskFull]) == .diskFull)
        #expect(SpeechFailure.mostActionable([.other(detail: "a"), .notEnoughMemory]) == .notEnoughMemory)
        #expect(SpeechFailure.mostActionable([]) == .other(detail: "no engine"))
    }

    @Test func classifiesEngineErrors() {
        #expect(SpeechFailure.classify(NSError(domain: "kAFAssistantErrorDomain", code: 1110), language: "fr") == .noSpeech(language: "fr"))
        #expect(SpeechFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskFull)
        #expect(SpeechFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskFull)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(SpeechFailure.classify(wrapped) == .diskFull)
        #expect(SpeechFailure.classify(AIToolError.noSpeech) == .noSpeech(language: nil))
        #expect(SpeechFailure.classify(SpeechFailure.permissionDenied) == .permissionDenied)
        if case .other = SpeechFailure.classify(NSError(domain: "x", code: 1)) {} else { Issue.record("unknown → other") }
    }

    @Test func classifiesWhisperHelperFailures() {
        #expect(WhisperEngine.classifyExit(status: SIGKILL, signal: true, stderr: "") == .notEnoughMemory)
        #expect(WhisperEngine.classifyExit(status: SIGILL, signal: true, stderr: "") == .appIncomplete)
        #expect(WhisperEngine.classifyExit(status: 1, signal: false, stderr: "whisper_init_from_file: failed to load model") == .speechModelDamaged)
        #expect(WhisperEngine.classifyExit(status: 1, signal: false, stderr: "bad CPU type in executable") == .appIncomplete)
        if case .other = WhisperEngine.classifyExit(status: 3, signal: false, stderr: "boom") {} else { Issue.record("unknown exit → other") }
        // can't launch (wrong architecture, not executable, missing): only an update helps
        #expect(WhisperEngine.classifyLaunch(NSError(domain: NSPOSIXErrorDomain, code: Int(EBADARCH))) == .appIncomplete)
        #expect(WhisperEngine.classifyLaunch(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)) == .appIncomplete)
    }

    @Test func whisperForcedWithoutModelOrHelper() async {
        let r = Transcriber.Request(language: "fr", engine: .whisper)
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("unused.wav")
        if WhisperRuntime.cliURL == nil {
            await #expect(throws: SpeechFailure.appIncomplete) { _ = try await Transcriber.recognize(wav: wav, request: r) }
        } else if ModelCatalog.preferredWhisperModel == nil {
            await #expect(throws: SpeechFailure.speechModelNeeded) { _ = try await Transcriber.recognize(wav: wav, request: r) }
        }
    }

    @Test func readinessHonoursTestOverride() async {
        SpeechTestHooks.forcedReadiness = .blocked(.permissionDenied)
        defer { SpeechTestHooks.forcedReadiness = nil }
        #expect(await Transcriber.readiness(language: nil, engine: .automatic, uiLanguage: "fr") == .blocked(.permissionDenied))
    }

    @Test func parsesTestHookSpecs() {
        #expect(SpeechFailure.parse("languageUnavailable:de") == .languageUnavailable(language: "de", canAddDictation: false))
        #expect(SpeechFailure.parse("noSpeech:fr") == .noSpeech(language: "fr"))
        #expect(SpeechFailure.parse("nothingToCaption:track") == .nothingToCaption(trackChosen: true))
        #expect(SpeechFailure.parse("bogus") == nil)
        #expect(SpeechTestHooks.parseReadiness("needsPermission") == .needsPermissionPrompt)
        #expect(SpeechTestHooks.parseReadiness("diskFull") == .blocked(.diskFull))
    }

    /// JobQueue keeps the thrown error (no more string matching on its description).
    @Test func jobQueueCarriesTheTypedError() async {
        let q = JobQueue(maxConcurrent: 1)
        let id = await q.enqueue(titleKey: "t") { _ in throw SpeechFailure.permissionDenied }
        let (state, error) = await q.waitResult(id)
        if case .failed = state {} else { Issue.record("expected failed, got \(state)") }
        #expect(error as? SpeechFailure == .permissionDenied)
        let ok = await q.enqueue(titleKey: "t") { _ in }
        let done = await q.waitResult(ok)
        #expect(done.state == .done && done.error == nil)
    }
}
