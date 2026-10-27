import SwiftUI
import AppKit
import MontageCore
import Perception

/// Export dialog palette (UX.md §7.1, screenshots 110–113).
enum ExportStyle {
    static var background: Color { Theme.panel }
    static var field: Color { Color(hex: Chrome.p.control) }
    static var label: Color { Color(hex: Chrome.p.iLabel) }
    static var disabledLabel: Color { Color(hex: Chrome.p.iconDim) }
    static var separator: Color { Theme.separator }
    /// Wide enough for the longest French labels on one line ("Échantillonnage audio", UX_GAPS W11-2).
    static let labelWidth: CGFloat = 142
    static let rowHeight: CGFloat = 30
}

/// File sizes in the UI language (not the system locale): "44.3 MB" / "44,3 Mo" (decimal units, like Finder).
enum ExportFormat {
    static func bytes(_ n: Int64) -> String {
        let units = ["export.unit.kb", "export.unit.mb", "export.unit.gb", "export.unit.tb"]
        var v = Double(max(n, 0)) / 1000
        var u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        if n < 1000 { return tr("export.unit.bytes", Int(n)) }
        let f = NumberFormatter()
        f.locale = L10n.shared.locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = v < 100 ? 1 : 0
        return tr(units[u], f.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v))
    }
}

/// One menu entry: title, optional grey subtitle (codec menu), enabled flag.
struct ExportMenuItem<ID: Hashable> {
    let id: ID
    let title: String
    var subtitle: String? = nil
    var enabled = true
}

/// CapCut export dropdown: `#333336` field, bold value, chevron right; native pop-up menu with ✓ and grey subtitles.
struct ExportDropdown<ID: Hashable>: View {
    let items: [ExportMenuItem<ID>]
    let selection: ID
    var enabled = true
    let onSelect: (ID) -> Void

    var body: some View {
        WithPerceptionTracking {
            Button {
                ExportMenuPresenter.show(items: items, selection: selection, onSelect: onSelect)
            } label: {
                HStack {
                    Text(verbatim: items.first { $0.id == selection }?.title ?? "")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .background(ExportStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
        }
    }
}

@MainActor
enum ExportMenuPresenter {
    static func show<ID: Hashable>(items: [ExportMenuItem<ID>], selection: ID, onSelect: @escaping (ID) -> Void) {
        let m = NSMenu()
        m.autoenablesItems = false
        for it in items {
            let i = PlayerMenuAction.item(it.title) { onSelect(it.id) }
            i.state = it.id == selection ? .on : .off
            i.isEnabled = it.enabled
            if let sub = it.subtitle {
                let s = NSMutableAttributedString(string: it.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
                s.append(NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                i.attributedTitle = s
            }
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// "Label ……… [control]" row (label 104 pt).
struct ExportRow<Content: View>: View {
    let label: String
    var enabled = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(enabled ? ExportStyle.label : ExportStyle.disabledLabel)
                    .frame(width: ExportStyle.labelWidth, alignment: .leading).lineLimit(1).minimumScaleFactor(0.85)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: ExportStyle.rowHeight)
        }
    }
}

/// "☑ Video exporting ▴" section header: checkbox enables the output; the chevron collapses the section.
struct ExportSectionHeader: View {
    let id: String
    let title: String
    @Binding var isOn: Bool
    @Binding var expanded: Bool
    var enabled = true
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                Button { isOn.toggle() } label: {
                    HStack(spacing: 8) {
                        ExportCheckboxBox(isOn: isOn)
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(enabled ? .white : ExportStyle.disabledLabel)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!enabled).testID("export.section.\(id)")
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 7))
                        .foregroundStyle(enabled ? Theme.textSecondary : ExportStyle.disabledLabel).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).testID("export.section.\(id).expand")
                Spacer()
            }
            .frame(height: 32)
        }
    }
}

/// CapCut checkbox look as a Button (synthetic UI-test clicks reach Buttons, not tap gestures).
struct ExportCheckbox: View {
    @Binding var isOn: Bool
    var enabled = true
    var body: some View {
        WithPerceptionTracking {
            Button { isOn.toggle() } label: { ExportCheckboxBox(isOn: isOn) }
                .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
    }
}

struct ExportCheckboxBox: View {
    let isOn: Bool
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(isOn ? Theme.accent : Theme.stepper)
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.textPrimary) }
            }
            .frame(width: 16, height: 16)
        }
    }
}

/// 36×20 switch (CapToggle look) as a Button.
struct ExportToggle: View {
    @Binding var isOn: Bool
    var enabled = true
    var label = ""   // SE-017
    var body: some View {
        WithPerceptionTracking {
            Button { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.accent : Theme.stepper).frame(width: 36, height: 20)
                    Circle().fill(Color.white).frame(width: 14, height: 14).padding(.horizontal, 3)
                }
                .frame(width: 36, height: 20).contentShape(Capsule())
            }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            .accessibilityLabel(Text(verbatim: label.isEmpty ? tr("ax.switch") : label))
            .accessibilityValue(Text(verbatim: tr(isOn ? "ax.on" : "ax.off")))
        }
    }
}
