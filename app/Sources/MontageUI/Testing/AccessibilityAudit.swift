import AppKit

/// SE-017 VoiceOver audit: walks the window's accessibility tree (what VoiceOver reads) and lists interactive or
/// image elements that have no spoken name. UI scripts run it with the `a11yAudit` step after opening each panel.
/// Reads attributes through the generic `accessibilityAttributeValue` path (what assistive apps see), so AppKit views,
/// `NSAccessibilityElement`s and SwiftUI's accessibility nodes are all covered.
@MainActor
enum AccessibilityAudit {
    struct Issue { let role: String; let id: String; let frame: CGRect }
    static var roleCounts: [String: Int] = [:]

    static let interactive: Set<String> = Set([NSAccessibility.Role.button, .checkBox, .radioButton, .slider, .popUpButton, .menuButton,
                                               .textField, .comboBox, .incrementor, .image, .disclosureTriangle].map(\.rawValue))

    static func attr(_ o: NSObject, _ a: NSAccessibility.Attribute) -> Any? { o.accessibilityAttributeValue(a) }
    static func string(_ o: NSObject, _ a: NSAccessibility.Attribute) -> String {
        let v = attr(o, a)
        if let s = v as? String { return s }
        if let s = v as? NSAttributedString { return s.string }
        return ""
    }
    static func children(_ o: NSObject) -> [NSObject] {
        var out = (attr(o, .children) as? [Any])?.compactMap { $0 as? NSObject } ?? []
        if out.isEmpty, let v = o as? NSView {
            // SwiftUI hosting views publish their nodes through the modern API; plain subviews as a last resort
            out = (v.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            if out.isEmpty { out = v.subviews }
        }
        return out
    }

    /// The spoken name: description (label), title, help; fields / sliders may speak their value or placeholder; a
    /// button whose only child is a text or labelled image speaks that child; a "titleUIElement" link counts too.
    static func name(_ o: NSObject, role: String) -> String {
        for a in [NSAccessibility.Attribute.description, .title, .help] { let s = string(o, a); if !s.isEmpty { return s } }
        if attr(o, .titleUIElement) != nil { return "titled" }
        if [NSAccessibility.Role.textField, .comboBox, .slider, .incrementor].map(\.rawValue).contains(role) {
            let p = string(o, .placeholderValue); if !p.isEmpty { return p }
            if let v = attr(o, .value) { let s = "\(v)"; if !s.isEmpty { return s } }
        }
        let kids = children(o)
        if kids.count == 1 {
            for a in [NSAccessibility.Attribute.value, .description, .title] { let s = string(kids[0], a); if !s.isEmpty { return s } }
        }
        return ""
    }

    /// Unlabeled elements under `root`, plus how many interactive elements were checked.
    static func run(_ root: NSObject, limit: Int = 8000) -> (issues: [Issue], checked: Int) {
        var issues: [Issue] = [], checked = 0, seen = 0
        var stack: [NSObject] = [root]
        while let o = stack.popLast(), seen < limit {
            seen += 1
            if let v = o as? NSView, v.isHiddenOrHasHiddenAncestor { continue }
            let role = string(o, .role)
            roleCounts[role, default: 0] += 1
            if interactive.contains(role) {
                var frame = CGRect.zero
                if let p = (attr(o, .position) as? NSValue)?.pointValue, let s = (attr(o, .size) as? NSValue)?.sizeValue {
                    frame = CGRect(origin: p, size: s)
                }
                if frame.width > 1, frame.height > 1 {
                    checked += 1
                    if name(o, role: role).trimmingCharacters(in: .whitespaces).isEmpty {
                        issues.append(Issue(role: role, id: string(o, .identifier), frame: frame))
                    }
                }
            }
            stack.append(contentsOf: children(o).reversed())
        }
        return (issues, checked)
    }

    /// SwiftUI builds its accessibility nodes only once an assistive client asked for them: say so, like VoiceOver does.
    static func enableTree() {
        for a in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: a))
        }
    }

    static func dump(_ window: NSWindow?) -> [String: Any] {
        guard let root = window?.contentView else { return ["checked": 0, "unlabeled": [] as [Any]] }
        roleCounts = [:]
        enableTree()
        let r = run(root)
        return ["checked": r.checked, "roles": roleCounts,
                "unlabeled": r.issues.map { "\($0.role)#\($0.id)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }]
    }
}
