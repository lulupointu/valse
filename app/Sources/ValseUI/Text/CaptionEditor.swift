import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import ValseEngine
import Perception

/// Text ▸ Basic, captions only: "Apply to all main captions" (CapCut [11], on by default). When on, every style edit
/// made on this caption restyles the other captions of its track in the same undo step (`CaptionStyleSync`).
struct ApplyToAllCaptionsRow: View {
    let ctx: InspectorContext
    @Perception.Bindable private var ui = TextUIState.shared
    var body: some View {
        WithPerceptionTracking {
            Button { ui.applyToAllCaptions.toggle() } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(ui.applyToAllCaptions ? Theme.accent : Theme.stepper)
                        if ui.applyToAllCaptions { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.textPrimary) }
                    }
                    .frame(width: 16, height: 16)
                    Text(loc: "captions.applyAllMain").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("captions.applyAllMain.help"))
            .padding(.top, 2).padding(.bottom, 4)
            .testID("captions.applyAllMain")
        }
    }
}

/// Text ▸ Templates ▸ Caption (captions, C4 [18], OB-10: first category of the Templates sub-tab): karaoke / caption
/// looks, applied to every caption of the track ("Apply to all main captions" on) or only to the selected one. Their
/// spoken-word values are then editable in Text ▸ Spoken word.
struct CaptionTemplatesSection: View {
    let ctx: InspectorContext
    /// Lower-cased search text of the Templates sub-tab ("" = all).
    var query = ""
    var body: some View {
        WithPerceptionTracking {
            let cat = tr("text.templates.caption")
            let items = Registries.captionTemplates.all.filter {
                query.isEmpty || tr($0.nameKey).lowercased().contains(query) || cat.lowercased().contains(query) || tr($0.groupKey).lowercased().contains(query)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: cat).font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                    TileGrid {
                        ForEach(items) { d in
                            WithPerceptionTracking {
                                Tile(title: tr(d.nameKey), testID: "captionTemplate.\(d.id)") { ctx.store.applyCaptionTemplate(d) } content: {
                                    TextPreviewImage(key: "captionTemplate:\(d.id)", content: Self.preview(d), fontPx: 30, padding: 4)
                                }
                            }
                        }
                    }
                }
                .testID("text.templates.caption")
            }
        }
    }

    static func preview(_ d: CaptionTemplateDescriptor) -> TextContent {
        var t = CaptionOps.defaultStyle()
        t.string = "Aa Bb"
        d.apply(&t)
        // show the highlighted look on the second word
        if let k = t.karaoke, k.mode != .singleWord {
            t.applyStyle(TextRunStyle(color: k.highlightColor, backgroundColor: k.boxColor), to: TextSpan(3, 2))
        }
        t.karaoke = nil
        t.fontSize = 0.1
        return t
    }
}
