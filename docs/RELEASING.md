# Releasing Valse and automatic updates (SE-015)

Owner decisions (2026-10-26): Sparkle 2, self-signed code signing (no Apple Developer ID / notarization), releases on
the public `lulupointu/valse` GitHub repo, one stable channel, silent updates, no polling: check at launch + release push.
2026-10-27: the app, called Montage until 0.3, is renamed Valse everywhere, bundle id included (`fr.montage.Montage` →
`fr.valse.Valse`); existing installs move over through one **bridge release** (below).

## How installed copies update
- Feed: `https://github.com/lulupointu/valse/releases/latest/download/appcast.xml` (Info.plist `SUFeedURL`), an asset of
  the newest (non-draft, non-prerelease) release: ~2 KB per check.
- No polling. Valse checks at each launch and after the Mac wakes. While it runs it keeps one idle stream open to
  the ntfy.sh topic in Info.plist `ValseUpdatePushURL`; `scripts/release.sh` publishes to it (and to the pre-rename
  topic, see below), and every running copy checks 5–60 s later (random, spreads the load). A message only triggers a
  normal check of the signed feed, so a forged one costs one check. A dropped stream reconnects silently (5 s → 10 min
  backoff) and checks once on reconnect, so a release pushed while offline is not missed. If ntfy.sh is down, copies
  update at their next launch.
- Failed checks (offline, GitHub down) show nothing. Settings ▸ About has one switch (automatic updates on/off).
- An update downloads quietly (a binary delta of a few MB when the previous release is one of the last 3, else the
  full zip), is verified (EdDSA signature against `SUPublicEDKey`; Sparkle checks it before extracting), and installs
  when Valse quits. Meanwhile a small card at the window's top-right offers "Restart to update" (quits through the
  normal path: project saved, jobs stopped; waits while an export runs) or "Later" (installs at the next quit anyway).
- "Check for updates" (Settings ▸ About, app menu) runs the same flow and shows its result inline.
- Valse declares the Sparkle channel `valse` (`allowedChannels`): it reads appcast items on that channel and items
  without a channel. Copies from before the rename know no channels and only see channel-less items.
- Code: `ValseApp/Updater.swift` (Sparkle, silent user driver, triggers), `ValseApp/UpdatePush.swift` (push
  stream), `ValseUI/Home/UpdateController.swift` (state the UI reads; `PreviewBackend` for tests / `--ui-state
  update=0.3.0` screenshots), `UpdateViews.swift`. Dev builds, `swift run`, UI tests and screenshots never start the
  updater (no .app bundle / tooling flags / empty `SUPublicEDKey`).

The topic names are public (anyone can read the "new version" messages, and the repo is public anyway). Changing one
strands running copies until their next launch: keep them.

## One-time setup (per release machine)
`scripts/release_setup.sh [<backup dir>]` creates:
1. **"Montage Release Signing"**, a self-signed code-signing certificate in the login keychain (macOS asks for the login
   password to trust it). It keeps its pre-rename name on purpose: same certificate every release = same signing
   chain, and macOS ties camera / microphone / speech permissions to it; re-issuing it under a new name would change
   that for every user. `VALSE_SIGN_IDENTITY` overrides the name if it ever has to change.
2. **Sparkle's EdDSA key** (login keychain). Its public half goes into `app/Bundle/Info.plist` `SUPublicEDKey`
   (the script prints it; commit it). **It must never change**: copies installed before the rename can only accept the
   bridge release through this key (their code-signing requirement names the old bundle id, which Valse no longer has).

Both are exported to the backup dir (default `~/ValseReleaseKeys`, or the existing `~/MontageReleaseKeys`). **Keep it
safe and never commit it**: without the EdDSA private key, installed copies can never be updated again. New Mac:
`scripts/release_setup.sh --import <backup dir>` (reads backups made before the rename too).

## Cutting a release
1. `main` builds and passed the gate; push it (`git push origin main`).
2. `scripts/fetch_music_pack.sh` once (the library is required in release builds), and `scripts/build_ai_runtimes.sh`
   once per runtime version bump (universal whisper-cli / demucs / llama-completion are required too: release builds
   bundle them into `Contents/Helpers`; without them users get no Whisper captions, stems or local LLM).
3. `scripts/release.sh 0.5.0 [--notes notes.md]` (`--dry-run` = build + appcast only). It builds the universal app
   (CFBundleVersion = commit count, so it always grows), signs it, zips it (`Valse.zip`), makes deltas from the last 3
   Valse releases (`Valse<build>-<from>.delta`; their apps are cached in `~/Library/Application Support/ValseRelease/
   apps/<tag>`, the pre-rename `MontageRelease` store is moved there), writes `appcast.xml` (this release on the
   `valse` channel + the bridge item copied from the latest published appcast, during the week after the bridge
   release) and creates the GitHub release with
   `Valse.zip`, `appcast.xml` and the deltas, then sends the push to both topics.
4. Running copies download it within a minute; the others at their next launch.

Never delete or edit a published release's `Valse.zip` (the deltas of later releases are built against it), and never
delete the bridge release's `Valse-bridge.zip` (the bridge release's own appcast points pre-rename copies at it).

## The Montage → Valse bridge (once)
Why: Sparkle in a copy installed before the rename (Montage ≤ 0.3, `/Applications/Montage.app`, `fr.montage.Montage`)
only installs an archive holding an app named like the installed bundle (`Montage.app`) or with the same bundle id, and
always installs it at the installed path. So the bridge release ships the new Valse build **named `Montage.app`**;
that build renames its own bundle to `Valse.app` at its first launch. Every later release ships `Valse.app`, which
installed Valse copies find by bundle id. Copies that skip a release still land on the bridge first: for one week after the
bridge release (owner 2026-10-27), later appcasts keep the bridge item without a channel (the only item they see) next
to the newest release on the `valse` channel. After that week `release_appcast.py` drops it (`--bridge-days`): a
pre-rename copy that was not opened during that week sees no update at all and is reinstalled by hand (install.sh or
the `Valse.zip` download); its first launch still migrates everything.

Owner steps:
1. Merge the rename branch, push `main`.
2. `scripts/release.sh <next version, e.g. 0.4.0> --bridge --notes notes.md` (`--dry-run` first if you like: check that
   `build/release/<version>/` has `Valse.zip`, `Valse-bridge.zip` and an `appcast.xml` with one item and no
   `<sparkle:channel>`). It publishes `Valse.zip` (fresh installs, install.sh), `Valse-bridge.zip` (the same signed
   app as `Montage.app`, for existing copies) and the appcast, and pushes to the old topic
   (`montage-valse-91d5…`, which running pre-rename copies listen on) and the new one.
3. Check on your own Mac: the installed Montage updates at quit; at next launch it becomes `/Applications/Valse.app`
   (a Dock item that pointed at Montage.app may need to be dragged in again), Home shows the same projects, Settings are kept, AI models are still
   installed. macOS asks once more for camera / microphone / speech permission (new bundle id: unavoidable). Online
   music keys saved in Settings ▸ Music move over when macOS lets Valse read them without asking; otherwise enter them
   again.
4. From then on, plain `scripts/release.sh <version>` (it refuses to run while the latest appcast is a pre-rename
   one). It carries the bridge item for a week, then drops it. Keep the bridge release and its `Valse-bridge.zip`.

What the first launch of Valse does on an existing install (`ValseApp/Rebrand.swift`, `ValseCore/Persistence/
RebrandMigration.swift`, all once, crash-safe, retried at the next launch if a step could not finish):
- Bundle: `…/Montage.app` → `…/Valse.app` in the same folder, then relaunch (skipped if `Valse.app` exists there, the
  folder is not writable or the app runs translocated: it then keeps running from `Montage.app` and keeps updating).
- Folders (same-volume renames, never copies; never merged into an existing Valse folder; skipped while a pre-rename
  Montage still runs): `~/Library/Application Support/Montage` → `Valse` (settings, library index, AI models,
  runtimes, stickers, LUTs, effects, pasted media…), `~/Library/Caches/Montage` → `Valse`, and `~/Movies/Montage` →
  `~/Movies/Valse` when it is the default project library (a custom "Save to" folder stays where it is). Until a move
  succeeds, Valse keeps using the old folder. The library index and settings.json paths are rewritten; projects keep
  their files and their `.montage` name, and their media paths into a moved folder are resolved when they open.
- Settings: the old domain `fr.montage.Montage` is copied into `fr.valse.Valse` (keys renamed, content IDs in values
  mapped); the old domain is kept.
- Keychain: online-audio keys move from `fr.montage.online-audio` to `fr.valse.online-audio` when readable without a
  prompt.
- Projects saved by Montage open as they are (`.montage`, UTI `fr.montage.project` imported by Info.plist, built-in
  content IDs `montage.…` mapped to `valse.…` when loaded); new projects are `.valse` (`fr.valse.project`).
`scripts/updater_e2e.sh` proves the whole path offline (pre-rename build → bridge → migration → channel release, and a
client that skipped the bridge release).

## First install (no notarization)
- Recommended: `curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash`
  (curl downloads carry no quarantine flag: Valse opens without any Gatekeeper prompt). It quits a running Valse or
  Montage first (project saved) and replaces an old `Montage.app` in the same folder.
- From the browser: unzip, move to Applications, open; macOS says it cannot verify Valse → Done → System Settings ▸
  Privacy & Security → **Open Anyway** (macOS 15 removed the right-click ▸ Open bypass). Only the first launch; Sparkle
  strips the quarantine flag of the updates it installs.
