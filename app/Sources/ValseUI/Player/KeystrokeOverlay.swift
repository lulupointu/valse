import SwiftUI
import AppKit
import Perception
import ValseCore

/// "Show keystrokes" (PB-015, View menu): the keys pressed in the editor appear as pills over the bottom-left of the
/// preview for ~2 s (for tutorials / screen recordings). Plain typing into text fields is not shown, only combos.
@MainActor @Perceptible
public final class KeystrokeFeed {
    public static let shared = KeystrokeFeed()
    static let defaultsKey = "valse.view.showKeystrokes"

    public struct Item: Identifiable, Equatable { public let id = UUID(); public let text: String; var count = 1 }
    public private(set) var items: [Item] = []
    public private(set) var enabled = false
    /// Seconds a pill stays; nil = 2 s, or 30 s in UI tests (read at push time: the feed may exist before the driver).
    @PerceptionIgnored var lifetimeOverride: TimeInterval?
    var lifetime: TimeInterval { lifetimeOverride ?? (TestAnchors.isEnabled ? 30 : 2) }

    init() {
        if !HomeSandbox.isActive, AppDefaults.store.bool(forKey: Self.defaultsKey) { setEnabled(true) }
    }

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !HomeSandbox.isActive { AppDefaults.store.set(on, forKey: Self.defaultsKey) }
        if !on { items = [] }
    }

    /// Fed by `ShortcutRegistry.handle` (the editor's key path: it sees every key the editor receives, before the
    /// app's monitor consumes it).
    func record(_ e: NSEvent) {
        guard enabled else { return }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        if e.window?.firstResponder is NSText, mods.isEmpty { return }   // typing text
        guard let b = KeyBinding(event: e) else { return }
        push(b.display)
    }

    /// Adds a label (repeats of the last key show "×N").
    func push(_ text: String) {
        if let last = items.last, last.text == text {
            items[items.count - 1].count += 1
        } else {
            items.append(Item(text: text))
            if items.count > 4 { items.removeFirst() }
        }
        let id = items.last!.id, count = items.last!.count
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].count == count else { return }
                withAnimation(.easeOut(duration: 0.2)) { _ = self.items.remove(at: i) }
            }
        }
    }
}

struct KeystrokeOverlay: View {
    @Perception.Bindable var feed: KeystrokeFeed = .shared
    var body: some View {
        WithPerceptionTracking {
            if feed.enabled && !feed.items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(feed.items) { it in
                        WithPerceptionTracking {
                            Text(verbatim: it.count > 1 ? "\(it.text)  ×\(it.count)" : it.text)
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.25), lineWidth: 1))
                                .transition(.opacity)
                        }
                    }
                }
                .padding(12)
                .allowsHitTesting(false)
                .testID("player.keystrokes")
            }
        }
    }
}
