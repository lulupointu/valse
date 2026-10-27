import Foundation

/// SF Symbols newer than the deployment floor (macOS 13 = SF Symbols 4) render as NOTHING on older systems.
/// Wrap such a name in `SFSymbolCompat.compat("…")` where it is defined (registry entry, view literal): on macOS 14+ the
/// name is returned unchanged; on 13 the closest SF Symbols 4 glyph from `fallbacks` is used instead.
/// Renamed glyphs don't need this: write their OLD spelling (e.g. `speedometer`), which every OS resolves.
/// Enforced by `scripts/check_sf_symbols.py` and `SFSymbolAvailabilityTests` (a too-new literal outside `compat("…")`, or a
/// fallback that is itself too new, fails the build gate).
public enum SFSymbolCompat {
    /// too-new name → macOS 13 fallback. One `"name": "fallback",` pair per line (parsed by check_sf_symbols.py).
    public static let fallbacks: [String: String] = [
        "arrow.down.right.and.arrow.up.left.rectangle": "arrow.down.right.and.arrow.up.left",
        "arrow.up.left.and.arrow.down.right.rectangle": "arrow.up.left.and.arrow.down.right",
        "book.pages": "book",
        "circle.dotted.circle": "circle.dotted",
        "circle.lefthalf.filled.righthalf.striped.horizontal": "circle.lefthalf.filled",
        "circle.lefthalf.striped.horizontal": "circle.righthalf.filled",
        "circle.lefthalf.striped.horizontal.inverse": "circle.lefthalf.filled",
        "drop.halffull": "drop.fill",
        "figure.child": "figure.and.child.holdinghands",
        "fireworks": "party.popper",
        "rainbow": "camera.filters",
        "gauge.with.needle": "gauge",
        "key.slash": "lock.slash",
        "lightbulb.max": "lightbulb.fill",
        "rectangle.portrait.rotate": "rotate.right",
        "tv.slash": "tv",
        "waveform.badge.mic": "waveform.and.mic",
    ]

    /// `name` on macOS 14+, its SF Symbols 4 fallback on macOS 13.
    public static func compat(_ name: String) -> String {
        if #available(macOS 14, *) { return name }
        return fallbacks[name] ?? name
    }

    /// The name used when running on macOS 13 (tests).
    public static func macOS13Name(_ name: String) -> String { fallbacks[name] ?? name }
}
