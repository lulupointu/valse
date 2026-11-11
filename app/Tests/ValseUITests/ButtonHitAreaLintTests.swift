import Testing
import Foundation

/// BUG-HIT-AREA (owner: "I can only click on the drawn icon, not the full button"). A SwiftUI `.plain` button, or an
/// `onTapGesture` on an icon, hit-tests only its own frame: a bare 11 pt `Image(systemName:)` is a ~10 pt target.
/// Every icon-only plain button / tappable icon in ValseUI must be a `GlyphButton` / `.valseTapArea` (Support/
/// Controls.swift: target grown to ≥ 20 pt, layout unchanged), or give its label a sized `.contentShape` / a filled
/// `.background` key. Source lint: it reads a plain button's source from its `Button` line to its `.buttonStyle`.
struct ButtonHitAreaLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ValseUI")

    static let hitShapes = ["valseTapArea", "contentShape", ".background("]
    /// TODO(BUG-HIT-AREA): AssetPanel was being reworked by another agent when this lint landed; it still has bare glyph
    /// buttons (EffectLibraryTab, Library/LibraryBrowser, SubprojectsView). Fix them, then drop this exclusion.
    static let excluded: [String] = []

    static func swiftFiles() -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        for case let u as URL in e where u.pathExtension == "swift" && !excluded.contains(where: u.path.contains) { out.append(u) }
        return out.sorted { $0.path < $1.path }
    }

    /// Icon-only plain buttons / tapped icons without a hit shape, as "File.swift:line".
    static func violations(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if line.contains(".buttonStyle(.plain)") || line.contains(".buttonStyle(PlainButtonStyle())") {
                // the button's source: back to its `Button` line (≤ 12 lines), up to the style line
                var j = i
                while j > max(0, i - 12), !lines[j].contains("Button") { j -= 1 }
                guard lines[j].contains("Button") else { continue }
                let block = lines[j...i].joined(separator: "\n")
                let iconOnly = block.contains("Image(systemName:") && !block.contains("Text(") && !block.contains("Label(")
                    && !block.contains("Button(tr(")
                if iconOnly && !hitShapes.contains(where: block.contains) { out.append("\(file):\(j + 1)") }
            }
            if line.contains(".onTapGesture") {
                let block = lines[max(0, i - 3)...i].joined(separator: "\n")
                if block.contains("Image(systemName:") && !hitShapes.contains(where: block.contains) { out.append("\(file):\(i + 1)") }
            }
        }
        return out
    }

    @Test func iconButtonsHaveAHitShape() throws {
        let files = Self.swiftFiles()
        #expect(files.count > 100, "ValseUI sources not found at \(Self.sources.path)")
        var bad: [String] = []
        for f in files {
            bad += Self.violations(in: try String(contentsOf: f, encoding: .utf8), file: f.lastPathComponent)
        }
        #expect(bad.isEmpty, "icon-only plain buttons / tapped icons hit-test only the glyph; use GlyphButton / .valseTapArea: \(bad)")
    }

    @Test func lintCatchesABareGlyphButton() {
        let bare = """
        Button { close() } label: { Image(systemName: "xmark").font(.system(size: 11)) }
            .buttonStyle(.plain).help("x")
        Image(systemName: "star").onTapGesture { fav() }
        """
        #expect(Self.violations(in: bare, file: "X.swift") == ["X.swift:1", "X.swift:3"])
        let fixed = """
        GlyphButton(outset: 6) { close() } label: { Image(systemName: "xmark").font(.system(size: 11)) }
            .help("x")
        Button { pick() } label: { Image(systemName: "eyedropper").frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain)
        Image(systemName: "star").valseTapArea { fav() }
        """
        #expect(Self.violations(in: fixed, file: "X.swift").isEmpty)
    }
}
