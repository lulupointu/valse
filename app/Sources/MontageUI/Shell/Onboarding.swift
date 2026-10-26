import SwiftUI
import Perception
import MontageCore

/// Tutorials & onboarding (PM-016): a first-run walkthrough of the editor — one tip per panel (import → player →
/// edit → timeline → export) shown as a coach card on that panel with Next / Skip, remembered once done; Help ▸ Show
/// editor tips replays it. "What's new" lists the latest features once per version.
@MainActor @Perceptible
public final class Onboarding {
    public static let shared = Onboarding()
    static let seenKey = "montage.onboarding.editorTipsSeen"
    static let whatsNewKey = "montage.onboarding.whatsNewVersion"
    /// Bump when the What's new list changes.
    public static let whatsNewVersion = 1

    public enum Step: Int, CaseIterable, Sendable {
        case importMedia, player, inspector, timeline, export
        var panel: DetachablePanel? {
            switch self {
            case .importMedia: return .assets
            case .player: return .player
            case .inspector: return .inspector
            case .timeline: return .timeline
            case .export: return nil
            }
        }
        var titleKey: String { "tips.\(stepName).title" }
        var bodyKey: String { "tips.\(stepName).body" }
        var stepName: String { String(describing: self) }
    }

    /// Current tip (nil = none showing).
    public private(set) var step: Step?
    public var showsWhatsNew = false

    /// Editor opened: start the walkthrough the first time (never during UI tests unless asked).
    func editorDidAppear() {
        guard !HomeSandbox.isActive, !TestAnchors.isEnabled else { return }
        if !AppDefaults.store.bool(forKey: Self.seenKey) { step = .importMedia; return }
        if AppDefaults.store.integer(forKey: Self.whatsNewKey) < Self.whatsNewVersion { showsWhatsNew = true }
    }

    public func start() { step = .importMedia }

    public func next() {
        guard let s = step else { return }
        if let n = Step(rawValue: s.rawValue + 1) { step = n } else { finish() }
    }

    public func finish() {
        step = nil
        if !HomeSandbox.isActive { AppDefaults.store.set(true, forKey: Self.seenKey) }
    }

    public func closeWhatsNew() {
        showsWhatsNew = false
        if !HomeSandbox.isActive { AppDefaults.store.set(Self.whatsNewVersion, forKey: Self.whatsNewKey) }
    }

    var dump: [String: Any] { ["step": step?.stepName ?? "", "whatsNew": showsWhatsNew] }

    /// What's new entries (localized keys).
    static let whatsNew = ["whatsnew.layouts", "whatsnew.subprojects", "whatsnew.beatSync", "whatsnew.recorder", "whatsnew.detach"]
}

/// Coach card shown on the panel of the current tip.
struct CoachCard: View {
    @Perception.Bindable var onboarding = Onboarding.shared
    let step: Onboarding.Step
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loc: step.titleKey).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.Valse.ink)
                    Spacer()
                    Text(verbatim: "\(step.rawValue + 1)/\(Onboarding.Step.allCases.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Valse.ink.opacity(0.6))
                }
                Text(loc: step.bodyKey).font(.system(size: 12)).foregroundStyle(Theme.Valse.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("tips.skip")) { onboarding.finish() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Valse.ink.opacity(0.65))
                        .testID("tips.skip")
                    Spacer()
                    Button(tr(step == Onboarding.Step.allCases.last ? "tips.done" : "tips.next")) { onboarding.next() }
                        .buttonStyle(AccentButtonStyle())
                        .testID("tips.next")
                }
            }
            .padding(12)
            .frame(width: 280)
            // Valse coach mark: a flat cream card with ink text on a hard teal offset block (zero blur, no soft shadow)
            .background(Theme.Valse.cream, in: RoundedRectangle(cornerRadius: 10))
            .valseHardShadow(Theme.accent, radius: 10, depth: 4)
            .testID("tips.card")
        }
    }
}

/// "What's new" card (once per `whatsNewVersion`).
struct WhatsNewCard: View {
    @Perception.Bindable var onboarding = Onboarding.shared
    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: tr("whatsnew.title"), width: 440, onClose: { onboarding.closeWhatsNew() }) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Onboarding.whatsNew, id: \.self) { k in
                        WithPerceptionTracking {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkle").foregroundStyle(Theme.accent).font(.system(size: 11))
                                Text(loc: k).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    HStack {
                        Button(tr("tips.replay")) { onboarding.closeWhatsNew(); onboarding.start() }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        Spacer()
                        Button(tr("common.ok")) { onboarding.closeWhatsNew() }.buttonStyle(AccentButtonStyle()).testID("whatsnew.ok")
                    }
                }
                .padding(16)
            }
            .testID("whatsnew")
        }
    }
}
