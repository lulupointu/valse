import Foundation
import ValseCore
import ValseEffects
import ValseEngine

/// Where an AI tool appears / what it needs.
public enum AIToolTarget: String, Sendable {
    /// Needs a selected video clip (inspector "AI tools", e.g. Remove background).
    case videoClip
    /// Needs a selected clip with audio (Enhance voice, Captions from clip).
    case audioClip
    /// Works on the whole project (Auto captions).
    case project
}

public struct AIToolInput: Sendable {
    public let project: Project
    public let clipID: ClipID?
    public let language: String
    public init(project: Project, clipID: ClipID?, language: String) {
        self.project = project; self.clipID = clipID; self.language = language
    }
    public var clip: Clip? { clipID.flatMap { project.timeline.clip($0) } }
    public var asset: MediaAsset? { clip?.mediaID.flatMap { project.asset($0) } }
}

public enum AIToolOutput: Sendable {
    /// Undoable edit applied when the job finishes (on the then-current project).
    case edit(any EditCommand)
    /// File produced in the cache (e.g. matte video), no project change.
    case artifact(URL)
    case none
}

public enum AIToolError: Error, Sendable {
    case unavailable(String)
    case noInput
    /// "Couldn't add captions. No speech in your video."
    case noSpeech
    /// A required model isn't downloaded yet (model id).
    case modelMissing(String)
    public var messageKey: String {
        switch self {
        case .unavailable: return "ai.error.unavailable"
        case .noInput: return "ai.error.noInput"
        case .noSpeech: return "ai.error.noSpeech"
        case .modelMissing: return "ai.error.modelMissing"
        }
    }
}

/// One AI feature. Runs as a background job (ValseEngine.JobQueue) with progress and cancel; heavy models are
/// loaded on demand inside `run` and released after (one heavy model resident at a time on 8 GB machines).
/// To add one: write a `static let` descriptor (see BuiltinAITools) and append it to `AIRegistry.builtins`.
public struct AIToolDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let descriptionKey: String
    public let symbol: String
    public let target: AIToolTarget
    public let isAvailable: @Sendable () async -> Bool
    public let run: @Sendable (AIToolInput, JobProgress) async throws -> AIToolOutput

    public init(id: String, nameKey: String, descriptionKey: String, symbol: String, target: AIToolTarget,
                isAvailable: @escaping @Sendable () async -> Bool = { true },
                run: @escaping @Sendable (AIToolInput, JobProgress) async throws -> AIToolOutput) {
        self.id = id; self.nameKey = nameKey; self.descriptionKey = descriptionKey; self.symbol = symbol
        self.target = target; self.isAvailable = isAvailable; self.run = run
    }
}

public enum AIRegistry {
    public static let tools = Registry<AIToolDescriptor>(BuiltinAITools.all)
    public static func tools(for target: AIToolTarget) -> [AIToolDescriptor] { tools.all.filter { $0.target == target } }
}

public enum AIResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Valse_ValseAI", fallback: .module)
    public static func register() { L10n.shared.register(bundle) }
}
