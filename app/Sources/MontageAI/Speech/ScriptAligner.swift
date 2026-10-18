import Foundation
import MontageCore

/// TX-030 job: recognizes the speech of the project's audible clips (cached transcripts, whisper.cpp → Apple speech)
/// and aligns a script to it → one undoable edit adding a caption track with the script's text and the speech timing.
public enum ScriptAligner {
    public struct Output: Sendable {
        public let command: any EditCommand
        public let count: Int
        public let matchRatio: Double
    }

    public enum Failure: Error, Sendable { case noSpeech, mismatch }

    public static func run(script: String, project p: Project, language: String?,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> Output {
        let clips = CaptionGenerator.sourceClips(p, .allTracks)
        guard !clips.isEmpty else { throw AIToolError.noInput }
        let transcripts = try await PilotTranscripts.load(p, language: language) { progress?(0.95 * $0) }
        let heard = ScriptAlignment.heardWords(transcripts: transcripts, clips: clips)
        guard !heard.isEmpty else { throw Failure.noSpeech }
        let lang = language ?? transcripts.values.first { !$0.language.isEmpty }?.language ?? L10n.shared.language
        let (segs, ratio) = ScriptAlignment.segments(script: script, heard: heard, language: lang)
        guard !segs.isEmpty, ratio >= 0.25 else { throw Failure.mismatch }
        progress?(1)
        let cmd = Edit("cmd.alignScript") { p in
            guard CaptionOps.addCaptionTrack(segs, to: &p, origin: .script) != nil else { throw EditError.nothingToDo }
        }
        return Output(command: cmd, count: segs.count, matchRatio: ratio)
    }
}
