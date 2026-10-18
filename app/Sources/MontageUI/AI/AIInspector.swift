import SwiftUI
import MontageCore

/// Inspector tabs/sections contributed by the AI workstream (appended to `BuiltinInspector`).
@MainActor
enum AIInspector {
    static var tabs: [InspectorTab] { TTSInspector.tabs + TrackingInspector.tabs }
    static var sections: [InspectorSection] { CutoutInspector.sections + TTSInspector.sections + VideoAIInspector.sections + TrackingInspector.sections + ColorLookInspector.sections + EnhanceInspector.sections + FaceCoverInspector.sections + CameraLockInspector.sections + AIRemoveInspector.sections }
}
