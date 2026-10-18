import SwiftUI
import MontageCore

/// Inspector tabs/sections contributed by the AI workstream (appended to `BuiltinInspector`).
@MainActor
enum AIInspector {
    static var tabs: [InspectorTab] { CaptionsInspector.tabs + TTSInspector.tabs }
    static var sections: [InspectorSection] { CutoutInspector.sections + CaptionsInspector.sections + TTSInspector.sections }
}
