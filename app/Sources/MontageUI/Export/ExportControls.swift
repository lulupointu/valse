import SwiftUI
import AppKit
import MontageCore

/// Export dialog palette (UX.md §7.1, screenshots 110–113).
enum ExportStyle {
    static let background = Color(hex: 0x1C1C1C)
    static let field = Color(hex: 0x333336)
    static let label = Color(hex: 0xD9D9D9)
    static let disabledLabel = Color(hex: 0x5F5F5F)
    static let separator = Color(hex: 0x2E2E2E)
    static let labelWidth: CGFloat = 104
    static let rowHeight: CGFloat = 30
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
        Button {
            ExportMenuPresenter.show(items: items, selection: selection, onSelect: onSelect)
        } label: {
            HStack {
                Text(verbatim: items.first { $0.id == selection }?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
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
        HStack(spacing: 12) {
            Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(enabled ? ExportStyle.label : ExportStyle.disabledLabel)
                .frame(width: ExportStyle.labelWidth, alignment: .leading).lineLimit(2)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: ExportStyle.rowHeight)
    }
}

/// "☑ Video exporting ▴" section header: checkbox enables the output; the chevron collapses the section.
struct ExportSectionHeader: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var expanded: Bool
    var enabled = true
    var body: some View {
        HStack(spacing: 8) {
            CapCheckbox(isOn: $isOn, enabled: enabled)
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(enabled ? .white : ExportStyle.disabledLabel)
                .onTapGesture { if enabled { isOn.toggle() } }
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 7))
                    .foregroundStyle(enabled ? Theme.textSecondary : ExportStyle.disabledLabel).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(height: 32)
    }
}
