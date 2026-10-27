# Releasing Valse and automatic updates (SE-015)

Owner decisions (2026-10-26): Sparkle 2, self-signed code signing (no Apple Developer ID / notarization), releases on
the public `lulupointu/valse` GitHub repo, one stable channel, silent updates, no polling: check at launch + release push.

## How installed copies update
- Feed: `https://github.com/lulupointu/valse/releases/latest/download/appcast.xml` (Info.plist `SUFeedURL`), an asset of
  the newest (non-draft, non-prerelease) release: ~2 KB per check.
- No polling. Valse checks at each launch and after the Mac wakes. While it runs it keeps one idle stream open to
  the ntfy.sh topic in Info.plist `ValseUpdatePushURL`; `scripts/release.sh` publishes to it, and every running copy
  checks 5–60 s later (random, spreads the load). A message only triggers a normal check of the signed feed, so a
  forged one costs one check. A dropped stream reconnects silently (5 s → 10 min backoff) and checks once on
  reconnect, so a release pushed while offline is not missed. If ntfy.sh is down, copies update at their next launch.
- Failed checks (offline, GitHub down) show nothing. Settings ▸ About has one switch (automatic updates on/off).
- An update downloads quietly (a binary delta of a few MB when the previous release is one of the last 3, else the
  full zip), is verified (EdDSA signature against `SUPublicEDKey` + same code-signing certificate), and installs when
  Valse quits. Meanwhile a small card at the window's top-right offers "Restart to update" (quits through the normal
  path: project saved, jobs stopped; waits while an export runs) or "Later" (installs at the next quit anyway).
- "Check for updates" (Settings ▸ About, app menu) runs the same flow and shows its result inline.
- Code: `ValseApp/Updater.swift` (Sparkle, silent user driver, triggers), `ValseApp/UpdatePush.swift` (push
  stream), `ValseUI/Home/UpdateController.swift` (state the UI
  reads; `PreviewBackend` for tests / `--ui-state update=0.3.0` screenshots), `UpdateViews.swift`. Dev builds, `swift run`,
  UI tests and screenshots never start the updater (no .app bundle / tooling flags / empty `SUPublicEDKey`).

The topic name is public (anyone can read the "new version" messages, and the repo is public anyway). Changing it
strands running copies until their next launch: keep it.

## One-time setup (per release machine)
`scripts/release_setup.sh [<backup dir>]` creates:
1. **"Valse Release Signing"**, a self-signed code-signing certificate in the login keychain (macOS asks for the login
   password to trust it). Same certificate every release = same designated requirement: Sparkle accepts updates and
   macOS keeps camera / microphone / speech permissions across updates.
2. **Sparkle's EdDSA key** (login keychain). Its public half goes into `app/Bundle/Info.plist` `SUPublicEDKey`
   (the script prints it; commit it).

Both are exported to the backup dir (default `~/ValseReleaseKeys`). **Keep it safe and never commit it**: without the
EdDSA private key, installed copies can never be updated again. New Mac: `scripts/release_setup.sh --import <backup dir>`.

## Cutting a release
1. `main` builds and passed the gate; push it (`git push origin main`).
2. `scripts/fetch_music_pack.sh` once (the library is required in release builds), and `scripts/build_ai_runtimes.sh`
   once per runtime version bump (universal whisper-cli / demucs / llama-completion are required too: release builds
   bundle them into `Contents/Helpers`; without them users get no Whisper captions, stems or local LLM).
3. `scripts/release.sh 0.2.0 [--notes notes.md]` (`--dry-run` = build + appcast only). It builds the universal app
   (CFBundleVersion = commit count, so it always grows), signs it, zips it, makes deltas from the last 3 releases
   (their apps are cached in `~/Library/Application Support/ValseRelease/apps/<tag>`), writes `appcast.xml` and
   creates the GitHub release `v0.2.0` with `Valse.zip`, `appcast.xml` and the deltas, then sends the push.
4. Running copies download it within a minute; the others at their next launch.

Never delete or edit a published release's `Valse.zip`: the deltas of later releases are built against it.

## First install (no notarization)
- Recommended: `curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash`
  (curl downloads carry no quarantine flag: Valse opens without any Gatekeeper prompt).
- From the browser: unzip, move to Applications, open; macOS says it cannot verify Valse → Done → System Settings ▸
  Privacy & Security → **Open Anyway** (macOS 15 removed the right-click ▸ Open bypass). Only the first launch; Sparkle
  strips the quarantine flag of the updates it installs.
