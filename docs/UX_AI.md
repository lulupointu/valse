# Valse UX reference, part 2: CapCut's AI and Pro features

Companion to `docs/UX.md`. It fills the gaps UX.md marked as "not explored": we couldn't run these features live without signing in.
Read UX.md first. This file reuses its tokens, inspector anatomy (§5), timeline anatomy (§6) and glossary (§10).

**Sources (October 2026):**
1. **CapCut for macOS 9.6.0 resources**, read as data, no code run: `Contents/Resources/po/en.po` + `fr-FR.po`, joined by msgid
   (17.5 k strings). Most labels, options, ranges, progress texts, error toasts and mutual exclusions below come from here.
   The msgid keys (`pc_resize_*`, `pc_text_cut_*`…) group strings by feature, which shows which strings sit together in one panel.
   Also read: `lvop_intelligent_crop/` (the auto-reframe dialog, a web plugin: option lists and defaults from `main.js`),
   `matting_config/`, `rnnoise/`, `models/` (on-device model names).
2. **Live observations already in UX.md** (where each AI section lives in the inspector, toolbar buttons, beat menu, export dialog).
3. **Tutorials**: CapCut's own resource pages (capcut.com/resource/…, /desktop/…), a narrated YouTube tutorial transcript
   (gotranscript), third-party guides. They're often vague or out of date, so we only used them for flow order and placement.

**Confidence tags** on every feature/row:
- **[R]** verified in resources: the exact string exists in en.po/fr-FR.po, or the option list is in bundled JSON/JS.
- **[L]** observed live (from UX.md).
- **[T]** from a tutorial / vendor article.
- **[I]** inferred: how CapCut's shared patterns imply it works. Treat it as our design decision if no other source confirms it.

Labels are written `English / Français`. `%1` = placeholder.
Ignore everything about credits, "uses left", Pro paywalls, sign-in, upload consent ("Allow CapCut to upload your media to our server")
and cloud queues ("In line… Estimated 1h+ wait"). Valse runs everything on device and has none of this. We list those strings only
so you know what to drop.

---

## 0. The shared "AI job" pattern (applies to almost every feature below)

CapCut runs every AI process the same way. Valse should build it **once** (a job system + clip-overlay UI) and reuse it everywhere.

| Stage | What the user sees | Example strings (en / fr) | Conf. |
|---|---|---|---|
| Trigger | Ticking a section checkbox in the inspector (`☐ Stabilize`), clicking a tile, or a `[Generate]` / `[Apply]` button. Most sections run **as soon as the box is ticked**: there's no separate Apply. | — | [L][R] |
| Waiting | When another job is already running on that clip/project, the new one waits in a local queue. | "Waiting to be stabilized / En attente de stabilisation", "Waiting for cutout / En attente de découpage", "Waiting to enhance voice... / En attente de l'amélioration de la voix…", "Queued for processing / Dans la file de traitement" | [R] |
| Progress | **Non-blocking.** The clip on the timeline gets a dark translucent overlay with a progress label, e.g. "Applying auto cutout... 37%". You can keep editing other clips. The inspector section shows the same text/spinner. | "Applying auto cutout... %1% / Application en cours du découpage automatique… %1%", "Stabilizing being applied... %1%", "Applying optical flow... %1%", "Isolating voice... %1%", "Applying relight... %1%", "AI removing... %1%" | [R] text, [L] for cutout progress on the clip, [I] overlay styling |
| Cancel | Unticking the checkbox (or Undo) while it runs cancels the job. Some features ask first. A toast confirms. | "Cutout is being applied. Undo cutout? / Découpage en cours d'application. Annuler le découpage ?", "Quit applying vocal isolation?", "Stop generating?", toasts "Video stabilization canceled", "Optical flow canceled", "Auto reframe canceled", "Relight is canceled" | [R] |
| Done | Toast (dark pill, bottom-centre of the player, ~2 s). The clip overlay disappears and the player shows the result. | "Auto cutout completed / Découpage automatique terminé", "Video stabilization completed", "Optical flow applied", "Vocal isolation applied", "Auto reframe applied", "Relight applied", "Customized cutout applied" | [R] |
| Failure | Toast (or inline message in the panel) with the cause and the action; "Try again" only when a retry can work (Valse rule, docs/UX.md §11 "Error messages"; CapCut always says "Try again"). | "Couldn't auto remove background. Try again.", "Couldn't stabilize video. Try again.", "Couldn't apply auto reframe. Try again later." | [R] |
| Undo/redo | Each application is one named undo step. | "Undo: AI expand / Annuler : développement par l'IA", "Undo: Keep vocal", "Redo: Remove vocal", "Color match: %1", "Auto adjust：%1" | [R] |
| Export guard | Export is blocked, or waits, while jobs are running. | "Can't export. Some features are being applied. / Exportation impossible. Certaines fonctionnalités sont en cours d'application.", "You can export after the relight is completed", during export: "Removing background and stabilizing..." / "Stabilizing..." | [R] |
| Mutual exclusion | Features that rewrite geometry exclude each other. A confirm dialog lists what will be removed. | "%1 and %2 applied to your video will be removed if you apply auto reframe.", "Auto reframe will be removed if you turn on stabilize.", "Auto reframe will be removed if you crop the video." | [R] |
| Can't apply | Disabled with a toast for unsupported inputs: compound clips, reversed clips, templates, AI avatars, images, library music, clips that are too long. | "Can't apply vocal isolation to compound clips", "…to reversed clips", "Clips need to be within %1 minutes to apply vocal isolation", "Keep the clip within 30 minutes" (enhance quality) | [R] |
| Concurrency | "Can't apply. The clip is being expanded.", "Can't expand. Another feature is being applied." **One heavy job per clip at a time.** Different clips can run in parallel or queue. | | [R] |
| Long jobs | Some panels offer **Minimize / Réduire** ("Expanding may take a while. You can tap "Minimize" to continue editing this project.") or **Run in background / Exécuter en arrière-plan** (audio translator). | | [R] |
| Privacy prompt (first use, face/body features) | "Allow CapCut to recognize your facial and body features for retouching?" + "Your media won't be uploaded to our server." `[Allow]` | | [R] (Valse: show a one-time, local-only notice, or nothing at all) |

**Result storage model** [I, consistent with all strings]: the AI result is a **cached derived asset attached to the clip**
(matte sequence, stabilized transform track, interpolated frames, separated stem…). The clip keeps its identity, trims and keyframes.
Unticking the section hides the result instantly, and ticking it again reuses the cache ("The applied optical flow result won't be removed").
Nothing new appears on the timeline unless the feature says otherwise (captions, TTS, separated audio, shorts).

**Valse requirements derived from this:**
- A per-clip job badge/overlay with % on the timeline, plus the same status in the inspector section header.
- Cancel by unticking or ⌘Z.
- Results cached on disk by (source hash, params), so re-ticking is instant.
- An export pre-flight that waits for pending jobs (with a progress dialog) instead of refusing.

---

## 1. Captions (Text tab ▸ Auto captions), [R] labels, [L] location

### 1.1 Where
- Asset panel ▸ **Text** tab ▸ left sub-nav **Auto captions / Légendes automatiques** [L]. Mirrors: the Text tab's empty-state card,
  "Smart suggestions ▸ Add captions" (§13), right-click on a clip ▸ **Generate captions / Générer les légendes** (an assignable shortcut,
  UX.md §8.2) [L][R], and the toolbar **Transcript** panel ▸ "Generate captions" (§2) [R].
- Sibling sub-nav item **Local captions / Sous-titres locaux** imports SRT/LRC/ASS ("Supported file formats: SRT, LRC, and ASS.", max **3 MB**:
  "Couldn't import file. File needs to be no more than 3MB.", one file at a time) [R].

### 1.2 Panel content (top to bottom) [R]
Header hint: "Recognize speech in the video to generate captions automatically. / Reconnaître la voix dans la vidéo pour générer
automatiquement les sous-titres."

| Control | en / fr | Values |
|---|---|---|
| Spoken language dropdown | **Spoken language / Langue source** | **Auto detect / Détection automatique** (default), then a list of languages, each shown in English plus its own name (e.g. "Swedish · Svenska"). CapCut supports 17+ main languages plus ~25 extra (Azerbaijani, Bulgarian, Czech, Danish, Finnish, Greek, Hausa, Hebrew, Hungarian, Kannada, Khmer, Kurdish, Malayalam, Marathi, Nepali, Norwegian, Pashto, Punjabi, Sindhi, Swahili, Swedish, Tamil, Telugu, Ukrainian, Urdu, Zulu). |
| Checkbox | **Identify filler words / Identifier les tics de langage** (Pro) | Off by default. When on, fillers are tagged in the captions and in the transcript. |
| Bilingual toggle | **Bilingual captions / Légendes bilingues** → **Translate to / Langue cible pour la traduction** dropdown | Off. Disabled with the hint "Can't generate bilingual captions when "Remove filler words" is selected". |
| Caption template row | **Templates / Modèles** ("Apply templates and generate captions / Appliquer des modèles et générer des légendes") | Optional style chosen before generating. |
| Track selector (when there are several audio sources) | "Select the track below to generate captions / Sélectionne la piste ci-dessous pour générer les sous-titres" | Options [I from strings "All tracks / Toutes les pistes", "Main track / Piste principale", "Voiceover / Voix off"]: All tracks, Main track, a specific audio/voiceover track. |
| Checkbox (only when captions already exist) | **Delete current captions / Supprimer les légendes actuelles** | Default on [I]. Replaces the existing auto captions. |
| Primary button (accent, full width) | **Generate / Générer** | |
| Secondary | **Auto lyrics / Paroles automatiques** + **Lyrics language / Langue des paroles** | For songs. "Voice not detected. To generate lyrics from music, tap "Auto lyrics."" |

Click count: Text tab → Auto captions → (optional language) → Generate = **3** (2 with auto-detect) [L].

### 1.3 Progress and result
- Progress: a blocking overlay over the editor: "Generating captions... / Génération en cours des légendes…", then
  "Splitting captions... / Division en cours des légendes…", then "Adding caption clips. Do not take any actions. / Ajout des clips de
  sous-titres. N'effectue aucune action." [R]. **This is the one AI flow that blocks the UI in CapCut.** For Valse: show a modal sheet with
  progress and **Cancel** (our ASR runs locally and may take longer). Keep it non-blocking if we can insert atomically at the end.
- Result [L][R]: a new **caption track** of text clips (one clip per caption, each ≤2 lines, "One piece of caption can be divided into at most
  two lines") placed above the main track and **linked to the source clips**. Toast "Captions added / Légendes ajoutées". Captions get the
  default caption style, or the chosen template.
- Errors: "Couldn't add captions. No speech in your video. / Impossible d'ajouter des légendes. Aucun discours dans ta vidéo." [R]
- Regenerating: "Generate captions again? / Souhaites-tu générer à nouveau des légendes ?" ("This will remove your existing captions and
  regenerate them using the same style and template.") [R]

### 1.4 Caption inspector (selecting any caption clip) [R][L]
> **C4 (owner screenshots 2026-10-19, current CapCut):** tabs **Captions | Text | Animation | Tracking | Text to speech**; the Captions list
> is a search field + tools, then **numbered rows of text only** (edited in place) with hover **＋** (add a caption after) and **🗑**
> (delete) — no timing fields (timing is done on the timeline). **Text** has sub-tabs **Basic | Templates | Bubble | Effects**: caption
> templates live in Templates, and Basic starts with **☑ Apply to all main captions** (on by default: a style edit restyles every caption
> of the track). The Captions tab and the asset panel moved: see UX.md §3.1.

The inspector header gets a **Captions / Légendes** tab next to Text, Animation, Text to speech. It lists all captions:
- One row per caption: index number + timestamps + editable text. **Click a row → the playhead jumps there.**
  Shortcuts (from the in-app tip, exact text): *"Double-click the number to play from the caption · Split a caption: Enter · Exit editing:
  place cursor at the start or end of caption and press Enter · Start a new line: Command + Enter · Merge up: place cursor at the start of
  caption and press Delete · Merge down: place cursor at the end of caption and press Fn + Delete"*. Errors: "Can't merge here",
  "Can't split here".
- Top bar: **Find / Rechercher** (find & replace), select all, **Highlight keywords / Mettre en évidence les mots-clés** (Pro: auto picks
  keywords; "Highlight keywords automatically?", `[Highlight]`, `Clear all`; "This will overwrite your selected keywords."),
  **Identify filler words** / **Remove filler words / Supprimer les tics de langage** (when filler mode is on, captions shortcuts,
  find/replace and bilingual are disabled, with the toasts quoted above).
- Bilingual: **Bilingual / Bilingues** vs **Translation only / Version traduite uniquement**, **Translated language / Langue cible**,
  "Translating... / Traduction en cours…", and **Apply to all main captions / Appliquer à toutes les légendes principales**, **Apply to all sub
  captions** (main/sub styles). "Update sub captions and AI emojis?" appears after you edit main captions.
- **Apply to all captions / Appliquer à toutes les légendes** for style changes, and **Captions line wrap / Renvoi à la ligne des sous-titres**.
- Editing text in a row updates the clip live ("Captions updated / Légendes mises à jour").
- **AI emojis**: "Let AI add emojis to your captions…". Works only on auto-generated captions ("AI emojis can only be applied to
  auto-generated captions").

### 1.5 Caption templates (karaoke) [R]
Under Text ▸ caption template or the template row. Arrangement: **Word by word / Mot par mot**, **Line by line / Ligne par ligne**,
**Whole screen / Écran entier**. **Words per line / Nombre de mots par ligne**, **Lines per screen / Nombre de lignes par écran**,
**No limit**. Animation states: **Spoken word / Mot prononcé**, **Unspoken word**, **Spoken line / Ligne prononcée**, **Unspoken line**,
**Keyword / Mot-clé** (each with its own style; e.g. "Unspoken captions ▸ Opacity"). Keyword emphasis: **Special emphasis style**,
**Separate lines for keywords**, **Separate screens for keywords**. Valse needs **word-level timestamps** for all of this.

### 1.6 Export captions [L][R]
Export dialog ▸ ☐ **Caption exporting / Exportation de sous-titres** → Format SRT/TXT. Toasts: "Captions exported", "Couldn't export captions".

### 1.7 Script → captions [R]
Text ▸ **Enter text / Saisis du texte** ("Text will automatically be split into captions.") → **Split into captions / Diviser en légendes**.
Also "Convert scripts into captions". Errors: "Couldn't split text to captions", "Captions will be cut off if scripts are not split."
Buttons: **Split and add / Diviser et ajouter**, **Add without split / Ajouter sans diviser**.

---

## 2. Transcript-based editing (Transcript), [R] labels, [T] flow

### 2.1 Where
- Timeline toolbar button **Transcript / Transcription** (visible when a clip is selected) [L]. Its tooltip is "Transcript-based editing /
  Édition basée sur la transcription" [R][T]. **Valse (C4)**: always visible — the transcript is global (every main-track clip with
  sound), no selection needed; the panel says whether it is up to date ("Out of date — timeline changed · Update", incremental) and its
  main action is **Remove filler words** (scope: everywhere, or the selected clips), whose review UI is shared with Captions ▸ Filler
  words. Apply style = Settings ▸ Edit ▸ Labs (Instant / Review list / Inline), see STATUS.md C4.
- Also: menu ▸ Layout ▸ "Transcript-based editing" (a layout mode) [T].
- It opens as a **panel that replaces the asset panel on the left** [T]. Close it with ✕ ("Hide the window of transcript-based editing") [R][T].

### 2.2 Flow
1. Select a clip → **Transcript**. If there's no transcript yet, an empty state shows: "Edit your video as easily as you edit text." /
   "Transcribe the speech in your video. You can delete, copy, or paste parts of your video by editing its transcript.", plus a
   **Select language / Sélectionner la langue** dropdown and an accent **Transcribe / Transcrire** button [R].
2. Progress: in the panel, "Transcribing... %1% / Transcription en cours… %1%" [R], non-blocking [I].
3. Result: paragraphs ("Paragraph %1 / Paragraphe %1"). **Pauses are inline grey chips with their length, e.g. "2.40s"** [T].
   Fillers are tagged **Filler / Tic de langage**, **Hesitation / Hésitation**, **Repetition / Répétition** [R].
4. Edit:
   - Select words → **Delete** (or ⌫). The matching media is ripple-deleted from the main track; the timeline shortens live. Deleted text stays visible
     but struck through, unless you choose **Hide deleted text / Masquer le texte supprimé** (toggle with **Show deleted text**) [R][T].
   - Click a struck-through span → **Restore / Restaurer** [R][T].
   - Right-click a selection: **Copy / Cut / Paste** (moves media), **Mark as / Marquer comme** (Filler/Pause/Repetition), **Unmark / Retirer le
     marquage**, **Add overlay / Ajouter une superposition**, **Add text template**, **Save as new clip / Enregistrer comme nouveau clip**,
     **Overdub / Repiquer** (cloud) [R].
   - Click any word → the playhead seeks there. During playback the current word is highlighted [T].
   - **Search / Rechercher** box with "%1 results found" and **Previous/Next** [R].
5. Bulk clean-up, **Remove filler words / Supprimer les tics de langage** (Pro) [R]:
   - Options: **Pause, repeat, and hesitation / Pause, répétition et hésitation** as categories (Pauses, Repetition, Hesitation) and
     **Minimum pause duration / Durée minimale de mise en pause** (a field in seconds; ad-maker variant: "Detect pauses over").
   - Progress: "Identifying filler words... / Identification des tics de langage…".
   - Button **Delete %s / Supprimer %s** (count), result "Filler words removed / Tics de langage supprimés" ("The corresponding section of
     your video has been deleted.").
   - Empty results: "No filler words identified", "No pauses identified".
6. **Re-transcribe / Retranscrire** after timeline edits ("Update the transcript."). **Generate captions** turns the transcript into captions:
   "The changes in the transcript will be synced with the captions." [R]

### 2.3 Constraints [R]
- The main-track magnet is forced on: "Main track magnet can't be turned off when using transcript-based editing".
- Only main-track clips: "No video clip in the main track. Add clips to the main track and transcribe again."
- Max **2 h**: "Can't transcribe clips longer than 2 hours".
- No speech: "No speech in your video."

---

## 3. Cutout / background removal (Video ▸ Remove BG), [L] location, [R] labels

Inspector ▸ Video ▸ sub-tab **Cutout / Découpage** (newer builds label the section **Remove BG / Supprimer l'arrière-plan**). It has three
checkbox sections, and they're mutually exclusive (ticking one unticks the others) [L][I].

### 3.1 Auto removal / Suppression automatique ("Auto cutout / Découpage automatique")
- 1 click: tick the box. The job starts at once.
- Progress on the timeline clip: "Applying auto cutout... %1%" [R][L], non-blocking. Unticking (or ⌘Z) mid-way asks "Cutout is being
  applied. Undo cutout?" [R].
- Done toast "Auto cutout completed" [R]. The player shows the subject over the layers below, or over the canvas background on the main track.
- Refinement controls under the section once applied [R]: **Clean up edge / Nettoyer le bord** (0–100), **Feather edge / Adoucir le bord**
  (0–100), **Expand / Développer** (edge dilate/erode, bipolar) [R key `auto_remove_expand`]. There's also a **Stroke / Trait** preset row
  (cutout outline styles; "More cutout strokes are available now"). Strokes need a cutout ("Can't add stroke. Remove the background and try again.") [R].
- Model: the video-matting models in `matting_config` (`tt_matting_video`, a GRU temporal variant, saliency fallback). It runs **on device** in
  CapCut too [R].
- Result on the timeline: the same clip, no new track [I]. The clip shows a small cutout badge [I].

### 3.2 Custom removal / Suppression personnalisée ("Customized cutout")
- Tick → the canvas enters brush mode. Tools: **Quick brush / Brosse rapide** (smart, SAM-like click/brush), **Brush / Pinceau**,
  **Eraser / Gomme**, **Size / Taille** slider [R].
- Flow [R][I]: paint over the subject on the current frame → **Apply / Appliquer** → the selection propagates through the clip: "Applying
  customized cutout %1%" → "Customized cutout applied". `[Cancel]` (key `cancel_customized_cutout`).
- Applying auto reframe removes it: "Customized cutout in your videos will be removed if you apply auto reframe." [R]

### 3.3 Chroma key
See UX.md §7 (live-verified). "*Pick color of the photo, and then adjust brightness" [R].

### 3.4 Magic cutout (effect) [R]
"✨Magic cutout" is a video effect: select the subject, then ✓ to apply ("Select & tap ✓ to apply. It may take a moment."). Progress "Your effect
is %1% ready. Hang tight!" with **Keep generating / Discard**. Duration %1–%2 s. Cloud. P2 for Valse.

**Valse:** Vision person segmentation gives a live preview while the full-quality matte job runs. Click count stays **3** (select → Cutout → tick).

---

## 4. Video ▸ Basic: AI enhancement toggles

All of these are checkbox sections in Video ▸ Basic, under Blend [L]. Each follows §0.

### 4.1 Stabilize / Stabiliser [L][R]
- ☐ Stabilize → **Stabilize level / Niveau de stabilisation** dropdown: **Minimal cropping / Recadrage minimal** · **Recommended / Recommandé**
  (default) · **Most stable / Le plus stable** [R] (UX.md's live "Least cut" = Minimal cropping).
- Progress "Stabilizing being applied... %1%", waiting state "Waiting to be stabilized", done "Video stabilization completed",
  canceled "Video stabilization canceled". Changing the level re-runs it ("The stabilized effect switched") [R].
- Excludes auto reframe, both ways [R].
- "Stabilize is turned on automatically" appears when some other feature (camera tracking, smart suggestions) needs it [R].
- Result: the same clip, slightly zoomed/cropped [I].

### 4.2 Enhance quality / Améliorer la qualité [L][R]
- ☐ Enhance quality → **HD / UHD** segmented ("HD makes videos clearer and more natural. UHD provides more precise and vivid details.") [R].
- Clip ≤ **30 min** [R]. "Waiting to enhance image quality" → "Applying enhancing image quality" [R]. CapCut runs it in the cloud for images.
- Export variant: **AI ultra HD / UHD par l'IA** switch in the Export dialog, "Exporting in ultra HD..." [R].

### 4.3 Reduce image noise / Réduire le bruit de l'image [L][R]
- ☐ Noise reduction (video). A level selector [I: **Weak / Faible**, **Strong / Fort** exist as `pc_new_basic_weak_n/strong_n` next to
  `pc_new_basic_level` "Level"]. Toasts "Noise reduction canceled".

### 4.4 Remove flickers / Supprimer les scintillements [R]
- ☐ Remove flickers → mode: **Flashlight / Lampe de poche** (artificial light flicker) · **Time-lapse / Accéléré** [R]; possibly a
  **Level** setting [I].
- Progress "Applying removing video flickers", "Waiting to remove flickers", done "Video flickers removed", error "Couldn't apply removing
  video flickers. Try again." [R]

### 4.5 Optical flow / smooth slow-mo [L][R]
Two entry points:
- **Speed ▸ Normal ▸ ☐ Smooth slow-mo / Ralenti fluide**: only when speed < 1× ("Smooth slow-mo can only be applied in slow speed videos").
  Method dropdown: **Frame blending / Fusion d'images** · **Optical flow / Flux optique** ("Longer time, better quality / Durée plus longue,
  meilleure qualité"). Fallback toast: "Can't use optical flow on your device. You can try frame blending." [R]
- **Video ▸ Basic ▸ ☐ Optical flow** = frame-rate up-conversion ("Make video playback smoother. Match your project's frame rate to the export
  setting for smoother playback."), with **Apply to all** ("Turn it on to apply optical flow to all clips"). It asks "Change frame rate for this
  project? Change the project's frame rate to preview the optical flow result." `[Change]`. It's disabled with "Your video already has enough
  frames." or "Can't turn it on. The frame rate is too low." [R]
- Progress "Applying optical flow... %1%", done "Optical flow applied" / "Smooth slow-mo applied" [R]. Bundled models `interpolation`,
  `umvfi` [R].

### 4.6 Motion blur [L][R]
☐ Motion blur: blur amount, blend, direction [L]. "Applying motion blur... %1", "Motion blur applied" [R]. Only one clip at a time ("To apply
motion blur to multiple clips, create a compound clip"). "Choosing multiple times will apply motion blur multiple times… You can't preview
the effect on the current interface." [R]

### 4.7 Auto reframe / Recadrage automatique [L][R]
**A) Per clip (Video ▸ Basic ▸ ☐ Auto reframe):**
- Controls [R from `lvop_intelligent_crop/main.js` + po]: **Aspect ratio / Format**: Original · 9:16 · 16:9 · 1:1 · 4:3 · 3:4 · 2.35:1.
  **Camera moving speed / Vitesse déplacement caméra**: **Slow / Lent** · **Default / Par défaut** (default) · **Fast / Rapide**.
  **Image stabilization / Stabilisation de l'image**: **Flexible** · **Default** · **Stable**.
- Tick → confirm when it conflicts ("Apply auto reframe? Stabilize and crop applied to your video will be removed…", or crop / camera
  tracking / AI movement / customized cutout) → "Applying auto reframe... %1" → "Auto reframe applied" [R].
- Afterwards: "Adjust the frame position for a specific frame when video is paused" [R]. You drag the crop box in the player to correct it,
  which creates a correction keyframe [I].
- It changes the **project canvas ratio** to the target (the export shows "9:16 (auto-reframe)") [R].

**B) Standalone dialog** (`SmartCrop` plugin, `ui.type: dialog`) [R]: opened from the home screen / the tools list. **Import only 1 video at a time**,
the same three options plus **Frame size / Taille du cadre**, a preview with a timebar, **Import again**, and **Export video**
("Video exported"). Valse can skip this and use path A.

Clicks (A): select → Video ▸ Basic → tick → pick ratio = **4**.

### 4.8 Camera tracking / Suivi de la caméra ("Lens lock") [R]
☐ Camera tracking → target **Face / Visage** · **Body / Corps** · **Hand / Main** (+ a custom box) [R]; **Keep face size / Keep body size /
Keep face/body/hands size** toggle; canvas fill **Fit canvas / Adaptation à la zone de travail** · **Blur canvas / Floutage de zone**.
"Tap Edit to apply camera tracking effect", "Applying camera tracking effect...". It needs people ("Try a video with people in it"), and it
excludes auto reframe [R].

### 4.9 AI movement / Mouvement par l'IA [R]
☐ AI movement → presets **Dynamic / Dynamique** · **Soft / Doux** · **Shake / Secouer** · **Zoom / Zoomer** (+ scale [I]). It excludes auto
reframe: "Auto reframe will be removed if you apply AI movement." Local Ken-Burns in Valse.

### 4.10 Relight / Ajout de lumière [L][R]
☐ Relight section (it also appears under "AI tools / Outils IA"):
- Presets row: **Facial / Faciale** · **Object / Objet** · **Ambient / Ambiante** · **Creative / Créatif** · **Custom / Personnalisé** + saved
  **Relight presets** (max **50**: "You can add up to 50 relight presets") [R].
- Target **People / Personnes** · **Background / Arrière-plan** · **Both / Les deux** [R].
- **Lights / Éclairages** list, "Light %1"; per light: **Type** = **Point / Ponctuelle** · **Directional / Directionnelle**; **Color**,
  **Brightness**, **Intensity**, **Radius / Rayon**, **Distance**, **Highlights**; animation **Moving speed / Vitesse de déplacement**,
  **Blinking / Vitesse de clignotement**, **Color changing / Changement de couleur** (+ **Changing speed**) [R].
  You position a light by dragging its handle on the canvas [I].
- "Applying relight... %1%" (the depth/normal pass runs once; slider changes after that are real-time) [R+I].
- Errors: "Couldn't apply relight to GIF file", "Update the graphic card driver…" [R].

### 4.11 AI remove / AI remix / AI expand [L][R]
- **AI remove / Suppression par l'IA**: brush (**Brush to select**, **Size**, **Erase**), optional prompt "Describe what you want to remove", `[Remove]`.
  Video duration limited to %1–%2 s. "AI removing... %1%", "Estimated time left: %1:%2". Pick a result ("Select a result you like") →
  **Apply** → "Result applied" [R]. A tutorial also mentions Quick/Custom brush [T]. **Valse: P1, local LaMa per frame.**
- **AI remix**: brush + prompt "Examples: brown hair, light blue dress…" → Generate → results. Cloud, P2.
- **AI expand**: "AI expanding... %1%", **Minimize**, "Expand further", "Edit expanded area". Cloud, P2.

### 4.12 Color: Auto adjust, Color match, Color correction (Adjust ▸ Basic) [L][R]
- **☐ Auto adjust / Ajustement automatique**: one tick plus a strength slider [L]. Undo label "Auto adjust：%1" [R].
- **☐ Color match / Ajustement des couleurs** ("Apply the color theme from the source photo to clips"): **Source / Source** = **Select source
  frame / Sélectionner le cadre source** (swipe the timeline/filmstrip: "Swipe to select a frame to match the color") or **import an image**
  ("Select a frame or import an image to apply its colors to any clip.") → **Apply / Appliquer** → "Matching colors..." [R]; then a strength
  slider [I]. It can't use Pro materials [R].
- **☐ Color correction / Correction des couleurs** ("Correct colors in one click") plus strength [R][I]. Multicam has a variant: "Automatically correct
  colors in each camera's footage for a consistent look." [R]
- These are all statistical, so Valse needs no ML. Results are parameter changes, and they stay editable.

---

## 5. Retouch (Video ▸ Enhance / "Retouch"), [L] location, [R] labels

Inspector ▸ Video ▸ **Enhance / Améliorer** (also labelled **Retouch / Retouche**). Pill tabs **Face · Body · Hair · Face presets · Body presets** [L][R].
First use triggers the face/body permission prompt (§0).

- **Auto styles / Styles Automatique**: a grid of one-tap looks combining **Retouch + Reshape + Makeup** parameters, with an intensity slider
  [R]. A spinner shows while it loads [L].
- **Face**: mode **Single face / Un seul visage** (click a face on the canvas: "Select a person first") · **Multiple faces / Plusieurs visages** (all faces) [R].
  Limit toast "Number of faces exceeds limit" [R]. "Face not detected" [R].
  - **Skin / Peau**: **Smooth / Lisser**, **Plump / Potelé**, **Even** (skin even), **Clear blemishes / Imperfections claires**,
    **Sparkly skin**, **Brighten / Illuminer** (= whitening), **Skin tone / Couleur de peau**, **Tan / Bronzage**, **Teeth / Dents** (whitening)
    [R][L]. All 0–100, default 0 [L].
  - **Face / Visage** reshape: **Thin face / Visage fin**, **V shape / Forme en V**, **Width / Largeur**, **Jawline / Menton**, **Chin length**,
    **Upper face / Midface / Lower face**, eyes (**Size, Height, Distance, Inner corners**, tilt), **Eyebrows** (**Height, Distance, Peak, Tilt**),
    nose (**Size, Height, Nasal root**), mouth (**Size, Height, Smile**) [R]. Bipolar sliders [I].
  - **Auto reshape / Remodelage automatique**, **Manual reshape / Remodelage manuel** (brush warp, **Protect face / Protéger le visage**,
    **Intensity**, **Size**) [R].
  - **Manual / Manuelle**: **Smooth skin**, **Clear blemishes** brushes ("Click or brush over the area to retouch", "You can only brush inside the frame"),
    **Brush / Eraser**, **Size**, **Intensity**. The reset asks "Continue to reset? All manual retouch effects will be removed." [R]
  - **Makeup / Maquillage**: **Style**, **Lipstick / Rouge à lèvres**, **Eye shadow / Ombre à paupières**, blush, contour [R][I].
- **Body / Corps**: **Auto / Automatique** presets **Proportional / Proportionnelle** · **Refined / Peaufinée** · **Curve / Courbe**; **Manual**
  tools **Slim / Amincir** · **Stretch / Étirer** · **Resize / Redimensionner** with **Stretch area / Étirer la zone** (a box on the canvas);
  sliders **Slim**, **Waist / Taille**, **Head size / Taille de la tête**, **Hip / Hanche**, **Breasts**, **Buttocks**, long legs; **Single person**;
  "Body not detected" [R].
- **Presets**: footer **Save as preset / Enregistrer comme préréglage** → "Save as face preset" / "Save as body preset", name "Preset %1",
  up to %1 presets, "To save as preset, adjust an item first", **Rename / Delete** [R].
- **Eye contact / Contact visuel**: a toggle; it only applies to the main character ("Eye contact will be applied to the main character"),
  "Correcting eye contact... %1%" [R].
- **Feedback**: retouch is **real-time** (no job, sliders update the player live) [I, consistent with UX.md live slider behaviour and the lack of
  any "Applying retouch…" string]. Eye contact is a job.

---

## 6. Audio AI (Audio ▸ Basic and Voice changer), [L] location, [R] labels

Audio ▸ Basic sections (UX.md §5.1): ☐ Loudness normalization · ☐ Enhance voice · ☐ Video translator · ☐ Reduce noise · ☐ Isolate voice / Separate
audio · ☐ Beats [L].

### 6.1 Reduce noise / Réduire le bruit [R]
- One checkbox ("Minimize unwanted background sounds in your audio or video."), with no visible strength [I]. CapCut runs it locally
  (`rnnoise_v2.0.model`; "It may take longer to reduce noise" on machines without a discrete GPU) [R].
- Toast "Audio noise reduction successful" [R]. The waveform on the clip redraws [I].

### 6.2 Enhance voice / Améliorer la voix [L][R]
- ☐ Enhance voice ⓘ ("Automatically remove echoes, popping sounds, mouth clicks, and other noises, enhancing the voice to studio quality.")
  + **Strength / Force** slider [I, FEATURES.md lists it]. Job: "Waiting to enhance voice..." → "Enhancing voice... %1%" [R].

### 6.3 Loudness normalization [L][R]
☐ → "Normalize the loudness of the selected clip or clips to a target level." **Target loudness / Intensité sonore cible** (−23/−16/−14 LUFS
from Settings). "Applying loudness normalization... %1" → "Normalized loudness to %1 LUFS". Fails on compound clips, templates, avatars,
and very quiet clips [R].

### 6.4 Isolate voice / Separate audio [R]
Two generations of UI. The newer one is **Separate audio / Contenu audio séparé**:
- ☐ Separate audio → "Select the audio elements you want to separate." Chips: **Vocals / Chant** · **Instruments** · **Drums / Batterie** · **Bass /
  Basses** · **Piano** · **Guitar / Guitare** · **Strings / Instrument à corde** · **Wind / Instrument à vent** · **Synthesizer / Synthétiseur**
  · **Others / Autres**, + checkbox **Keep remaining audio / Conserver le contenu audio restant** ("To keep vocals only, select "Instruments"
  and "Keep remaining audio."") → **Separate / Séparer** [R].
- Progress "Separating audio... %1%" → "Audio separated". Partial results: "Couldn't separate %1. Others separated.", "%1 not detected.
  Others separated." Limit "You can separate up to %1 clips". **Restore** → "Original audio restored" [R].
- Older/simple mode, **Isolate voice / Isoler la voix**: **Keep vocal / Conserver la voix** · **Remove vocal / Supprimer la voix** · **None** [R].
  Undo labels "Undo: Keep vocal", "Undo: Remove vocal" [R].
- **Timeline result** [I, strongly implied by "Separate"/"Remaining audio"/"%1 separated. Select other audio elements you want to separate."]: each
  separated stem becomes a **new audio clip on its own track under the source**, time-aligned and linked. The source clip's audio is muted or
  replaced by the remaining audio. Keep/Remove vocal replaces the clip's audio in place (same clip).
- Limits: ≤ %1 minutes per clip (FEATURES: ~10); no compound, reversed, template or library music [R].

### 6.5 Voice changer [L][R]
Audio ▸ **Voice changer** pill tabs: **Voice filters / Filtres vocaux** · **Voice characters / Caractères vocaux** · **Speech to song / Discours en
chanson** [R]. Tiles 78 pt, click = download + apply + play [L]. Parameters under the grid, depending on the effect:
**Pitch / Hauteur**, **Timbre**, **Strength / Force**, **Room size / Taille de la pièce**, **Depth / Profondeur**, **Frequency / Fréquence**,
**Noise / Bruit**, **Amplitude**, **Surround rate / Débit surround**, **Quantity**, **Center** [R]. **Apply to all** [L]. Real-time, no job [I].

### 6.6 Custom voices (voice clone) and change to custom voice [R]
- "Create your custom voice with 10 seconds of audio." Sources: record (reading prompts, e.g. "Read the text out loud and clearly in a quiet
  environment.") or upload/extract. "Creating custom voice... %1%". Listen: "You are listening to your custom voice." [R]
- Changing an existing clip to a custom voice: "Changing to custom voice...", "Stop changing to custom voice?" [R]
- Valse: P1/P2 local, with a consent notice.

### 6.7 Audio / video translator [R]
Audio ▸ ☐ **Audio translator / Outil de traduction de fichiers audio** (or Video translator). Pick a target language → **Apply** → progress, with
**Run in background / Exécuter en arrière-plan** → "Translation completed". It refuses avatar, reversed and compound clips. Lip sync in its own
section (Standard "Original aspect ratio, generates faster" / Vivid "1:1, generates slower"). Cloud, P2.

---

## 7. Text to speech [L][R]

- Where: select a text clip → inspector tab **Text to speech / Synthèse vocale** [L]. Also Audio/Text panels and a standalone "Voiceover"
  long-text editor (`pc_long_text_editor_tts_*`) [R].
- Controls [R]:
  - **Search voices / Rechercher des voix**.
  - Pill tabs **Custom voices**, **Trending**, **New**, **Narration**, **Characters**, **Commercial**, **Anime**, **Chat**, **Viral**, **Premium**.
  - **Filters / Filtres** popover with Accent / language groups: EN-US, EN-UK, EN-Australian, EN-Others, **FR-Parisian / FR-Français**, **FR-Canadian**,
    FR-Others, ES-Castilian/Latin American/Mexican, PT-Brazilian/European, DE-Standard, JA-Standard/Kansai, ZH-Mandarin/Cantonese. Tags like
    Male/Female/Child/Elderly, styles (Excited, Angry, Caring, Deep…) with `[Reset] [Done]`.
  - Voice tiles (hover = sample).
  - **Adjust / Ajuster** ▸ **Speed / Vitesse** (+ pitch [I]).
  - **Update speech according to script / Mettre à jour la voix en fonction du script** (toggle).
  - **Apply to all / Appliquer à tout**.
  - Footer `[Generate speech]` [L].
- Progress: "Generating speech... / Génération en cours du discours…" [R], inline in the panel [I].
- Result [L]: a **TTS audio clip** (`clip.tts` colour `#15394A`) on an audio track under the main track, starting at the text clip's start and
  linked to it ("Text and speech are added to the track"). Editing the text with "Update speech…" on regenerates the clip ("Updating speech...")
  [R]. Too-long text: "Enter no more than %1 characters, otherwise the speech will not be updated." [R]
- Clicks: select text → TTS tab → click voice → Generate = **4** [L].

---

## 8. Beats (beat markers) [L][R]

- Where: select a music/audio clip → timeline toolbar **♥ Beats** button ▾ [L] (tooltip "Auto beat / Rythme auto", menu item "Auto mark beats /
  Marquer automatiquement le rythme"). Also Audio ▸ Basic ▸ ☐ **Beats / Rythmes**, and right-click ▸ Auto mark beats [R].
- Menu: **None** · **Beats 1 / Rythmes 1** · **Beats 2 / Rythmes 2** [L] (Beat 1 = sparser downbeats, Beat 2 = denser [I]). There's also a
  **Melody / Mélodie** mode [R].
- Manual: **Add beat / Ajouter un rythme** (M adds a marker at the playhead [L]), **Remove beats / Supprimer les rythmes**, **Clear beats /
  Effacer les rythmes** (an assignable shortcut) [R][L].
- Timeline appearance [L]: **yellow dots on a strip under the audio clip's waveform**, one per beat. Clips and the playhead snap to them when auto
  snapping is on.
- Drop target: dragging several media files onto the beat-marked audio shows "Drag and drop files here to align them with beat markers" → the
  files are laid out on the main track with one cut per beat → "Files aligned with beat markers" [R].
- Errors: "No beats to add to this sound", "Couldn't add beats. Try again." [R]. Applying a speed curve deletes the markers: "Beat markers will be
  deleted." [R]
- Local DSP, no job overlay (instant or a short spinner) [I].

---

## 9. AI stylize / AI effects [L][R]

Video/image clip → inspector tab **AI stylize / Stylisation par l'IA** [L]:
- **☐ AI effects / Effets IA**: **Prompt / Invite** box, **Random / Aléatoire**, **Strength / Force** slider (left = closer to the reference,
  right = closer to the prompt), `[Generate]` → "Generating..." with **Stop** → **Results / Résultats** thumbnails → **Refine / Peaufiner** /
  **Regenerate** → **Apply** → "AI effect applied" [R]. Video ≤ **10 s** ("Clips need to be within 10 seconds to apply AI effects"); on video it
  first stylizes the first frame ("The AI effect will be applied to the first frame of the video. Select a style to apply it to the whole video.") [R].
- **☐ Style**: preset grid (cloud). Mutually exclusive with AI effects ("The applied style will be removed if you apply AI effect.") [R].
- Valse: local style filters (NPR shaders, fast style nets) in the same tab. Same states, without a queue.

---

## 10. Long video to shorts and AI clipper [R][T]

### 10.1 Long video to shorts / Vidéo longue en vidéos courtes (home screen tool)
1. Home ▸ **Long video to shorts** card → **Upload long video / Téléverse une vidéo longue** drop zone ("Drag and drop %1 here"). Rules: "Duration:
   %1 to %2 minutes" (≥1 min and ≤ ~3 h per the tutorials), "Size: up to %1 GB", "This feature works best with talking videos, such as…".
   A video with no audio is rejected [R][T].
2. **Select the part you want to convert to shorts** (range handles on a timebar, "%1:%2:%3") [R].
3. **Set duration for shorts / Définis une durée pour les vidéos courtes**: **Auto** · **< 60s** · **60 – 90s** · **90s – 3m** [R]. **Caption
   style** template [R].
4. **Get shorts / Obtiens des vidéos courtes** → "Analyzing... %1%" → "Converting shorts... %1%". You can leave ("You can click "Go back" and view
   the progress in "History.""). Closing the app cancels it [R].
5. Results "Shorts (%1)": a grid of 9:16 shorts with captions. Each opens as its own new project [T][I]. A video under 1 min only gets
   reframed and captioned [R].

### 10.2 AI clipper / Créateur de clips IA (inside the editor, newer)
- Entry: Media panel / footer bar "AI clipper" [L, UX.md mentions the "AI clipper" footer bar].
- Flow [R]: **Select media** (filter "Select videos with speech", **Select all**, `Next (%1)`) → settings: content type **Any content · Podcast ·
  Interview · Product demo · Tutorial**; total length **<5 min · 5–10 min · 10+ min** (+ "3min+"); clip **Duration**: **Auto · 0–15s · 15–30s ·
  30s–1min · 1min+**; **Editing style / Style d'édition**: **Auto (edit based on your video content)** · **Chronological** · **Story-driven** ·
  **Speech-based** · **Valse**; **More requirements** prompt ("Describe the style, mood, or moments to highlight"); **Upload outline**
  → **Start clipping** / **Get clips**.
- Progress: "Creating clips... %1%" / "AI clipping... %1%", "About %1s left", **View later** ("We'll notify you when it's ready.") and
  **Cancel** → "Cancel clipping? Your highlight clips in progress will be lost." `[Keep generating]` `[Cancel]` [R].
- Results **Highlight clips / Clips avec mise en évidence**: list/grid, **Drag to reorder**, **Add chapter**, **Auto arrange clips**, **Save as new
  folder**, `[Save]`. "Get highlight clips?" warns: "Keyframes and speed changes will be removed. Some elements may be removed or may not sync
  with the main track." Then it **rebuilds the main track** [R].
- Valse: local Whisper + LLM scoring. Keep the same three-step wizard.

---

## 11. AI writer / scripts [R]

- Where: Text ▸ long-text editor ("Enter scripts" / **AI writer / Rédacteur IA**) and Script-to-video [R].
- Inputs: **Topic / Sujet** ("Example: an introduction to the First Industrial Revolution"), **Requirements / Exigences** ("Enter style description,
  character count, and additional details"), type (e.g. **Talking script / Script oral**), **Write script based on clips** [R].
- Output actions: **Make longer / shorter / rewrite** ("This feature can add more content… / shorten… / rewrite…"); **Add to track** (with **Split
  and add** / **Add without split**), saved to "AI writer" history ("Captions added and saved to "AI writer"") [R].
- Progress "Generating..." / "Almost there...". Disclaimer "Scripts are generated automatically by AI…" [R].
- Valse: local LLM (Foundation Models / Qwen). Results land as caption/text clips.

---

## 12. Other AI entry points worth cloning

- **Split scene / Diviser la scène**: right-click a clip (or a media card) ▸ Split scenes → shot-boundary detection (`SceneEditDetection`) →
  the clip is split at every cut [R].
- **Smart search** in Media: search media by content/dialogue [T].
- **AI emojis**, **AI packaging / Conception par l'IA** (captions + keyword SFX + effects in one click), **Auto B-roll** (cloud) [R]. P2.

---

## 13. Smart suggestions / Suggestions intelligentes (project analyzer) [R]

A newer panel (it analyzes locally: "CapCut will process your projects directly on this device"):
- `[Analyze]` → "Checking your video..." ("Checking for flicker, blur, shaking, dropped frames, and more across all clips...") + "Checking your
  audio…" ("…inconsistent volume, noise, unclear speech…") → "Analyzing... %1%" → **Analysis complete** · "Suggestions are ready", with **Stop**
  (confirm "Stop analyzing?").
- Suggestion groups: **Look better** (Make video clearer = Stabilize / Remove flickers / Reduce image noise / Enhance quality / Optical flow; Make
  colors better = Auto adjust; Make colors consistent = Color match; Retouch face; Eye contact), **Sound better** (Make voice clearer = Enhance
  voice + Reduce noise; Normalize loudness), **Express better** (Add captions, Style captions, AI movement, avatar). Each item shows **Clips to
  improve** and `[Apply]` (applies to every flagged clip). Undo per suggestion: "Remove retouching effects?", "Voice enhancement and noise
  reduction that were applied automatically will be removed." **Analyze again** after edits ("Project updated. Try analyzing again.").
- Valse: a good P1. It's just orchestration of features we already have.

---

## 14. Export progress state [L][R]

- In the Export dialog, after `[Export]` [L]: the cover preview shows "Generating… 0%" → plays the result. Footer **Open folder / Ouvrir le dossier**,
  `[Close]`, (Share).
- **Background export** [R]: "Your export will continue in the background, so you can edit other projects." / **Back to home / Retour à la page
  d'accueil**. On the home screen the project card shows **Exporting / Exportation en cours** (with %), **Waiting to export / Exportation en
  attente**, **Exported / Exportation effectuée**, or **Couldn't export**. A second project waits: "Another project is exporting. Export will
  start once it's done." Notification when it finishes: "%1 exported" with `[View file]` `[OK]` (`[Open project]`). Quitting asks "Quit app? The
  project you're exporting will be stopped." Editing while exporting may show "Editing is lagging / Please wait until the export is complete."
- Pending AI jobs: "Once the features are applied, you can click "Back to home" to continue exporting in the background."; during export:
  "Stabilizing...", "Removing background and stabilizing...", "Exporting in ultra HD..." [R].
- **Export selected clips** [R]: right-click ▸ Export selected clips → dialog with **Title** ("The exported file will be named with this title followed by
  a sequential number."), **No. of clips:**, ☐ **Include all changes when exporting** (off = only position/size/speed) → "Exporting..." → "Clips
  exported · Open the folder to view them." `[Open folder]`.
- Errors [R]: "Export failed", FAT32 too-large, invalid path, "Audio files not found → [Link audio files] / [Export anyway]", "The video may not export
  successfully. Close other applications or select a lower resolution and try again." (low memory, which matters on 8 GB).
- Valse: progress bar with % + elapsed/remaining time + **Cancel**, a non-modal mini progress in the title bar when the dialog is closed,
  then "Open folder" / "Export again" / "Close".

---

## 15. Layouts, custom layouts, detachable panels [R][L]

- **Layout presets** (title-bar layout button and CapCut ▸ Layout) [L][R]:
  - **Default / Par défaut** ("Balanced panel layout.")
  - **Media / Fichiers multimédia** ("Expands the media panel.")
  - **Generative / Génération**
  - **Attributes / Attributs** ("Expands the attribute panel.")
  - **Vertical / Disposition verticale** ("Ideal for vertical videos on social media."; a coach-mark suggests it for 9:16 projects: "Working on a vertical video? Switch to the vertical layout here.")
  - **Custom layout 1 / 2 / 3 / Disposition personnalisée 1/2/3**: three slots that store the current splitter arrangement [R]. We found no
    "Save layout" string, so CapCut probably **auto-saves the splitter state of the active slot** [I].
  - **Reset current layout / Réinitialiser la disposition actuelle**.
- **Detaching**: each panel's ☰ menu (or right-click on the header) has [R]:
  - **Detach media panel / Détacher le panneau de contenu multimédia**
  - **Detach player / Détacher le lecteur**
  - **Detach editing panel / Détacher le panneau d'édition** (the inspector)
  - **Detach timeline / Détacher la chronologie**

  A detached panel becomes its own native window (movable to a second screen; tip "Try [Separate window, Dual screen] to make editing easier.").
  The remaining panels reflow to fill the main window. Closing the detached window docks the panel back [I]. A **Window / Fenêtre** menu exists [R].
- **Responsive**: "Auto layout / Disposition automatique" [R]. Below a minimum window size: "Please expand the window to continue using CapCut" [R].
- Valse: NSWindow-based detach for the player (full-screen on the second display) and the timeline is P1. Implement the 5 presets + 3 custom slots.

---

## 16. Summary for Valse implementers

| Feature | Location | Clicks | Feedback | Timeline result |
|---|---|---|---|---|
| Auto captions | Text ▸ Auto captions | 2–3 | modal progress (generate → split → add) | new caption track, linked |
| Transcript editing | toolbar Transcript | 2 + edits | panel progress % | ripple cuts on the main track |
| Auto cutout | Video ▸ Remove BG ☐ | 3 | % on the clip | same clip (matte) |
| Custom cutout | Video ▸ Remove BG ☐ + brush + Apply | 5+ | % on the clip | same clip |
| Stabilize | Video ▸ Basic ☐ + level | 3–4 | % on the clip | same clip |
| Enhance quality / denoise / deflicker / optical flow | Video ▸ Basic ☐ | 3 | % on the clip | same clip (cached render) |
| Smooth slow-mo | Speed ▸ ☐ (speed < 1×) | 4 | % on the clip | same clip |
| Auto reframe | Video ▸ Basic ☐ + ratio | 4 | % on the clip, conflict confirm | same clip, project ratio changes |
| Relight / camera tracking / AI movement | Video ▸ Basic ☐ | 3+ | % on the clip | same clip |
| Retouch | Video ▸ Enhance sliders | 3 | real-time | same clip |
| Color match | Adjust ▸ Basic ☐ + source + Apply | 5 | "Matching colors..." | same clip (params) |
| Reduce noise / enhance voice | Audio ▸ Basic ☐ | 3 | % / toast | same clip |
| Separate audio | Audio ▸ Basic ☐ + chips + Separate | 4–5 | % | new stem audio clips/tracks (inferred) |
| Voice changer | Audio ▸ Voice changer tile | 3 | real-time | same clip |
| TTS | Text clip ▸ TTS ▸ voice ▸ Generate | 4 | inline spinner | new TTS audio clip, linked |
| Beats | toolbar ♥ ▾ Beats 1/2 | 3 | instant | yellow dots under the audio clip |
| Long video → shorts | Home card wizard | 4 | % + history | N new projects |
| AI clipper | editor wizard | 4–5 | % + ETA, View later | rebuilds the main track |

**Remaining gaps (not verifiable without running the features):** pixel layout and exact styling of the on-clip progress overlay; the exact
timeline placement of separated stems; default strength values for Enhance voice, Auto adjust and Color match; the Beats 1 vs 2 density
definition; whether Custom layout slots need an explicit save; whether a detached window re-docks on close. Each of these is marked [I] above.
Valse should decide them and record the decision here.
