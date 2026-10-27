import Testing
import Foundation
import AppKit
import SwiftUI
@testable import ValseUI

/// BUG-OVERSIZED-SHEETS: no sheet / popover / dialog / auxiliary window larger than its window, no window larger than
/// its screen. The clamping math, the layout primitive, and a source check that every presentation uses the mechanism.
@MainActor
struct WindowFitTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    // MARK: Math

    @Test func fitKeepsIdealWhenRoomAndClampsOtherwise() {
        let m = WindowFit.margin
        #expect(WindowFit.fit(CGSize(width: 720, height: 663), in: CGSize(width: 1687, height: 983)) == CGSize(width: 720, height: 663))
        // the export dialog in a 900×600 window: width kept, height = window − 2 margins
        #expect(WindowFit.fit(CGSize(width: 720, height: 663), in: CGSize(width: 900, height: 600)) == CGSize(width: 720, height: 600 - 2 * m))
        #expect(WindowFit.fit(CGSize(width: 860, height: 600), in: CGSize(width: 800, height: 500)) == CGSize(width: 800 - 2 * m, height: 500 - 2 * m))
        // never negative
        #expect(WindowFit.fit(CGSize(width: 100, height: 100), in: CGSize(width: 10, height: 10)) == .zero)
        #expect(WindowFit.available(in: CGSize(width: 900, height: 600)) == CGSize(width: 900 - 2 * m, height: 600 - 2 * m))
    }

    @Test func windowFrameClampedIntoVisibleFrame() {
        // 13" MacBook Pro default: 1280×800, menu bar 25, Dock 60 → visible 1280×715 at y 60
        let visible = CGRect(x: 0, y: 60, width: 1280, height: 715)
        let big = WindowFit.clamp(CGRect(x: -200, y: -100, width: 1687, height: 983), to: visible)
        #expect(big == visible)
        let moved = WindowFit.clamp(CGRect(x: 1000, y: 700, width: 600, height: 400), to: visible)
        #expect(moved == CGRect(x: 680, y: 375, width: 600, height: 400))
        let inside = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(WindowFit.clamp(inside, to: visible) == inside)
        // second display with a negative origin
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 875)
        #expect(WindowFit.clamp(CGRect(x: -2000, y: 0, width: 1400, height: 420), to: left) == CGRect(x: -1440, y: 0, width: 1400, height: 420))
        #expect(WindowFit.clamp(minSize: CGSize(width: 1100, height: 680), to: CGSize(width: 1024, height: 615)) == CGSize(width: 1024, height: 615))
        #expect(WindowFit.clamp(minSize: CGSize(width: 1100, height: 680), to: visible.size) == CGSize(width: 1100, height: 680))
    }

    @Test func insideCheck() {
        let w = CGSize(width: 900, height: 600)
        #expect(WindowFit.isInside(CGRect(x: 16, y: 16, width: 868, height: 568), window: w))
        #expect(WindowFit.isInside(CGRect(x: 0, y: 0, width: 900.4, height: 600), window: w))
        #expect(!WindowFit.isInside(CGRect(x: 90, y: -31, width: 720, height: 663), window: w))
    }

    @Test func nsWindowFitsItsScreen() throws {
        let screen = try #require(NSScreen.main)
        let v = screen.visibleFrame
        let w = NSWindow(contentRect: NSRect(x: v.minX, y: v.minY, width: v.width + 400, height: v.height + 300),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.minSize = NSSize(width: v.width + 50, height: 100)
        w.fitToScreen(screen)
        #expect(w.frame.width <= v.width + 0.5 && w.frame.height <= v.height + 0.5)
        #expect(v.insetBy(dx: -0.5, dy: -0.5).contains(w.frame))
        #expect(w.minSize.width <= v.width)
    }

    // MARK: Layout

    /// A card taller than the window: `CapLayout` + `scrollsWhenTight` keep it (and its pinned footer) inside.
    @Test func cardNeverTallerThanTheWindow() {
        let space = HostWindowSpace.shared
        let saved = space.size
        defer { space.size = saved }
        space.size = CGSize(width: 900, height: 600)
        let card = VStack(spacing: 0) {
            Color.red.frame(height: 40)
            VStack(spacing: 0) { ForEach(0..<40, id: \.self) { _ in Color.blue.frame(height: 30) } }.scrollsWhenTight()
            Color.green.frame(height: 50)
        }
        .fittedFrame(width: 1200)
        let host = NSHostingView(rootView: card)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        let s = host.fittingSize
        #expect(s.height <= 600 - 2 * WindowFit.margin + 0.5, "card \(s)")
        #expect(s.width <= 900 - 2 * WindowFit.margin + 0.5, "card \(s)")
        // a short card keeps its natural height (no growth to the window's)
        let short = VStack(spacing: 0) { Color.red.frame(height: 40); Color.green.frame(height: 50) }.fittedFrame(width: 300)
        let h2 = NSHostingView(rootView: short)
        #expect(abs(h2.fittingSize.height - 90) < 0.5, "short \(h2.fittingSize)")
        #expect(abs(h2.fittingSize.width - 300) < 0.5)
    }

    // MARK: Every presentation uses the mechanism

    struct Hit: CustomStringConvertible { let file: String; let line: Int; let text: String
        var description: String { "\(file):\(line): \(text)" } }

    static func scan(_ match: (String) -> Bool) throws -> [Hit] {
        var hits: [Hit] = []
        for dir in ["ValseUI", "ValseApp"] {
            let root = sources.appendingPathComponent(dir)
            let e = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in e where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: sources.path + "/", with: "")
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    if match(code) { hits.append(Hit(file: rel, line: i + 1, text: line.trimmingCharacters(in: .whitespaces))) }
                }
            }
        }
        return hits
    }

    @Test func noRawSheetsOrPopovers() throws {
        // SwiftUI sheets size themselves to their content (unbounded): use `.inWindowModal` / an app modal.
        let sheets = try Self.scan { $0.contains(".sheet(") }
        #expect(sheets.isEmpty, "raw .sheet: \(sheets)")
        // popovers go through `.fittedPopover` (WindowFit.swift holds the one raw call)
        let popovers = try Self.scan { $0.contains(".popover(") }.filter { !$0.file.hasSuffix("Support/WindowFit.swift") }
        #expect(popovers.isEmpty, "raw .popover: \(popovers)")
    }

    @Test func windowsAndPanelsAreClampedToTheScreen() throws {
        let makers = try Self.scan { $0.range(of: #"(NSWindow|NSPanel)\(contentRect"#, options: .regularExpression) != nil
            || $0.range(of: #"class \w+: (NSWindow|NSPanel)\b"#, options: .regularExpression) != nil }
        // exempt: the offscreen UI-test window; tooltips (width-capped text, origin kept inside the screen)
        let exempt = ["ValseUI/Testing/", "ValseUI/Support/Tooltips.swift"]
        for file in Set(makers.map(\.file)) where !exempt.contains(where: { file.hasPrefix($0) }) {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("fitToScreen("), "\(file) creates a window without fitToScreen()")
        }
        #expect(!makers.isEmpty)
    }

    @Test func noLargeFixedFrames() throws {
        // a literal size ≥ 600 wide or ≥ 400 high must be an ideal size clamped by `fittedFrame`
        let big = try Self.scan { code in
            guard let r = code.range(of: #"\.frame\(width: *(Self\.size\.width|\d+), *height: *(Self\.size\.height|\d+)\)"#,
                                     options: .regularExpression) else { return false }
            let s = String(code[r])
            if s.contains("Self.size") { return true }
            let n = s.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            return n.count == 2 && (n[0] >= 600 || n[1] >= 400)
        }
        #expect(big.isEmpty, "fixed frames larger than a small window: \(big)")
    }
}
