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

// Text style presets live in Builtin/TextStyles.swift (text engine, W7).
