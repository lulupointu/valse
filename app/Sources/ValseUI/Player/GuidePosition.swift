import SwiftUI
import ValseCore
import Perception

/// Guide position in canvas pixels or percent (PB-011 "edit guide position").
enum GuidePositionMath {
    static func pixels(_ position: Double, length: Double) -> Double { (position * length).rounded() }
    /// Parses "540", "540px", "50%", "50 %" (comma decimals too) into a 0…1 position; nil when invalid / outside.
    static func parse(_ text: String, length: Double, percent: Bool) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        var pct = percent
        if t.hasSuffix("%") { pct = true; t.removeLast() } else if t.hasSuffix("px") { pct = false; t.removeLast(2) }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), length > 0 else { return nil }
        let pos = pct ? v / 100 : v / length
        return pos >= 0 && pos <= 1 ? pos : nil
    }
}

/// Small card under the player header: "Horizontal guide  [540] px | %  [Delete] [OK]".
struct GuidePositionPopover: View {
    let store: EditorStore
    @Perception.Bindable var ui: PlayerUIState
    @State private var text = ""
    @State private var percent = false
    @State private var invalid = false

    var body: some View {
        WithPerceptionTracking {
            if let id = ui.editingGuide, let g = ui.guides.first(where: { $0.id == id }) {
                let length = Double(g.axis == .vertical ? store.projectSettings.canvasSize.width : store.projectSettings.canvasSize.height)
                HStack(spacing: 8) {
                    Text(loc: g.axis == .vertical ? "player.guide.vertical" : "player.guide.horizontal")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextField("", text: $text)
                        .textFieldStyle(ValseFieldStyle()).frame(width: 70).font(.system(size: 12).monospacedDigit())
                        .onSubmit { commit(id, length) }
                        .testID("guide.position")
                    SubTabBar(items: [("px", "px"), ("pct", "%")], selection: percent ? "pct" : "px") { v in
                        let pos = GuidePositionMath.parse(text, length: length, percent: percent) ?? g.position
                        percent = v == "pct"
                        text = format(pos, length)
                    }
                    .frame(width: 80)
                    Button(tr("tlmenu.delete")) { ui.guides.removeAll { $0.id == id }; ui.editingGuide = nil }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("guide.delete")
                    Button(tr("common.ok")) { commit(id, length) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("guide.ok")
                    IconButton("xmark", help: tr("common.close")) { ui.editingGuide = nil }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.menu, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(invalid ? Theme.Valse.orange : .clear))
                .valseFloatingCard(radius: 6, depth: 3)
                .onAppear { text = format(g.position, length) }
                .onValueChange(of: id) { _, _ in text = format(g.position, length) }
                .testID("guide.dialog")
            }
        }
    }

    func format(_ pos: Double, _ length: Double) -> String {
        percent ? Fmt.num(pos * 100, 1) : String(Int(GuidePositionMath.pixels(pos, length: length)))
    }

    func commit(_ id: UUID, _ length: Double) {
        guard let pos = GuidePositionMath.parse(text, length: length, percent: percent),
              let i = ui.guides.firstIndex(where: { $0.id == id }) else { invalid = true; return }
        invalid = false
        ui.guides[i].position = pos
        ui.editingGuide = nil
    }
}
