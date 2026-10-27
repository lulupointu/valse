import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine
import Perception

// Stickers ▸ Yours ▸ Import (ST-003): still / animated images and Lottie files become custom stickers; 3–49 still
// images can be imported as one frame-sequence sticker (fps 1–50, once / repeat), CapCut's "Import as frame sequence
// stickers". Imported stickers live in `UserStickerLibrary` and behave like built-in stickers.

/// Frame-sequence options asked when several still images are imported.
public struct StickerSequenceOptions: Sendable, Equatable {
    public var fps: Double
    public var loops: Bool
    public init(fps: Double = 12, loops: Bool = true) { self.fps = fps; self.loops = loops }
}

extension EditorStore {
    /// Imports `urls` into the custom sticker library: one sticker per file, or one frame-sequence sticker when
    /// `sequence` is given. Returns the new sticker ids; shows a toast.
    @discardableResult
    public func importStickers(_ urls: [URL], sequence: StickerSequenceOptions? = nil) -> [String] {
        do {
            let ids: [String]
            if let sequence {
                ids = [try UserStickerLibrary.shared.importSequence(urls, fps: sequence.fps, loops: sequence.loops)]
            } else {
                ids = try UserStickerLibrary.shared.importFiles(urls)
            }
            showToast(tr("sticker.import.done", ids.count))
            return ids
        } catch UserStickerLibrary.ImportError.sequenceCount {
            showToast(tr("sticker.import.sequenceCount", UserStickerLibrary.minSequenceFrames, UserStickerLibrary.maxSequenceFrames), error: true)
        } catch {
            showToast(tr("sticker.import.failed"), error: true)
        }
        return []
    }

    /// True when every file is a single-frame still image (candidates for a frame-sequence sticker).
    nonisolated static func areStills(_ urls: [URL]) -> Bool {
        urls.allSatisfy { u in
            guard u.pathExtension.lowercased() != "json", let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return false }
            return CGImageSourceGetCount(src) == 1
        }
    }

    /// Open panel → import (asks "frame sequence or separate stickers" for 3–49 still images).
    func importStickersWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = UserStickerLibrary.importTypes
        panel.message = tr("sticker.import.message")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let n = urls.count
        if n >= UserStickerLibrary.minSequenceFrames, n <= UserStickerLibrary.maxSequenceFrames, Self.areStills(urls) {
            switch askSequence(count: n) {
            case .some(.some(let opts)): importStickers(urls, sequence: opts)
            case .some(.none): importStickers(urls)
            case .none: return
            }
        } else {
            importStickers(urls)
        }
    }

    /// nil = cancelled; .some(nil) = separate stickers; .some(options) = one frame-sequence sticker.
    private func askSequence(count: Int) -> StickerSequenceOptions?? {
        let alert = NSAlert()
        alert.messageText = tr("sticker.import.sequenceTitle")
        alert.informativeText = tr("sticker.import.sequenceInfo", count)
        alert.addButton(withTitle: tr("sticker.import.asSequence"))
        alert.addButton(withTitle: tr("sticker.import.separate"))
        alert.addButton(withTitle: tr("common.cancel"))
        let fps = NSTextField(string: "12")
        fps.frame = NSRect(x: 120, y: 30, width: 60, height: 22)
        let fpsLabel = NSTextField(labelWithString: tr("sticker.import.fps"))
        fpsLabel.frame = NSRect(x: 0, y: 32, width: 116, height: 18)
        let mode = NSPopUpButton(frame: NSRect(x: 116, y: 0, width: 140, height: 24), pullsDown: false)
        mode.addItems(withTitles: [tr("sticker.import.repeat"), tr("sticker.import.once")])
        let modeLabel = NSTextField(labelWithString: tr("sticker.import.playback"))
        modeLabel.frame = NSRect(x: 0, y: 3, width: 116, height: 18)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        [fpsLabel, fps, modeLabel, mode].forEach(box.addSubview)
        alert.accessoryView = box
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let v = min(max(Double(fps.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 12, 1), 50)
            return .some(StickerSequenceOptions(fps: v, loops: mode.indexOfSelectedItem == 0))
        case .alertSecondButtonReturn: return .some(nil)
        default: return nil
        }
    }
}

/// "+ Import" card first in Stickers ▸ Yours.
struct ImportStickerCard: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            Text(loc: "sticker.import").font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? Theme.hoverRing : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .aspectRatio(1, contentMode: .fit)
            .onHover { hover = $0 }
            .help(tr("sticker.import.help"))
        }
    }
}
