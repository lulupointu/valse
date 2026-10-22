import SwiftUI
import MontageCore
import MontageEffects
import Perception

/// Text ▸ Spoken word (captions only, OB-10c): manual controls for every word-state effect the caption templates apply
/// (`KaraokeStyle`): what happens to the word being spoken (mode, colour, outline, scale, box, bounce), to the words not
/// spoken yet (opacity). Picking a template writes the same fields, so its values show
/// here; edits follow "Apply to all main captions" like every other caption style edit (`CaptionStyleSync`).
struct CaptionSpokenWordSection: View {
    let ctx: InspectorContext

    /// `KaraokeStyle` fields this tab edits (unit-tested against the struct so a new template field gets a control).
    static let exposedFields: Set<String> = ["mode", "highlightColor", "highlightStroke", "highlightScale", "boxColor",
                                             "unspokenOpacity", "bounce"]

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.karaoke != nil },
                             toggle: { t, on in t.karaoke = on ? (t.karaoke ?? KaraokeStyle()) : nil },
                             reset: { t in t.karaoke = KaraokeStyle() })
    }

    static func set(_ ctx: InspectorContext, _ body: @escaping (inout KaraokeStyle) -> Void) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.updateText(id, nameKey: "cmd.spokenWord") { t in
            var k = t.karaoke ?? KaraokeStyle()
            body(&k)
            t.karaoke = k
        }
    }

    private func row(_ label: String, _ id: String, range: ClosedRange<Double>, get: @escaping (KaraokeStyle) -> Double,
                     set: @escaping (inout KaraokeStyle, Double) -> Void) -> some View {
        var r = TextInspector.row(ctx, label, range: range, get: { t in t.karaoke.map(get) ?? range.lowerBound },
                                  set: { t, v in var k = t.karaoke ?? KaraokeStyle(); set(&k, v); t.karaoke = k })
        r.testID = id   // slider "<id>", field "<id>.field"
        return r
    }

    private func color(_ label: String, _ id: String, _ value: RGBA, set: @escaping (inout KaraokeStyle, RGBA) -> Void) -> some View {
        InlineRow(label: label) {
            ColorSwatchButton(color: value, eyedropper: ctx.store) { col in Self.set(ctx) { set(&$0, col) } }
                .testID(id)
            Spacer()
        }
    }

    /// Optional colour (outline, box):a toggle line, then the colour row when on.
    @ViewBuilder
    private func optionalColor(_ label: String, _ id: String, _ value: RGBA?, default d: RGBA, colorLabel: String,
                               set: @escaping (inout KaraokeStyle, RGBA?) -> Void) -> some View {
        ToggleLine(label: label, isOn: Binding.perceived(get: { value != nil }, set: { on in Self.set(ctx) { set(&$0, on ? (value ?? d) : nil) } }))
            .testID(id)
        if let v = value {
            color(colorLabel, id + ".color", v) { k, c in set(&k, c) }
        }
    }

    var body: some View {
        WithPerceptionTracking {
            let k = TextInspector.text(ctx)?.karaoke ?? KaraokeStyle()
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("spokenWord.mode")) {
                    Dropdown(items: KaraokeMode.allCases.map { ($0, tr("spokenWord.mode.\($0.rawValue)")) }, selection: k.mode) { m in
                        Self.set(ctx) { $0.mode = m }
                    }
                    .testID("spokenWord.mode")
                }
                HintText(text: tr("spokenWord.mode.\(k.mode.rawValue).hint"))
                GroupCaption(title: tr("spokenWord.group.active"))
                color(tr("spokenWord.textColor"), "spokenWord.color", k.highlightColor) { $0.highlightColor = $1 }
                optionalColor(tr("spokenWord.outline"), "spokenWord.outline", k.highlightStroke, default: .black, colorLabel: tr("spokenWord.outline.color")) { $0.highlightStroke = $1 }
                optionalColor(tr("spokenWord.box"), "spokenWord.box", k.boxColor, default: RGBA(hex: 0x8C4BFF), colorLabel: tr("spokenWord.box.color")) { $0.boxColor = $1 }
                row(tr("spokenWord.scale"), "spokenWord.scale", range: 50...200, get: { $0.highlightScale * 100 }, set: { $0.highlightScale = $1 / 100 })
                row(tr("spokenWord.bounce"), "spokenWord.bounce", range: 0...50, get: { $0.bounce * 100 }, set: { $0.bounce = $1 / 100 })
                GroupCaption(title: tr("spokenWord.group.unspoken"))
                row(tr("spokenWord.unspokenOpacity"), "spokenWord.unspokenOpacity", range: 0...100,
                    get: { $0.unspokenOpacity * 100 }, set: { $0.unspokenOpacity = $1 / 100 })
                HintText(text: tr("spokenWord.hint"))
            }
        }
    }
}
