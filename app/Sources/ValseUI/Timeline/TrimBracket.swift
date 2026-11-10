import SwiftUI
import AppKit

/// Trim glyphs: a bracket matching the clip edge being trimmed. The head (left) edge shows "]", the tail (right) edge
/// "[" (NLE convention: the bracket faces away from the media that stays), with a small arrow towards the side the
/// edge moves into. Used by the timeline trim cursor and the toolbar "delete left / right" (trim head / tail) buttons.
enum TrimBracket {}

enum TrimBracketPaths {
    /// The bracket stroke in a unit square (x right, y down); `head` = "]".
    nonisolated static func bracketPath(head: Bool) -> Path {
        var p = Path()
        let x: CGFloat = head ? 0.62 : 0.38, serif: CGFloat = head ? -0.22 : 0.22
        p.move(to: CGPoint(x: x + serif, y: 0.12))
        p.addLine(to: CGPoint(x: x, y: 0.12))
        p.addLine(to: CGPoint(x: x, y: 0.88))
        p.addLine(to: CGPoint(x: x + serif, y: 0.88))
        return p
    }

    /// Arrow from the bracket pointing to the side the trimmed part is (head: left, tail: right).
    nonisolated static func arrowPath(head: Bool) -> Path {
        var p = Path()
        let x0: CGFloat = head ? 0.5 : 0.5
        let dir: CGFloat = head ? -1 : 1
        p.move(to: CGPoint(x: x0 + dir * 0.0, y: 0.5))
        p.addLine(to: CGPoint(x: x0 + dir * 0.38, y: 0.5))
        p.move(to: CGPoint(x: x0 + dir * 0.26, y: 0.4))
        p.addLine(to: CGPoint(x: x0 + dir * 0.38, y: 0.5))
        p.addLine(to: CGPoint(x: x0 + dir * 0.26, y: 0.6))
        return p
    }

}

extension TrimBracket {
    /// Cursors, drawn once; hot spot on the bracket's vertical stroke.
    static let headCursor = cursor(head: true)
    static let tailCursor = cursor(head: false)

    private static func cursor(head: Bool) -> NSCursor {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: true) { r in
            func stroke(_ path: Path, _ color: NSColor, _ width: CGFloat) {
                let t = CGAffineTransform(scaleX: r.width, y: r.height)
                let ns = NSBezierPath()
                path.applying(t).forEach { el in
                    switch el {
                    case .move(let p): ns.move(to: p)
                    case .line(let p): ns.line(to: p)
                    case .closeSubpath: ns.close()
                    default: break
                    }
                }
                ns.lineWidth = width; ns.lineCapStyle = .round; ns.lineJoinStyle = .round
                color.setStroke(); ns.stroke()
            }
            for (c, w) in [(NSColor.black, CGFloat(4.2)), (NSColor.white, CGFloat(2))] {
                // Owner feedback: the cursor brackets are mirrored against the toolbar glyphs (head edge "[", tail edge "]");
                // the arrow still points to the side the edge moves into. The toolbar glyph is unchanged.
                stroke(TrimBracketPaths.bracketPath(head: !head), c, w)
                stroke(TrimBracketPaths.arrowPath(head: head), c, w * 0.8)
            }
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: head ? 8.5 : 13.5, y: 11))
    }
}

/// Toolbar glyph (same drawing as the cursor, without the arrow so it reads at 14 pt next to the SF Symbols).
struct TrimBracketGlyph: View {
    let head: Bool
    var body: some View {
        ZStack {
            TrimShape(head: head, arrow: false).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            TrimShape(head: head, arrow: true).stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 15, height: 15)
    }
}

private struct TrimShape: Shape {
    let head: Bool
    let arrow: Bool
    func path(in rect: CGRect) -> Path {
        let base = arrow ? TrimBracketPaths.arrowPath(head: head) : TrimBracketPaths.bracketPath(head: head)
        return base.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
    }
}
