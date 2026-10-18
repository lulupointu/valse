import MontageCore

/// "Stickers" tab. Emoji stickers need no assets (rendered with Core Text at any resolution).
public enum BuiltinStickers {
    static func emoji(_ name: String, _ e: String, group: String = "emoji") -> StickerDescriptor {
        StickerDescriptor(id: "montage.sticker.\(name)", nameKey: "sticker.\(name)", groupKey: "sticker.group.\(group)",
                          source: .emoji(e))
    }
    public static let all: [StickerDescriptor] = [
        emoji("heart", "❤️"), emoji("star", "⭐️"), emoji("fire", "🔥"), emoji("laugh", "😂"),
        emoji("thumbsUp", "👍"), emoji("party", "🎉"), emoji("sparkles", "✨"), emoji("cool", "😎"),
        emoji("arrow", "➡️", group: "shapes"), emoji("check", "✅", group: "shapes"),
    ]
}

/// Text presets ("Text → Presets").
public enum BuiltinTextStyles {
    public static let all: [TextStyleDescriptor] = [
        .init(id: "montage.text.default", nameKey: "textStyle.default") { _ in },
        .init(id: "montage.text.outline", nameKey: "textStyle.outline") { t in
            t.color = .white; t.strokeColor = .black; t.strokeWidth = 0.12; t.bold = true
        },
        .init(id: "montage.text.yellow", nameKey: "textStyle.yellow") { t in
            t.color = RGBA(hex: 0xFFD400); t.strokeColor = .black; t.strokeWidth = 0.1; t.bold = true
        },
        .init(id: "montage.text.box", nameKey: "textStyle.box") { t in
            t.color = .black; t.backgroundColor = .white; t.bold = true
        },
        .init(id: "montage.text.shadow", nameKey: "textStyle.shadow") { t in
            t.color = .white; t.shadowColor = RGBA(0, 0, 0, 0.8)
        },
    ]
}
