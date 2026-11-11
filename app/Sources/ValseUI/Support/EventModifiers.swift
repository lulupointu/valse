import AppKit

/// FLAKY-UI4: the modifier keys of the event being handled (the click's / key's own flags, synthetic events included).
/// Never read `NSEvent.modifierFlags` in an action: it is the hardware keyboard state at this instant, so a key the user
/// holds or releases between the press and the action (or Shift held on the real keyboard while UI tests run on the
/// same Mac) changes what a click / Return does: ⇧ was read as held and Return in the caption search went to the
/// PREVIOUS match (cap_editor_tools "matchIndex 2"). Lint: EventModifiersLintTests.
@MainActor
public enum EventModifiers {
    /// The current event's modifier flags; the hardware state only when no event is being dispatched.
    public static var current: NSEvent.ModifierFlags { NSApp?.currentEvent?.modifierFlags ?? NSEvent.modifierFlags }
}
