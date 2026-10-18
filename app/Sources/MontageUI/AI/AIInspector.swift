import SwiftUI
import MontageCore

/// Inspector tabs/sections contributed by the AI workstream (appended to `BuiltinInspector`).
@MainActor
enum AIInspector {
    static var tabs: [InspectorTab] { TTSInspector.tabs }
    static var sections: [InspectorSection] { CutoutInspector.sections + TTSInspector.sections + VideoAIInspector.sections }
}
