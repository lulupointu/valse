import AppKit
import ApplicationServices

/// SE-017 audit through the real Accessibility API (AXUIElement of our own process), the path VoiceOver uses: SwiftUI
/// only builds its accessibility nodes for such clients. Runs on a background thread while the main thread keeps
/// serving the requests (the driver awaits it). Needs no permission for the own process on recent macOS; when the API
/// refuses, `run` returns nil and the in-process audit is used instead.
nonisolated enum AccessibilityAuditAX {
    struct Result: Sendable { var checked = 0; var unlabeled: [String] = []; var roles: [String: Int] = [:]; var error: String? }

    static let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenuButton",
                                           "AXTextField", "AXComboBox", "AXIncrementor", "AXImage", "AXDisclosureTriangle"]

    static func value(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ a: String) -> String { (value(e, a) as? String) ?? "" }

    static func name(_ e: AXUIElement, role: String) -> String {
        for a in ["AXDescription", "AXTitle", "AXHelp"] { let s = string(e, a); if !s.isEmpty { return s } }
        // window buttons: VoiceOver speaks their subrole ("close button")
        if ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(string(e, "AXSubrole")) { return "window button" }
        if value(e, "AXTitleUIElement") != nil { return "titled" }
        if ["AXTextField", "AXComboBox", "AXSlider", "AXIncrementor"].contains(role) {
            let p = string(e, "AXPlaceholderValue"); if !p.isEmpty { return p }
            if let v = value(e, "AXValue") { let s = "\(v)"; if !s.isEmpty { return s } }
        }
        if let kids = value(e, "AXChildren") as? [AXUIElement], kids.count == 1 {
            for a in ["AXValue", "AXDescription", "AXTitle"] { let s = string(kids[0], a); if !s.isEmpty { return s } }
        }
        return ""
    }

    /// The first element with this AXIdentifier under `roots` (depth-first).
    static func find(_ id: String, in roots: [AXUIElement], limit: Int = 12000) -> AXUIElement? {
        var stack = roots, seen = 0
        while let e = stack.popLast(), seen < limit {
            seen += 1
            if string(e, "AXIdentifier") == id { return e }
            stack.append(contentsOf: ((value(e, "AXChildren") as? [AXUIElement]) ?? []).reversed())
        }
        return nil
    }

    /// Walks the windows of this process (`scope`: only the subtree of the element with that test ID).
    static func run(limit: Int = 12000, scope: String? = nil) -> Result {
        var r = Result()
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 5)
        guard var windows = value(app, "AXWindows") as? [AXUIElement] else { r.error = "no AXWindows (accessibility API refused)"; return r }
        if let scope {
            guard let e = find(scope, in: windows) else { r.error = "no element \(scope)"; return r }
            windows = [e]
        }
        var stack: [(AXUIElement, String)] = windows.map { ($0, "") }, seen = 0
        while let (e, ctx) = stack.popLast(), seen < limit {
            seen += 1
            let role = string(e, "AXRole")
            r.roles[role, default: 0] += 1
            // parts of AppKit scroll bars (page areas, knob) are announced by the system as part of the scroll bar
            if interactive.contains(role), !ctx.hasSuffix("|AXScrollBar") {
                var size = CGSize.zero, pos = CGPoint.zero
                if let v = value(e, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &size) }
                if let v = value(e, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
                if size.width > 1, size.height > 1 {
                    r.checked += 1
                    if name(e, role: role).trimmingCharacters(in: .whitespaces).isEmpty {
                        r.unlabeled.append("\(role)#\(string(e, "AXIdentifier"))@\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)) in \(ctx) kids=\(((value(e, "AXChildren") as? [AXUIElement]) ?? []).map { string($0, "AXRole") + ":" + string($0, "AXValue") })")
                    }
                }
            }
            if let kids = value(e, "AXChildren") as? [AXUIElement] {
                let id = string(e, "AXIdentifier")
                let base = ctx.components(separatedBy: "|").first ?? ""
                let c = (id.isEmpty ? base : id) + (role == "AXScrollBar" ? "|AXScrollBar" : "")
                stack.append(contentsOf: kids.reversed().map { ($0, c) })
            }
        }
        return r
    }
}
