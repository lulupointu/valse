import SwiftUI
import AppKit
import MontageCore

/// Multi-line text editor bound to a text clip (Text ▸ Basic text area, the inline canvas editor). Typing is one undo
/// step per burst (gesture coalescing, ends after a short pause or when focus leaves), per-range styles stay attached
/// to their characters (`TextContent.setString`), and the selection is published so style controls can target it.
struct ClipTextEditor: NSViewRepresentable {
    let store: EditorStore
    let clipID: ClipID
    var font: NSFont = .systemFont(ofSize: 13)
    var textColor: NSColor = NSColor(white: 0.92, alpha: 1)
    var alignment: NSTextAlignment = .left
    var focusOnAppear = false
    var onCommit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = false          // the editor's undo stack is the project's
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.alignment = alignment
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.string = context.coordinator.currentString()
        context.coordinator.textView = tv
        if focusOnAppear {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.selectAll(nil)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        let s = context.coordinator.currentString()
        if tv.string != s, !context.coordinator.isTyping {
            let sel = tv.selectedRange()
            tv.string = s
            tv.setSelectedRange(NSRange(location: min(sel.location, (s as NSString).length), length: 0))
        }
        tv.alignment = alignment
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.finishTyping() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClipTextEditor
        weak var textView: NSTextView?
        var isTyping = false
        private var idle: Task<Void, Never>?

        init(_ p: ClipTextEditor) { parent = p }

        func currentString() -> String {
            if case .text(let t) = parent.store.project.timeline.clip(parent.clipID)?.content { return t.string }
            return ""
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            let store = parent.store, id = parent.clipID
            if !isTyping {
                if store.session.isInGesture { store.endGesture() }
                store.beginGesture("cmd.text")
                isTyping = true
            }
            store.updateGesture { p in
                guard var c = p.timeline.clip(id), case .text(var t) = c.content else { return }
                t.setString(s)
                c.content = .text(t)
                if t.template == nil { c.name = s.replacingOccurrences(of: "\n", with: " ") }
                p.timeline[clip: id] = c
            }
            idle?.cancel()
            idle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                self?.finishTyping()
            }
        }

        func finishTyping() {
            idle?.cancel()
            guard isTyping else { return }
            isTyping = false
            parent.store.endGesture()
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = textView else { return }
            let r = tv.selectedRange()
            TextUIState.shared.selection[parent.clipID] = TextSpan(r.location, r.length)
        }

        func textDidEndEditing(_ n: Notification) {
            finishTyping()
            parent.onCommit?()
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                finishTyping(); parent.onCommit?(); return parent.onCommit != nil
            }
            return false
        }
    }
}
