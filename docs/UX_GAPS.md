# UX gaps: Montage vs CapCut (UX parity review, UXR)

Reviewed build: `main` at c756014 (2026-10-18), debug build. All captures were made offscreen (`--snapshot`, `--player-state`,
`--uitest` scripts); no real input was used. Montage evidence is in [`docs/ux_review/`](ux_review/). CapCut references are in
[`docs/ux/`](ux/). Workstreams follow ARCHITECTURE.md §17 and STATUS.md.

**Priorities.** **P0** blocks a core flow or looks broken. **P1** is noticeably worse than CapCut (an extra click, missing
feedback, missing control, or something that looks unfinished). **P2** is polish.

## Summary

| Workstream | P0 | P1 | P2 | Total |
|---|---|---|---|---|
| W12 Home, project, settings, shell | 1 | 3 | 4 | 8 |
| W13 Asset library | 0 | 3 | 5 | 8 |
| W8 Audio (audio library UI), all fixed (POL-B) | 0 | 1 | 1 | 2 |
| W1 Timeline | 0 | 4 | 5 | 9 |
| W2 Player canvas | 0 | 3 | 5 | 8 |
| W3 Inspector | 0 | 1 | 8 | 9 |
| W5 Transitions & animations | 0 | 2 | 1 | 3 |
| W7 Text, all fixed (POL-B) | 0 | 1 | 2 | 3 |
| W10 AI | 0 | 0 | 2 | 2 |
| W11 Export, all fixed (POL-B) | 0 | 0 | 3 | 3 |
| **Total** | **1** | **18** | **36** | **55** |

**Top items to dispatch first:** W12-1 (home screen), W12-2 (title bar takes 67 pt), W1-1 (effect and filter clips look like
adjustment clips), W13-1 + W2-3 (clicking a card previews nothing), W2-1 (no on-canvas mask), W2-2 (inline text edit, needs
verification), W1-2 (dead Cover button and FR overflow), W3-1 (Adjust footer), W12-3 (no Settings window), W5-1/W5-2/W7-1 (thin
transition and animation content with placeholder tiles).

**What already matches CapCut well:** the panel grid and colour tokens, the inspector anatomy (section headers with checkbox, ↺ and
‹◇›, slider + field + stepper rows, segmented sub-tabs), Video ▸ Basic/Cutout/Mask, Audio ▸ Voice changer grid, Speed ▸ Normal/Curve
presets, HSL rings, colour wheels, the on-canvas bounding box with rotate handle and text ✕, rulers and guides, the Effects, Filters
and Stickers grids, Sound FX list rows, the export dialog (720 pt, sections, live estimate), the clip context menu (richer than
CapCut), "Undo: Split" toasts, delete with linkage, full localization (2,336 keys in en and fr, consistent "vous").

---

## W12: Home, project management, settings, shell (title bar, toasts, menu bar)

**W12-1 · P0 · There is no home screen.**
- CapCut ([02_home](ux/02_home.png), [03](ux/03_home_card_hover.png), [04](ux/04_home_card_menu.png)): the app launches on Home
  with a "New project" hero (one click opens an empty editor) and a project grid (hover `…` → Rename / Duplicate / Delete). Leaving
  the editor shows the toast "Saved to project".
- Montage ([02_empty_editor](ux_review/02_empty_editor.png)): launch opens an "Untitled project" editor. There are no recent
  projects, and the only way to reopen work is File ▸ Open…. Reopening a project, the most common daily flow, has no CapCut
  equivalent.
- Fix: build the home window from UX §2.1 (hero, project grid at 98 pt with hover `…` menu, Trash delete with undo, empty state).
  Add a "Back to home" command and show the "Saved to project" toast when leaving the editor.

**W12-2 · P1 · The title bar is 67 pt tall instead of 36 pt, and the traffic lights sit on a separate strip.**
- CapCut ([15](ux/15_editor_video_selected.png)): a single 36 pt bar holds the traffic lights, "Auto saved: 13:08:45", the
  project name, the icons and Export.
- Montage ([03_titlebar_height](ux_review/03_titlebar_height.png)): the panels start at y = 67 pt (measured from pixels). The
  SwiftUI root in `EditorView` respects the window's title-bar safe area (about 28 pt), and then the 36 pt `TitleBar` is drawn
  below it. This wastes 31 pt of vertical space on every screen, and the autosave text ends up on a different row from the traffic
  lights.
- Fix: add `.ignoresSafeArea(.container, edges: .top)` on the editor stack (or host `TitleBar` in the title-bar area), keep the
  76 pt traffic-light inset, and check in a real window during phase 4.

**W12-3 · P1 · There is no Settings window (⌘,).**
- CapCut ([06](ux/06_settings_project.png)–[09](ux/09_settings_general.png)): a 512 pt modal with Project · Edit · Performance ·
  General tabs (image duration, step frames, proxy, hardware encoding, cache, language).
- Montage: there is no Settings menu item or window. The language can only be changed from a globe menu in the title bar.
  Settings that are already wired elsewhere have no UI: preview quality and proxy persistence (W2 → W12), and hardware encoding
  and the export sound (W11 → W12). These are open in STATUS cross-team requests.
- Fix: build the Settings window from UX §2.5 and connect the keys listed in STATUS.md.

**W12-4 · P1 · There is no shortcut window and no Help menu, and the menu bar is minimal.**
- CapCut ([50_shortcuts_1](ux/50_shortcuts_1.png), [52](ux/52_dialog_discard_confirm.png)): Help ▸ Shortcut and a ⌨ title-bar
  icon open a 720 pt editor with Timeline · Player · Basic · Other tabs and five presets. UX §8.1 also asks for a *richer* Mac menu
  bar (Clip, Timeline, Marker, View) than CapCut's.
- Montage: the menu bar has only File · Edit · View · Window, with about 15 items. There is no Help menu, no shortcut list, and no
  Clip, Timeline or Marker menu. Most commands (freeze, reverse, markers, compound, group…) can be found only in the context menu or
  through a shortcut.
- Fix: add the shortcut editor from UX §8.2, add Help ▸ Keyboard shortcuts, and add Clip, Timeline and Marker menus that mirror
  `ShortcutRegistry`.

**W12-5 · P2 · The title-bar controls differ from CapCut.**
- CapCut ([15](ux/15_editor_video_selected.png)): a layout button with a chevron, a shortcuts ⌨ icon, then Export.
- Montage ([01_editor_overview](ux_review/01_editor_overview.png)): a globe language menu, then Export. Changing the language from
  the title bar is programmer UI.
- Fix: move the language setting to Settings ▸ General, and add the shortcuts icon (and the layout menu when layouts exist).

**W12-6 · P2 · New-project defaults differ from CapCut.**
- CapCut ([10](ux/10_editor_empty.png)): the name is the date as MMDD ("1018", then "1018 (1)"). Details shows Ratio *Original*,
  Resolution *Adapted*, Free layer *Turned on*, and a real save path (autosaved from the start).
- Montage ([02_empty_editor](ux_review/02_empty_editor.png)): the name is "Untitled project", Ratio is "16:9", Resolution is
  "1920×1080", Saved to is "Not saved yet", there's no Free layer row, and the Details panel also shows a Color space picker.
- Fix: use CapCut's defaults (UX §2.2), autosave into a project folder at once, and show Original/Adapted until the first clip sets
  the canvas.

**W12-7 · P2 · ⌘S gives no feedback, and Save / Save As… contradict the autosave model.**
- CapCut: there is no Save command; the title bar shows "Auto saved: HH:MM:SS". UX §2.6 asks for ⌘S to be a no-op that flashes
  "Saved".
- Montage: ⌘S shows no toast (the state dump `ui.toast` stays null), and the File menu has Save and Save As….
- Fix: make ⌘S flash a "Saved" toast, and rename Save As… to "Duplicate project…" or drop it.

**W12-8 · P2 · Toasts have low contrast.**
- CapCut (UX §9): a centred white pill with black 12 pt text.
- Montage ([24_undo_toast](ux_review/24_undo_toast.png)): a `#2E2E2E` pill over the player header, almost the same colour as the
  header strip.
- Fix: `ToastView` should use a white background with black text, a radius-12 pill, and a 2 s fade.

## W13: Asset library (media tab, cards, search, previews)

**W13-1 · P1 · Clicking a media card does nothing (no selection, no preview, no hover scrub).**
- CapCut ([11](ux/11_media_imported.png), [12b](ux/12b_media_card_hover_scrub.png)): click selects the card (2 pt accent border plus
  in/out pill handles) and previews the source in the player ("Previewing — video", playable with Space). Hover scrubs the thumbnail
  with the mouse X position.
- Montage ([06_media_card_click](ux_review/06_media_card_click.png)): after a click there's no border, the player still shows the
  timeline, and the header still reads "Player". In `MediaTab.swift`, a card has only a double-click (add) and a hover ⊕. Hover
  scrub and in/out handles aren't implemented.
- Fix: single click = select plus source preview (needs W2-3). Add hover scrub through `ThumbnailCache`, the selection border, and
  the in/out handles.

**W13-2 · P1 · The media toolbar and card badges are incomplete.**
- CapCut ([11](ux/11_media_imported.png)): a toolbar with `[⊕ Import]`, "Search material", grid/list, sort ▾ and type filter ▾,
  and an "All" caption. Cards are 3:2, with the duration top-right, ⊕ bottom-right, and an "Added" chip once used.
- Montage ([04_assets_tabs_en](ux_review/04_assets_tabs_en.png)): the toolbar has only Import and a new-folder icon. Ocean, Sunset
  and Forest are on the timeline but show no "Added" chip. The duration is bottom-right and the ⊕ top-right, on 16:10 cards.
- Fix: add search, sort and filter, the "Added" chip, and CapCut's badge positions.

**W13-3 · P1 (with W2) · Clicking an effect, filter or sticker card doesn't preview it.**
- CapCut ([70b](ux/70b_effect_after_click.png)): click shows "Previewing — Effects" and loops a 3 s preview over the frame under
  the playhead before anything is added.
- Montage ([07_effect_card_click](ux_review/07_effect_card_click.png)): the card shows ☆/⊕, but the player is unchanged. This is
  the open FX-001 cross-team request.
- Fix: build a shared "library preview" mode in the player (W2-3) and call it from card clicks.

**W13-4 · P2 (with W4) · Card thumbnails appear late and fall back to placeholders.**
- CapCut ([63](ux/63_assets_effects.png), [65](ux/65_assets_filters.png)): thumbnails are present when the tab opens.
- Montage: on first open, Effects and Filters show grey glyph placeholders for more than 1.5 s
  ([05_assets_tabs_fr](ux_review/05_assets_tabs_fr.png)). After a drop, the Filters grid fell back to placeholders again
  ([16](ux_review/16_timeline_effect_filter_colours.png)).
- Fix: keep rendered thumbnails in a disk cache keyed by descriptor and version, and don't evict them when switching tabs.

**W13-5 · P2 · French sub-nav labels are truncated or shrunk.**
- Montage ([05_assets_tabs_fr](ux_review/05_assets_tabs_fr.png)): "Sous-titres aut…" and "Sous-titres loc…" are cut. "Modèle de
  texte" and "Bulles et badges" are drawn in a smaller font (auto-shrink).
- Fix: use shorter labels ("Sous-titres auto", "Importer des sous-titres", "Bulles") or allow two lines in the 120 pt column.

**W13-6 · P2 · French wording is inconsistent across tabs.**
- "Yours" is "Vos fichiers" in Audio but "Les vôtres" in Text.
- The Stickers tab's search says "Rechercher des autocollants".
- The Adjustment card is "Réglages" and its search "Rechercher des réglages" (*réglages* reads as "settings"), under the tab
  "Ajustement".
- Fix: use one term per concept: "Stickers", "Ajustement" / "Ajustement personnalisé", and one translation of "Yours".

**W13-7 · P2 · The Templates tab is an empty "coming soon" page.**
- Montage ([04_assets_tabs_en](ux_review/04_assets_tabs_en.png)): "Templates are coming soon." The TP workstream is still queued.
- Fix: hide the tab until local templates exist, or show the W7 text templates there.

**W13-8 · P2 · The Media sub-nav has no "Yours ▴" group.**
- CapCut: Yours ▴ (Import, Favorites, My presets) · Library ▾.
- Montage: "Import" and "Library" only. Library holds solid colour clips, which is fine.
- Fix: add Favorites for media (☆ on media cards) under a Yours group.

## W8: Audio (audio library UI, `MontageUI/Audio`)

**W8-1 · P1 · The Audio tab shows two sub-nav columns side by side, and imported audio uses grid cards. — FIXED (POL-B)**
- CapCut ([60](ux/60_assets_audio.png)): one 120 pt sub-nav, and **56 pt list rows** with a 40 pt cover, the title, "artist ·
  02:09", ☆ and ⊕.
- Montage ([04_assets_tabs_en](ux_review/04_assets_tabs_en.png)): the outer nav (Yours / Sound FX / Extracted) and the media-bin
  nav (Import / Library) sit side by side, using 240 pt. Imported music shows as a video-style card with a generic waveform glyph.
  Sound FX already uses proper rows ([26](ux_review/26_text_audio_library_panels.png)).
- Fix: use a single nav, and render Yours with the same rows as Sound FX (a waveform image as the cover, ▶ on hover).
- **Fixed (POL-B):** Yours is now its own list (no nested media-bin nav): Import button, 56 pt rows with the file's real waveform as cover, "artist · duration", ▶ on hover / click to preview, ⊕ adds at the playhead, drag to the timeline, Finder drop. UI script `audio_library` (baseline `audio_library_yours`).

**W8-2 · P2 · There's no Music library. — FIXED (POL-B)**
- CapCut: Music ▴ with genres.
- Montage: Yours · Sound FX · Extracted only.
- Fix: ship a small local royalty-free music pack in the same row UI, or hide the concept.
- **Fixed (POL-B):** Audio ▸ Music: 8 procedural royalty-free tracks in 4 genres (Chill, Upbeat, Cinematic, Lo-fi), ~30 s each, synthesized locally on first ▶/⊕ (`MusicLibrary`), same row UI; added media are named after the track. `audio_library` script + `AudioUITests.musicTracksSynthesize`.

## W1: Timeline editing UX

**W1-1 · P1 · Effect and filter clips look exactly like adjustment clips.** — **Fixed** (effect / filter / adjustment layers resolve their lane kind from the first effect (`AdjustmentLanes`), never share a lane, and use the purple / indigo / ochre colours and icons; UI script timeline_lanes_cover)
- CapCut ([86](ux/86_timeline_fit.png), [72](ux/72_effect_clip_added.png)): effects are purple (`#7C5E8C`, ✦), filters indigo
  (`#595493`), and adjustment layers ochre (`#A58744`), each kind on its own lane type.
- Montage ([16](ux_review/16_timeline_effect_filter_colours.png)): the dropped "Shake" effect and "Teal & orange" filter are ochre
  with the same ≡ icon. "Shake" was placed on the lane of the "Warm" filter. In the model, both are `adjustment` clips carrying an
  effect id. `Theme.clipColor` already has effect and filter colours, but nothing uses them.
- Fix: derive the display kind from the clip's first effect category for the colour, icon and track-header icon. Don't mix
  effects, filters and adjustments on one lane.

**W1-2 · P1 · The Cover button is a dead end, and it overflows in French.** — **Fixed** (the Cover button opens a cover editor (frame picker, local image, text layers) stored in `Project.cover` and used by the export; the button sits in the 52 pt gap, is 48 pt wide and fits "Couverture")
- CapCut ([18](ux/18_track_header_main.png)): the 40×36 "Cover" button opens the cover editor.
- Montage ([18_track_header_fr](ux_review/18_track_header_fr.png)): clicking it shows a single disabled "not yet" menu item. In
  French, "Couverture" is wider than the button and runs into the first clip.
- Fix: hide the button until TL-045 lands (or open a frame picker), and fit the label: a smaller font, two lines, or "Couv.".

**W1-3 · P1 · Track headers are cramped and missing ⋯.** — **Fixed** (type icon on every header incl. main, 14 pt icons at 22 pt pitch (aspect-correct glyphs), ⋯ on video/audio tracks, white slashed icon when toggled)
- CapCut ([18](ux/18_track_header_main.png), [90](ux/90_track_more_menu.png)): a type icon, then 🔒 👁 🔊 at 14 pt with 22 pt
  pitch, and ⋯ more (track height, waveform size) at the right.
- Montage ([17_timeline_fit](ux_review/17_timeline_fit.png), [18](ux_review/18_track_header_fr.png)): icons are about 9 pt and grey,
  bunched at the left, with no ⋯. The main track has no type icon, and track height can be changed only from a right-click.
- Fix: follow UX §6.3 (sizes, ⋯ button, a white slashed icon when toggled).

**W1-4 · P1 · The empty timeline doesn't match CapCut's empty state.** — **Fixed** (empty timeline = full-width dashed lane with a film icon and the hint; ruler and headers hidden until the first clip)
- CapCut ([10](ux/10_editor_empty.png)): no ruler and no track header. A full-width **dashed** lane with a film icon and "Drag
  material here and start to create".
- Montage ([02_empty_editor](ux_review/02_empty_editor.png)): a solid-outlined box about 570 pt wide with no icon. The ruler and a
  track header with lock, hide, mute and Cover are already shown.
- Fix: draw the dashed full-width lane with an icon, and hide the ruler and headers until the first clip.

**W1-5 · P2 · Transitions are hard to see on the timeline.** — **Fixed** (⋈ bow-tie glyph, brighter fill and outline on hover)
- CapCut ([96](ux/96_clip_detail_transition.png)): a translucent block with a ⋈ bow-tie icon.
- Montage ([17_timeline_fit](ux_review/17_timeline_fit.png)): a light rectangle with no icon.
- Fix: add the ⋈ glyph and a hover highlight.

**W1-6 · P2 · Keyframe diamonds sit on the clip's bottom edge.** — **Fixed** (diamonds centred on the clip body (hit band too))
- CapCut ([100d](ux/100d_kf_clip_two.png)): 6 pt diamonds centred on the filmstrip.
- Montage ([20_keyframes](ux_review/20_keyframes.png)): the diamonds are on the waveform strip at the bottom edge.
- Fix: centre them vertically on the clip body.

**W1-7 · P2 · The toolbar shows tools that don't apply to the selection.** — **Fixed** (Freeze, Reverse, Mirror, Rotate, Crop and Transcript only show for video / image clips)
- CapCut (UX §8.3): tools that depend on the clip type are hidden when they don't apply.
- Montage ([16](ux_review/16_timeline_effect_filter_colours.png)): with a filter clip selected, Freeze, Reverse, Mirror, Rotate,
  Crop and Transcript still show (some dimmed).
- Fix: hide them for effect, filter, adjustment, text and sticker clips.

**W1-8 · P2 · French clip duration chips use English number format.** — **Fixed** ("4,0 s" in French)
- Montage ([29_editor_fr](ux_review/29_editor_fr.png)): "4.0s", "12.0s".
- Fix: localized decimal and spacing: "4,0 s".

**W1-9 · P2 · The badge for an effect applied to a clip is tiny.** — **Fixed** (17×15 pt ✦ / filter chips next to the name chip)
- CapCut (UX §6.5): small effect and filter icons in the clip's name strip.
- Montage ([27](ux_review/27_fx_adjust_inspectors.png), timeline in the VHS-on-Forest run): a few-pixel glyph in the clip's
  top-right corner.
- Fix: show an 11 pt ✦ chip next to the name chip.

## W2: Player canvas and playback

**W2-1 · P1 · Masks can't be edited on the canvas.** — **Fixed** (dashed outline, corner dots, edge pills, centre cross; drag inside moves; floating rotate / feather / round-corner buttons; shown while Video ▸ Mask is open; `canvas_mask` UI script)
- CapCut ([28](ux/28_player_mask_canvas.png)): a dashed white mask outline with corner and edge handles and a centre cross, plus
  floating round buttons for feather ↕, rotate and round corners. Dragging inside moves the mask.
- Montage ([19_mask_added](ux_review/19_mask_added.png)): after "Add mask", the canvas shows only the clip's bounding box, so the
  mask can be adjusted only with the inspector fields. `CanvasOverlayView` has no mask handles.
- Fix: add a mask handle set to the overlay, using the same geometry as `MaskSettings`.

**W2-2 · P1 (verify) · During inline text editing the text seems to disappear.** — **Fixed** (real: confirmed with `screencapture -l` on an on-screen window — AppKit's inactive-window selection is opaque grey. The editor's layout manager now always paints a translucent blue highlight over the rendered text; `canvas_text_edit` UI script + baseline)
- CapCut ([78](ux/78_text_inline_edit.png)): a double-click selects the text in place with a blue highlight and a caret.
- Montage ([21_player_states](ux_review/21_player_states.png), second tile, `--player-state select=text,edit`): a grey box with no
  visible glyphs. This is an offscreen render of the `NSTextView`, so it needs confirmation in the phase-4 real-input pass. If it's
  real, it's P0 (it breaks "Add text").
- Fix: make the editor transparent, with text in the clip's font, colour and size, and the selection drawn over the rendered text.

**W2-3 · P1 · The player has no source or library preview mode.** — **Fixed** (`PlayerUIState.preview`: "Previewing — Video/Effects/Filters/Stickers" header with ✕, item timecode, Space plays, Esc / canvas click / seek / edit exit; `store.previewMedia/previewEffect/previewSticker/exitPreview`; media, effect, filter and sticker card clicks call it; `player_preview` UI script)
- CapCut (UX §4.1, [70b](ux/70b_effect_after_click.png)): the header changes to "Previewing — video" or "Previewing — Effects",
  the timecode shows the item's own duration, and Space plays it.
- Montage: there's no such state, and no localized string exists for it. W13-1 and W13-3 depend on it.
- Fix: add `PlayerUIState.preview(item)` with its own header title, transport and an exit on Esc or a click elsewhere.

**W2-4 · P2 · The default preview quality shows "High".** — **Fixed** (the automatic default reads "Auto" / "Automatic (recommended)" with its real behaviour in the detail line)
- CapCut ([103](ux/103_player_quality_menu.png)): "Full" by default.
- Montage ([01_editor_overview](ux_review/01_editor_overview.png)): "High" (the automatic default), which reads as a reduced quality.
- Fix: label the automatic default "Auto" or "Full", or default to Full on machines with more than 8 GB.

**W2-5 · P2 · The empty-project player shows a black frame.** — **Fixed** (no frame and a dimmed, disabled transport bar until the first clip; `player_empty` UI script + baseline)
- CapCut ([10](ux/10_editor_empty.png)): no frame, dimmed controls and dimmed counters.
- Montage ([02_empty_editor](ux_review/02_empty_editor.png)): a black 16:9 frame and full-brightness controls.
- Fix: hide the frame and dim the controls while the project is empty.

**W2-6 · P2 · The player ☰ menu has no Color oscilloscope.** — **Fixed** (☰ ▸ Color oscilloscope ▸ Turn off / Luma waveform / RGB parade, drawn bottom-right of the canvas; vectorscope and histogram not done)
- CapCut ([107](ux/107_player_menu.png)): Color oscilloscope ▸ Turn on / Turn off.
- Montage: there's no scope entry (no "scope" string under Player).
- Fix: add a luma waveform or RGB parade overlay, or leave it out deliberately and note that in FEATURES.

**W2-7 · P2 · Text boxes have no edge pills.** — **Fixed** (left/right pills set `TextContent.boxWidth`, the text wraps; `canvas_text_box` UI script)
- CapCut ([75](ux/75_text_on_canvas.png)): pill handles on the edge midpoints change the text box width.
- Montage ([21_player_states](ux_review/21_player_states.png), first tile): corner handles only. TX-011 is in the cross-team list.
- Fix: add the edge pills that set `boxWidth`.

**W2-8 · P2 · The chroma picker uses the system screen sampler.** — **Fixed** (canvas eyedropper `CanvasTool` with a loupe ring; samples the frame with the edited key switched off; Esc cancels; `canvas_eyedropper` UI script)
- CapCut ([125](ux/125_chroma_picker_hover.png)): a loupe ring on the canvas, and the click samples the frame.
- Montage: `NSColorSampler`, a screen-wide magnifier that can also pick colours outside the video.
- Fix: add a canvas eyedropper tool through `PlayerUIState` modal tools, like the cutout brush.

## W3: Inspector panels

**W3-1 · P1 · The Adjust tab has no footer and no Mask sub-tab.** — **Fixed** (footer on every Adjust sub-tab: Apply to all = whole grade + mask on every video/image clip, Save as preset → My presets chips; Adjust ▸ Mask sub-tab with render-tested grading mask; `adjust_footer_mask` UI script)
- CapCut ([32](ux/32_insp_adjust.png), [38](ux/38_insp_adjust_curves.png), [40](ux/40_insp_adjust_mask.png)): a sticky footer with
  `[Apply to all]` `[Save as preset]`, and sub-tabs Basic · HSL · Curves · Color wheel · **Mask**.
- Montage ([10_inspector_adjust](ux_review/10_inspector_adjust.png), [11_inspector_full_height](ux_review/11_inspector_full_height.png),
  full-height capture): no footer at any height, and only four sub-tabs. Applying a grade to every clip takes N times the work.
- Fix: add the footer (reuse `toast.appliedToAll`) and the Mask sub-tab (the same component as Video ▸ Mask).

**W3-2 · P2 · The curves editor differs from CapCut.** — **Fixed** (full-width graphs, endpoints only until edited, eyedropper per channel; `inspector_masks_speed`)
- CapCut ([38](ux/38_insp_adjust_curves.png)): a full-width graph, a diagonal with only its two endpoints, and an eyedropper and
  ↺ per channel.
- Montage ([10](ux_review/10_inspector_adjust.png)): a 220 pt graph that starts with five points (three interior ones) and has no
  eyedropper.
- Fix: make the graph full width, start with endpoints only, and add the eyedropper.

**W3-3 · P2 · Number formats aren't localized, and the speed sign is an "x".** — **Fixed** (`Fmt` formats in the UI language: "0,00°", "1,00×", "5,0 s", "−6,0 dB"; × in English; `inspector_fr_formats` + unit test)
- Montage ([14_inspector_fr_video](ux_review/14_inspector_fr_video.png)): in French, fields show "0.00°", "1.00x", "5.0s",
  "-6.0dB".
- Fix: format through the locale: "0,00°", "1,00×", "5,0 s", "−6,0 dB" (and "×" in English too).

**W3-4 · P2 · The filter and effect slider is called "Intensity".** — **Fixed** ("Strength" in English, "Intensité" in French)
- CapCut (UX §5.5): **Strength** 0–100.
- Montage ([12](ux_review/12_inspector_text_sticker_filter.png), [27](ux_review/27_fx_adjust_inspectors.png)): "Intensity".
- Fix: rename it to "Strength" in English; French can stay "Intensité".

**W3-5 · P2 · An audio clip's Speed tab shows "Smooth slow-mo".** — **Fixed** (video clips only)
- Montage ([13_inspector_audio_multi](ux_review/13_inspector_audio_multi.png)): "Smooth slow-mo (Only applied to slow-mo videos)",
  which doesn't apply to audio.
- Fix: hide it for audio clips.

**W3-6 · P2 · The remembered inspector tab carries over between clip types.** — **Fixed** (last tab remembered per `InspectorSelectionKind`; `inspector_tab_memory`)
- CapCut (UX §9): the inspector remembers the last tab *per clip type*.
- Montage ([12](ux_review/12_inspector_text_sticker_filter.png)): after Text ▸ Tracking, selecting a sticker opens Sticker ▸
  Tracking instead of Stickers.
- Fix: key the remembered tab by `InspectorSelectionKind`.

**W3-7 · P2 · Video ▸ Mask has only 6 shapes.** — **Fixed** (Text and Pen shapes, CPU-rasterized coverage with feather/invert, also in Adjust ▸ Mask; Pen points can't be drawn on the canvas yet, Brush later)
- CapCut ([24](ux/24_insp_video_mask.png)): 9 shapes, including Text, Brush and Pen.
- Montage ([08](ux_review/08_inspector_video_audio.png)): Linear, Mirror, Circle, Rectangle, Heart, Stars.
- Fix: add Text (a glyph outline) and Pen (Bézier); Brush can come later.

**W3-8 · P2 · Some French wording departs from the glossary or is ambiguous.** — **Fixed** ("Modulateur vocal", "Correspondance des couleurs")
- "Changeur de voix" (glossary: "Modulateur vocal").
- Color match is "Ajustement des couleurs", which is easy to confuse with "Ajuster". Prefer "Correspondance des couleurs".
- Evidence: [14](ux_review/14_inspector_fr_video.png), [15](ux_review/15_inspector_fr_text_audio.png).

**W3-9 · P2 · The Speed tab has no Velocity effects sub-tab.** — **Fixed** (8 speed-ramp presets as editable speed curves)
- CapCut ([30](ux/30_insp_speed.png)): Normal · Curve · Velocity effects.
- Montage ([09](ux_review/09_inspector_speed_anim.png)): Normal · Curve.
- Fix: add a preset grid (it can reuse the speed-curve presets plus ramps).

## W5: Transitions and animations content (running)

**W5-1 · P1 · The transition library is nearly empty.**
  *Fixed on the W5 branch: 121 transitions in 12 categories + Trending + Favorites (☆ on hover, shared `EffectFavorites`), search, shader-rendered A→B stills and hover loops (`w5_transitions_tab`).*
- CapCut ([64](ux/64_assets_transitions.png)): Favorites, Trending, and more than 15 categories with hundreds of items, a search
  field, and an A→B demo on hover.
- Montage ([04_assets_tabs_en](ux_review/04_assets_tabs_en.png)): Basic shows two items (Dissolve, Black fade) as static glyph
  tiles, plus Slide, Camera and Shape groups. There's no Favorites, no search and no preview.
- Fix: deliver the W5 content, use the same `EffectLibraryTab` grid as Effects (search, ☆, ⊕), and add rendered A→B thumbnails.

**W5-2 · P1 · There are few video animations, and the tiles are generic glyphs.**
  *Fixed on the W5 branch: 91 In/Out/Combo/Loop presets; tiles show the subject (sample picture / "Abc" / sticker) caught mid-animation and play on hover (`w5_animation_apply`, `w5_animation_text_sticker`). Glyph text tiles (W7) also show a mid-animation still now.*
- CapCut ([31](ux/31_insp_animation.png)): dozens of In, Out and Combo tiles that play the animation on hover.
- Montage ([09_inspector_speed_anim](ux_review/09_inspector_speed_anim.png)): 5 In and 2 Combo, shown as teal icon tiles with no
  preview.
- Fix: add more content and rendered preview loops (at least a rendered still of mid-animation).

**W5-3 · P2 · French animation names are truncated.**
  *Fixed on the W5 branch: shorter French names (no redundant entrant/sortant) and two-line captions on animation tiles (`w5_animation_fr`).*
- Montage ([14](ux_review/14_inspector_fr_video.png)): "Fond…ntrant", "Glisse…haut", "Glisse…droite", "Rotati…trante",
  "Mom…roïque", "Flash…erture".
- Fix: shorter French names ("Fondu", "Vers le haut", "Rotation"…) or two-line captions.

## W7: Text engine and text UI

**W7-1 · P1 · Text animation tiles are "ABC" placeholders. — FIXED (POL-B)**
- CapCut ([129](ux/129_insp_text_animation.png)): the tiles play the per-glyph animation on hover (Typewriter, Cyan Flight…).
- Montage ([12_inspector_text_sticker_filter](ux_review/12_inspector_text_sticker_filter.png)): every glyph animation tile is a
  grey "ABC".
- Fix: render a short loop or a mid-animation still per tile with the text engine.
- **Fixed (POL-B):** Glyph-animation tiles now show "ABC123" rendered by the text engine (`TextRasterizer.animationFrames`: same scene, atlas and per-unit transforms as the GPU pass, painted with Core Graphics): a mid-animation still at rest, the rendered 24-frame loop on hover. UI script `text_animation_tiles` (In / Out / Loop, baseline). Video animation tiles (W5) unchanged.

**W7-2 · P2 · Text effects have generic names. — FIXED (POL-B)**
- CapCut ([121](ux/121_text_effects_grid.png)): named word-art styles.
- Montage ([26](ux_review/26_text_audio_library_panels.png)): "ART" tiles named "Outline 1" … "Outline 12".
- Fix: descriptive names ("Neon outline", "Gold stroke"…).
- **Fixed (POL-B):** Word-art effects get descriptive en/fr names from their recipe ("Yellow stroke", "Pink neon", "Peach outline", "Trait jaune", "Néon rose"…), unique per group; duplicate neon/shadow variants fixed. `TextContentTests.textEffectsHaveDescriptiveUniqueNames`, UI scripts `text_effects_names`, `text_names_fr`.

**W7-3 · P2 · French text animation names are truncated. — FIXED (POL-B)**
- Montage ([15](ux_review/15_inspector_fr_text_audio.png)): "Machi…écrire", "Lettre…fondu", "Lettr…nantes", "Reto…ement".
- Fix: shorter French names.
- **Fixed (POL-B):** Shorter en/fr text animation names ("Dactylo", "Fondu lettres", "Toupie", "Bascule", "Letter fade"…); no truncation in the In / Out / Loop grids. UI script `text_names_fr` (baseline `text_animation_tiles_fr`).

## W10: AI features

**W10-1 · P2 · Text to speech tiles show raw locale codes and repeated names.** — FIXED (W10: grouped by locale, "Français"/"English" chips, Mamie/Papi)
- CapCut ([131](ux/131_insp_text_tts.png)): voice tiles by character name, with category pills.
- Montage ([12](ux_review/12_inspector_text_sticker_filter.png), [15](ux_review/15_inspector_fr_text_audio.png)): tiles say
  "Eddy fr-FR", "Eddy fr-CA", "Eddy en-US". The filter chips read "FR-Français" and "EN-English", and the names (Grandma, Grandpa)
  aren't localized.
- Fix: group by language with a readable caption ("Français (Canada)"), show each name once per language group, and use chips like
  "Français" / "English".

**W10-2 · P2 · The Auto captions panel shows engine internals.** — FIXED (W10: engine card under "Advanced")
- CapCut ([119](ux/119_text_auto_captions.png)): Spoken language, filler words, Generate.
- Montage ([25_auto_captions](ux_review/25_auto_captions.png)): "Speech recognition: Whisper large-v3-turbo · high accuracy" and an
  "Engine" dropdown in the main flow.
- Fix: move the engine choice under an "Advanced" disclosure (Automatic stays the default).

## W11: Export

**W11-1 · P2 · Export size estimate uses the system locale instead of the UI language. — FIXED (POL-B)**
- Montage ([22](ux_review/22_export_dialog.png), [23](ux_review/23_export_dialog_fr.png)): the English UI shows "44,3 MB" on a
  French system, and the French UI says "MB" instead of "Mo".
- Fix: format with the UI locale, and use the localized unit.
- **Fixed (POL-B):** Sizes are formatted in the UI language with localized units ("25.4 MB" / "25,4 Mo") in the dialog footer and the progress view (`ExportFormat.bytes`). UI scripts `export_dialog`, `export_dialog_fr` (`ui.export.dialog.footer`).

**W11-2 · P2 · French labels wrap to two lines in the export dialog. — FIXED (POL-B)**
- Montage ([23_export_dialog_fr](ux_review/23_export_dialog_fr.png)): "Fréquence d'images", "Espace colorimétrique" and
  "Échantillonnage audio" wrap and break the row grid.
- Fix: widen the label column to about 150 pt, or use "Images/s" and "Échantillonnage".
- **Fixed (POL-B):** Label column widened to 142 pt, single line: "Fréquence d'images", "Espace colorimétrique", "Échantillonnage audio" fit. `export_dialog_fr` baseline.

**W11-3 · P2 · "Burn captions into the video" is shown and on without captions. — FIXED (POL-B)**
- Montage ([22](ux_review/22_export_dialog.png)): the toggle is on even though the demo project has no caption track.
- Fix: hide the row (or disable it) when there are no captions.
- **Fixed (POL-B):** The toggle shows only when the project has real caption tracks (`CaptionExport.burnableTrackIDs`); turning it off no longer hides plain titles. `ExportFormatTests.burnInOnlyConcernsRealCaptionTracks`, `ui.export.dialog.burnCaptionsRow`.

---

## Not verified (driver limits): check in the phase-4 real-input pass

These are known W14 driver limits: SwiftUI `.onHover` doesn't fire, and NSMenu/`Menu` popups don't render offscreen.
- Hover visuals: the media card ⊕ on hover (present in code), effect, sticker and animation hover loops, toolbar hover backgrounds
  and tooltips (strings exist, "Split(⌘+B)" style), and the trim cursor.
- Popup menus: the player ☰, quality, ratio, linkage and preview-axis menus, and the clip and keyframe context menus. These were
  reviewed from source (`TimelineMenus.swift`); the clip menu covers all CapCut items plus colour labels.
- Live feedback while dragging: the trim edge frame in the player ([97b](ux/97b_trim_dragging.png)), live speed resize, and snap
  lines while dragging on the canvas. The driver replays only the end state.
- The player zoom bar: with `--player-state zoombar,zoom=1.6` the canvas zooms, but no floating ⊖──●──⊕ bar appeared in the
  snapshot ([21](ux_review/21_player_states.png)).

## How to reproduce

The capture scripts are generated from a small Python helper. They use `project: demo`, `lang: en|fr`, `click` on
`inspector.tab.*` and sub-tab points, `snapshot` on `panel.*`, `drop` effect, filter or transition, ⌘E, and a tall
`size: [1687, 2300]` run for full inspector panels. Player states use `Montage --background --demo --snapshot out.png
--player-state "seek=1,select=text,edit"` (and `rulers`, `zoombar`, `fullscreen`, `canvas=blur,ratio=9:16`). Contact sheets were
built with ImageMagick `montage`.
