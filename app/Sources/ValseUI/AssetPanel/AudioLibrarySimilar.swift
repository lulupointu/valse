import SwiftUI
import AppKit
import ValseCore
import ValseEngine
import Perception

/// "Similar sounds" (AU-025): nearest neighbours of a library track / sound effect, or of the audio of the selected
/// timeline clip, in the local feature space (`ContentSimilarity`, features pre-computed in the manifest).
@MainActor @Perceptible
final class AudioSimilarState {
    static let shared = AudioSimilarState()
    static let navID = "similar"

    enum Seed: Equatable {
        case item(String)              // ContentItem id
        case clip(ClipID, String)      // clip id, display name
    }

    private(set) var seed: Seed?
    private(set) var seedTitle = ""
    /// Row ids ("lib.<id>") of the matches, best first.
    private(set) var results: [String] = []
    private(set) var kind: ContentItem.Kind = .music
    private(set) var computing = false
    @PerceptionIgnored private var task: Task<Void, Never>?

    func show(item c: ContentItem) {
        task?.cancel()
        seed = .item(c.id)
        seedTitle = AudioLibrarySections.title(c)
        kind = c.kind
        computing = false
        results = ContentSimilarity.similar(to: c, limit: 20, in: c.kind == .music ? ContentLibrary.availableMusic : ContentLibrary.availableSFX)
            .map { AudioLibrarySections.rowID($0.item) }
        open()
    }

    /// Analyses the selected clip's source audio off the main thread (≤ 90 s), then lists the closest items.
    func show(clip: Clip, asset: MediaAsset) {
        task?.cancel()
        seed = .clip(clip.id, asset.name)
        seedTitle = asset.name
        let k = ContentSimilarity.kind(forDuration: clip.sourceRange.duration.seconds)
        kind = k
        results = []
        computing = true
        open()
        let url = asset.url, range = clip.sourceRange
        task = Task {
            let v = await Task.detached(priority: .userInitiated) { try? await ContentSimilarity.features(url: url, range: range) }.value
            guard !Task.isCancelled else { return }
            computing = false
            guard let v else { results = []; return }
            results = ContentSimilarity.similar(toFeatures: v, kind: k, limit: 20,
                                                in: k == .music ? ContentLibrary.availableMusic : ContentLibrary.availableSFX)
                .map { AudioLibrarySections.rowID($0.item) }
        }
    }

    func close() {
        task?.cancel()
        seed = nil; results = []; computing = false
        if AssetPanelState.shared.nav["audio"] == Self.navID { AssetPanelState.shared.nav["audio"] = AudioLibrarySections.defaultNav }
    }

    private func open() {
        AssetPanelState.shared.query["audio"] = nil
        AssetPanelState.shared.nav["audio"] = Self.navID
    }

    var dump: [String: Any] {
        let s: String
        switch seed {
        case .item(let id): s = id
        case .clip(let id, _): s = "clip:\(id)"
        case nil: s = ""
        }
        return ["seed": s, "title": seedTitle, "kind": kind.rawValue, "computing": computing, "results": results]
    }
}

/// Audio ▸ Similar: header "Similar to “X”" (✕ closes) + the matches as regular library rows.
struct AudioSimilarView: View {
    let store: EditorStore
    let sections: [LibrarySection]
    private var state: AudioSimilarState { AudioSimilarState.shared }

    var body: some View {
        WithPerceptionTracking {
            let byID = Dictionary(sections.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text(verbatim: tr("audio.similar.title", state.seedTitle)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if state.computing { ProgressView().controlSize(.small) }
                    IconButton("xmark", help: tr("audio.similar.close")) { state.close() }.testID("audio.similar.close")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                if state.computing {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(loc: "audio.similar.analyzing").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryItemsView(tab: "audio", namespace: "audio",
                                     title: tr(state.kind == .music ? "audio.similar.music" : "audio.similar.sfx"),
                                     items: state.results.compactMap { byID[$0] }, style: .list, empty: tr("audio.similar.none"))
                }
            }
            .testID("audio.similar")
        }
    }
}

/// Audio tab header: "Find sounds similar to the selected clip" while a clip with audio is selected.
struct SimilarToClipBar: View {
    let store: EditorStore

    var body: some View {
        WithPerceptionTracking {
            if let (clip, asset) = selection {
                Button {
                    AudioSimilarState.shared.show(clip: clip, asset: asset)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 11))
                        Text(verbatim: tr("audio.similar.toClip", asset.name)).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.top, 8)
                .testID("audio.similar.clip")
            }
        }
    }

    var selection: (Clip, MediaAsset)? {
        for c in store.selectedClips {
            if let id = c.mediaID, let a = store.project.asset(id), a.hasAudio || a.kind == .audio { return (c, a) }
        }
        return nil
    }
}

// MARK: - "Safe for social media" badge + license card

@MainActor @Perceptible
final class LicenseCardState {
    static let shared = LicenseCardState()
    private(set) var shownID: String?
    func toggle(_ id: String) { shownID = shownID == id ? nil : id }
    func close() { shownID = nil }
}

/// Green ✓ seal next to a library row's title; click opens the license card (the row's popover).
struct SafeForSocialBadge: View {
    let itemID: String
    /// CC BY: amber "Credit" badge (safe for social media once the author is credited).
    var needsCredit = false
    static let green = Theme.success, amber = Theme.warning
    var body: some View {
        WithPerceptionTracking {
            let open = LicenseCardState.shared.shownID == itemID
            let c = needsCredit ? Self.amber : Self.green
            Button { LicenseCardState.shared.toggle(itemID) } label: {
                HStack(spacing: 2) {
                    Image(systemName: needsCredit ? "person.crop.circle.badge.checkmark" : "checkmark.seal.fill").font(.system(size: 10))
                    Text(loc: needsCredit ? "audio.license.creditShort" : "audio.license.safeShort").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(c)
                .padding(.horizontal, 4).frame(height: 15)
                .background(c.opacity(open ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(tr(needsCredit ? "audio.license.creditTitle" : "audio.license.safe"))
            .testID("asset.tile.\(itemID).license")
        }
    }
}

/// License facts of a bundled library item, anchored under its row (popover-style card with an arrow).
struct LicenseCard: View {
    let itemID: String
    let title: String
    let license: LibraryLicense

    var body: some View {
        WithPerceptionTracking {
            let credit = license.credit
            let tint = credit == nil ? SafeForSocialBadge.green : SafeForSocialBadge.amber
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: credit == nil ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark").font(.system(size: 13))
                        .foregroundStyle(tint)
                    Text(loc: credit == nil ? "audio.license.safe" : "audio.license.creditTitle").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    IconButton("xmark", help: tr("audio.similar.close")) { LicenseCardState.shared.close() }
                        .testID("audio.license.close")
                }
                Text(loc: credit == nil ? "audio.license.body" : "audio.license.creditBody").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let credit {
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: credit).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            AppPasteboard.general.clearContents()
                            AppPasteboard.general.setString(credit, forType: .string)
                        } label: {
                            Text(loc: "audio.license.copyCredit").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain).testID("audio.license.copyCredit")
                    }
                    .padding(6)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 3) {
                    row(tr("audio.license.license"), license.licenseName)
                    row(tr("audio.license.author"), license.author)
                    row(tr("audio.license.source"), license.sourceName)
                    ForEach(Array(license.details.enumerated()), id: \.offset) { _, d in WithPerceptionTracking { row(d.0, d.1) } }
                    row(tr("audio.license.retrieved"), license.retrieved)
                }
                HStack(spacing: 10) {
                    link(tr("audio.license.viewLicense"), license.licenseURL)
                    link(tr("audio.license.viewSource"), license.sourcePage)
                }
            }
            .padding(10)
            .background(Theme.menu, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.35), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                // popover arrow pointing at the badge
                Path { p in p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 12, y: 6)) }
                    .fill(Theme.menu).frame(width: 12, height: 6).offset(x: 54, y: -6)
            }
            .testID("audio.license.card")
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: k).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).frame(width: 74, alignment: .leading)
            Text(verbatim: v).font(.system(size: 10.5)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func link(_ title: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            Text(verbatim: title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain).help(url)
    }
}
