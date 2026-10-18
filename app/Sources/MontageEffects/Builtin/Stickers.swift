import MontageCore

/// "Stickers" tab (ST-001/002/008). Emoji stickers need no assets (rendered with the system emoji font through
/// Core Text at any resolution, never redistributed); shapes, arrows, callouts and decorations are procedural
/// vector stickers (`VectorLayer`) drawn by the engine at output resolution.
public enum BuiltinStickers {
    static func emoji(_ name: String, _ e: String, group: String = "emoji", tags: [String] = []) -> StickerDescriptor {
        StickerDescriptor(id: "montage.sticker.\(name)", nameKey: "sticker.\(name)", groupKey: "sticker.group.\(group)",
                          source: .emoji(e), tags: tags)
    }

    static func vector(_ name: String, group: String, _ layers: [VectorLayer], tags: [String] = []) -> StickerDescriptor {
        StickerDescriptor(id: "montage.sticker.\(name)", nameKey: "sticker.\(name)", groupKey: "sticker.group.\(group)",
                          source: .vector(layers), tags: tags)
    }

    /// The original set (ids kept for saved projects).
    static let legacy: [StickerDescriptor] = [
        emoji("heart", "❤️"), emoji("star", "⭐️"), emoji("fire", "🔥"), emoji("laugh", "😂"),
        emoji("thumbsUp", "👍"), emoji("party", "🎉"), emoji("sparkles", "✨"), emoji("cool", "😎"),
        emoji("arrow", "➡️", group: "shapes"), emoji("check", "✅", group: "shapes"),
    ]

    /// (key, emoji, group) — names in StickerLibrary.strings.
    static let emojiTable: [(String, String, String)] = [
        ("smile", "😊", "emoji"), ("grin", "😁", "emoji"), ("wink", "😉", "emoji"), ("heartEyes", "😍", "emoji"),
        ("starStruck", "🤩", "emoji"), ("thinking", "🤔", "emoji"), ("shocked", "😱", "emoji"), ("crying", "😭", "emoji"),
        ("angry", "😡", "emoji"), ("sleepy", "😴", "emoji"), ("mindBlown", "🤯", "emoji"), ("partyFace", "🥳", "emoji"),
        ("rofl", "🤣", "emoji"), ("cold", "🥶", "emoji"), ("hot", "🥵", "emoji"), ("skull", "💀", "emoji"),
        ("ghost", "👻", "emoji"), ("alien", "👽", "emoji"), ("robot", "🤖", "emoji"), ("clown", "🤡", "emoji"),
        ("clap", "👏", "gestures"), ("wave", "👋", "gestures"), ("ok", "👌", "gestures"), ("victory", "✌️", "gestures"),
        ("pray", "🙏", "gestures"), ("muscle", "💪", "gestures"), ("pointUp", "☝️", "gestures"), ("pointRight", "👉", "gestures"),
        ("thumbsDown", "👎", "gestures"), ("raisedHands", "🙌", "gestures"), ("eyes", "👀", "gestures"), ("hundred", "💯", "symbols"),
        ("redHeart", "❤️‍🔥", "love"), ("pinkHeart", "🩷", "love"), ("brokenHeart", "💔", "love"), ("sparklingHeart", "💖", "love"),
        ("kiss", "💋", "love"), ("rose", "🌹", "love"), ("loveLetter", "💌", "love"), ("ring", "💍", "love"),
        ("balloon", "🎈", "celebration"), ("gift", "🎁", "celebration"), ("cake", "🎂", "celebration"), ("confettiBall", "🎊", "celebration"),
        ("trophy", "🏆", "celebration"), ("medal", "🥇", "celebration"), ("crown", "👑", "celebration"), ("fireworks", "🎆", "celebration"),
        ("christmasTree", "🎄", "celebration"), ("pumpkin", "🎃", "celebration"),
        ("dog", "🐶", "animals"), ("cat", "🐱", "animals"), ("unicorn", "🦄", "animals"), ("panda", "🐼", "animals"),
        ("butterfly", "🦋", "animals"), ("fox", "🦊", "animals"),
        ("pizza", "🍕", "food"), ("burger", "🍔", "food"), ("coffee", "☕️", "food"), ("donut", "🍩", "food"),
        ("iceCream", "🍦", "food"), ("avocado", "🥑", "food"), ("croissant", "🥐", "food"), ("cocktail", "🍹", "food"),
        ("sun", "☀️", "nature"), ("rainbow", "🌈", "nature"), ("lightning", "⚡️", "nature"), ("snowflake", "❄️", "nature"),
        ("flower", "🌸", "nature"), ("palm", "🌴", "nature"), ("moon", "🌙", "nature"), ("globe", "🌍", "nature"),
        ("camera", "📸", "objects"), ("music", "🎵", "objects"), ("microphone", "🎤", "objects"), ("rocket", "🚀", "objects"),
        ("money", "💰", "objects"), ("bell", "🔔", "objects"), ("lightBulb", "💡", "objects"), ("pin", "📍", "objects"),
        ("warning", "⚠️", "symbols"), ("cross", "❌", "symbols"), ("question", "❓", "symbols"), ("exclamation", "❗️", "symbols"),
        ("new", "🆕", "symbols"), ("up", "🔝", "symbols"), ("boom", "💥", "symbols"), ("zzz", "💤", "symbols"),
    ]

    // MARK: Vector stickers

    static let shapeColors: [(key: String, color: RGBA)] = [
        ("white", .white), ("black", RGBA(0.08, 0.08, 0.08)), ("yellow", RGBA(hex: 0xFFD400)), ("red", RGBA(hex: 0xFF3B30)),
        ("teal", RGBA(hex: 0x57BECB)),
    ]
    static let shapeKinds: [(key: String, shape: VectorLayer.Shape)] = [
        ("rect", .rect), ("roundedRect", .roundedRect), ("circle", .circle), ("triangle", .triangle), ("diamond", .diamond),
        ("hexagon", .hexagon), ("star", .star(points: 5)), ("heart", .heart), ("arrow", .arrow), ("line", .line), ("ring", .ring),
        ("plus", .plus), ("cross", .cross),
    ]

    /// Shapes (ST-008 basic graphics): every kind in five colours.
    static let shapes: [StickerDescriptor] = shapeKinds.flatMap { k in
        shapeColors.map { c in
            let layer: VectorLayer
            switch k.shape {
            case .ring: layer = VectorLayer(.ring, stroke: c.color, strokeWidth: 0.09)
            case .line: layer = VectorLayer(.line, stroke: c.color, strokeWidth: 0.08)
            default: layer = VectorLayer(k.shape, fill: c.color)
            }
            return vector("shape.\(k.key).\(c.key)", group: "shapes", [layer], tags: ["shape", k.key, c.key])
        }
    }

    static let white = RGBA.white, ink = RGBA(0.08, 0.08, 0.08), gold = RGBA(hex: 0xFFC83D), pink = RGBA(hex: 0xFF5C8A)

    static let callouts: [StickerDescriptor] = [
        vector("bubbleWhite", group: "callouts", [VectorLayer(.bubble, fill: white, stroke: ink, strokeWidth: 0.035, shadow: true)], tags: ["speech", "talk", "comic"]),
        vector("bubbleYellow", group: "callouts", [VectorLayer(.bubble, fill: RGBA(hex: 0xFFE14D), stroke: ink, strokeWidth: 0.035)], tags: ["speech", "comic"]),
        vector("bubbleTeal", group: "callouts", [VectorLayer(.bubble, fill: RGBA(hex: 0x57BECB))], tags: ["speech", "chat"]),
        vector("burstYellow", group: "callouts", [VectorLayer(.burst(points: 14), fill: RGBA(hex: 0xFFE14D), stroke: RGBA(hex: 0xFF3B30), strokeWidth: 0.03)], tags: ["pow", "boom", "comic", "sale"]),
        vector("burstRed", group: "callouts", [VectorLayer(.burst(points: 12), fill: RGBA(hex: 0xFF3B30), fillBottom: RGBA(hex: 0xC4161C))], tags: ["pow", "boom", "badge"]),
        vector("badgeGold", group: "callouts", [VectorLayer(.burst(points: 20), fill: gold, fillBottom: RGBA(hex: 0xE09A12)),
                                                 VectorLayer(.circle, stroke: white, strokeWidth: 0.025, inset: 0.24)], tags: ["seal", "award", "badge"]),
        vector("tagCircle", group: "callouts", [VectorLayer(.circle, fill: RGBA(hex: 0xFF3B30)), VectorLayer(.ring, stroke: white, strokeWidth: 0.03, inset: 0.14)], tags: ["badge", "label"]),
        vector("checkBadge", group: "callouts", [VectorLayer(.circle, fill: RGBA(hex: 0x34C759)), VectorLayer(.check, stroke: white, strokeWidth: 0.1, inset: 0.26)], tags: ["done", "yes", "tick"]),
        vector("crossBadge", group: "callouts", [VectorLayer(.circle, fill: RGBA(hex: 0xFF3B30)), VectorLayer(.cross, fill: white, inset: 0.3)], tags: ["no", "wrong"]),
    ]

    static let arrows: [StickerDescriptor] = [
        vector("arrowWhite", group: "arrows", [VectorLayer(.arrow, fill: white, stroke: ink, strokeWidth: 0.02, shadow: true)], tags: ["arrow", "point"]),
        vector("arrowYellow", group: "arrows", [VectorLayer(.arrow, fill: RGBA(hex: 0xFFD400), stroke: ink, strokeWidth: 0.025)], tags: ["arrow", "point"]),
        vector("arrowRed", group: "arrows", [VectorLayer(.arrow, fill: RGBA(hex: 0xFF3B30))], tags: ["arrow", "point"]),
        vector("chevronWhite", group: "arrows", [VectorLayer(.chevron, stroke: white, strokeWidth: 0.11)], tags: ["arrow", "next", "swipe"]),
        vector("chevronTeal", group: "arrows", [VectorLayer(.chevron, stroke: RGBA(hex: 0x57BECB), strokeWidth: 0.11)], tags: ["arrow", "next"]),
        vector("triangleArrow", group: "arrows", [VectorLayer(.triangle, fill: white, fillBottom: RGBA(0.8, 0.8, 0.8), shadow: true)], tags: ["play", "up"]),
    ]

    static let decor: [StickerDescriptor] = [
        vector("sparkleWhite", group: "decor", [VectorLayer(.sparkle, fill: white, shadow: true)], tags: ["shine", "twinkle", "star"]),
        vector("sparkleGold", group: "decor", [VectorLayer(.sparkle, fill: gold, fillBottom: RGBA(hex: 0xF09A10))], tags: ["shine", "gold"]),
        vector("starGold", group: "decor", [VectorLayer(.star(points: 5), fill: gold, fillBottom: RGBA(hex: 0xF09A10), stroke: white, strokeWidth: 0.025)], tags: ["star", "rating"]),
        vector("heartPink", group: "decor", [VectorLayer(.heart, fill: pink, fillBottom: RGBA(hex: 0xE0245E), shadow: true)], tags: ["love", "like"]),
        vector("heartOutline", group: "decor", [VectorLayer(.heart, stroke: white, strokeWidth: 0.06)], tags: ["love", "outline"]),
        vector("circleScribble", group: "decor", [VectorLayer(.ring, stroke: RGBA(hex: 0xFF3B30), strokeWidth: 0.05, inset: 0.08)], tags: ["highlight", "circle", "mark"]),
        vector("underline", group: "decor", [VectorLayer(.line, stroke: RGBA(hex: 0xFFD400), strokeWidth: 0.1)], tags: ["highlight", "line", "mark"]),
        vector("plusSign", group: "decor", [VectorLayer(.plus, fill: white, shadow: true)], tags: ["add", "plus"]),
        vector("starOutline", group: "decor", [VectorLayer(.star(points: 5), stroke: white, strokeWidth: 0.05)], tags: ["star", "outline"]),
        vector("diamondGem", group: "decor", [VectorLayer(.diamond, fill: RGBA(hex: 0x7FDBFF), fillBottom: RGBA(hex: 0x2F6BE0), stroke: white, strokeWidth: 0.02)], tags: ["gem", "jewel"]),
    ]

    public static let all: [StickerDescriptor] = legacy + emojiTable.map { emoji($0.0, $0.1, group: $0.2) }
        + callouts + arrows + decor + shapes + animated

    /// Animated (Lottie) stickers, generated by scripts/make_lottie_stickers.py into Resources/Lottie (W5, KF-012).
    static func lottie(_ name: String) -> StickerDescriptor {
        StickerDescriptor(id: "montage.sticker.anim.\(name)", nameKey: "sticker.anim.\(name)", groupKey: "sticker.group.animated",
                          source: .lottie(resource: "lottie-\(name).json", bundle: { EffectsResources.bundle }))
    }
    public static let animated: [StickerDescriptor] = ["heartbeat", "spinStar", "checkmark", "loadingRing", "bounceBall",
                                                       "confetti", "arrowNudge", "sparkle"].map(lottie)
}

// Text style presets live in Builtin/TextStyles.swift (text engine, W7).
