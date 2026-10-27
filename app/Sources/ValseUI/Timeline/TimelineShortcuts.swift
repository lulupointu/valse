import AppKit
import ValseCore

/// Timeline shortcuts (CapCut bindings, UX.md §8.2), appended to `ShortcutRegistry.builtins`.
@MainActor
enum TimelineShortcuts {
    static let all: [Shortcut] = [
        Shortcut("splitAll", "shortcut.splitAll", .char("b"), [.command, .shift]) { $0.splitAll() },
        Shortcut("selectMode", "shortcut.selectMode", .char("a")) { $0.toggleTool(.select) },
        Shortcut("splitMode", "shortcut.splitMode", .char("b")) { $0.toggleTool(.split) },
        Shortcut("selectLeft", "shortcut.selectLeft", .char("[")) { $0.selectLeftOfPlayhead() },
        Shortcut("selectRight", "shortcut.selectRight", .char("]")) { $0.selectRightOfPlayhead() },
        Shortcut("linkage", "shortcut.linkage", .char("~"), .shift) { $0.setOption(.linkage(!$0.project.timeline.linkage)) },
        Shortcut("linkageBacktick", "shortcut.linkage", .char("`")) { $0.setOption(.linkage(!$0.project.timeline.linkage)) },
        Shortcut("previewAxis", "shortcut.previewAxis", .char("s")) { $0.timelineUI.previewAxis.toggle() },
        Shortcut("toggleClip", "shortcut.toggleClip", .char("v")) { $0.toggleEnabledSelection() },
        Shortcut("extractAudio", "shortcut.extractAudio", .char("s"), [.control, .shift]) { $0.extractOrRestoreAudio() },
        Shortcut("marker", "shortcut.marker", .char("m")) { $0.addMarker() },
        Shortcut("markerColor", "shortcut.markerColor", .char("m"), .option) { $0.addMarker(newColor: true) },
        Shortcut("nextMarker", "shortcut.nextMarker", .char("m"), .shift) { $0.goToMarker(next: true) },
        Shortcut("prevMarker", "shortcut.prevMarker", .char("m"), [.option, .shift]) { $0.goToMarker(next: false) },
        Shortcut("prevCut", "shortcut.prevCut", .up) { $0.goToCut(next: false) },
        Shortcut("nextCut", "shortcut.nextCut", .down) { $0.goToCut(next: true) },
        Shortcut("inPoint", "shortcut.inPoint", .char("i")) { $0.setInPoint() },
        Shortcut("outPoint", "shortcut.outPoint", .char("o")) { $0.setOutPoint() },
        Shortcut("selectByClip", "shortcut.selectByClip", .char("x"), .shift) { $0.rangeFromSelection() },
        Shortcut("group", "shortcut.group", .char("g"), .command) { $0.groupSelection() },
        Shortcut("ungroup", "shortcut.ungroup", .char("g"), [.command, .shift]) { $0.ungroupSelection() },
        Shortcut("compound", "tlmenu.compound", .char("g"), .option) { $0.createCompound() },
        Shortcut("speedPanel", "shortcut.speedPanel", .char("r"), .command) { s in if s.singleSelectedClip != nil { s.inspectorTab = "speed" } },
        Shortcut("zoomFit", "shortcut.zoomFit", .char("z"), .shift) { $0.zoomTimelineToFit() },
        Shortcut("copy", "shortcut.copy", .char("c"), .command) { $0.copySelection() },
        Shortcut("cut", "shortcut.cut", .char("x"), .command) { $0.cutSelection() },
        Shortcut("paste", "shortcut.paste", .char("v"), .command) { $0.paste() },
        Shortcut("duplicate", "shortcut.duplicate", .char("d"), .command) { $0.duplicateSelection() },
        Shortcut("copyAttributes", "shortcut.copyAttributes", .char("c"), [.command, .shift]) { $0.copyAttributes() },
        Shortcut("pasteAttributes", "shortcut.pasteAttributes", .char("v"), [.command, .shift]) { s in
            (SnapshotRegistry.shared.timeline)?.showPasteAttributesDialog()
        },
    ]
}
