import SwiftUI
import AppKit

/// SwiftUI editor shell; heavy surfaces (player, timeline) are AppKit/Metal views bridged with
/// NSViewRepresentable. All strings are localization keys resolved from Localizable.strings (en/fr).
struct EditorShell: View {
    let player: NSView
    let timeline: NSView

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                Panel(title: "panel.media") {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2)).frame(height: 34)
                            .overlay(Text(String(format: NSLocalizedString("media.item", comment: ""), i + 1)).font(.system(size: 11)).foregroundStyle(.secondary))
                    }
                }.frame(width: 260)
                VStack(spacing: 4) {
                    Text("panel.player").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Host(view: player).aspectRatio(16 / 9, contentMode: .fit)
                    HStack { Image(systemName: "play.fill"); Text("00:00:00:00 / 00:01:00:00").monospacedDigit() }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(6).background(Color(white: 0.1))
                Panel(title: "panel.inspector") {
                    ForEach(["inspector.scale", "inspector.opacity", "inspector.saturation", "inspector.brightness"], id: \.self) { k in
                        HStack { Text(LocalizedStringKey(k)).font(.system(size: 11)); Slider(value: .constant(0.8)) }
                    }
                }.frame(width: 260)
            }.frame(height: 360)
            Host(view: timeline).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
    }
}

struct Panel<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
            Spacer()
        }.padding(8).frame(maxHeight: .infinity).background(Color(white: 0.1))
    }
}

struct Host: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
