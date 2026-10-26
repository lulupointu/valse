# Releasing Montage and automatic updates (SE-015)

Owner decisions (2026-10-26): Sparkle 2, self-signed code signing (no Apple Developer ID / notarization), releases on
the public `lulupointu/valse` GitHub repo, one stable channel, silent updates.

## How installed copies update
- Feed: `https://github.com/lulupointu/valse/releases/latest/download/appcast.xml` (Info.plist `SUFeedURL`), an asset of
  the newest (non-draft, non-prerelease) release: ~2 KB per check.
- Checks run in the background every day by default (Settings ▸ About: every hour / day / week, or off). A failed
  background check (offline, GitHub down) shows nothing and retries at the next interval.
- An update downloads quietly (a binary delta of a few MB when the previous release is one of the last 3, else the
  full zip), is verified (EdDSA signature against `SUPublicEDKey` + same code-signing certificate), and installs when
  Montage quits. Meanwhile a small card at the window's top-right offers "Restart to update" (quits through the normal
  path: project saved, jobs stopped; waits while an export runs) or "Later" (installs at the next quit anyway).
- "Check for updates" (Settings ▸ About, app menu) runs the same flow and shows its result inline.
- Code: `MontageApp/Updater.swift` (Sparkle, silent user driver), `MontageUI/Home/UpdateController.swift` (state the UI
  reads; `PreviewBackend` for tests / `--ui-state update=0.3.0` screenshots), `UpdateViews.swift`. Dev builds, `swift run`,
  UI tests and screenshots never start the updater (no .app bundle / tooling flags / empty `SUPublicEDKey`).

## One-time setup (per release machine)
`scripts/release_setup.sh [<backup dir>]` creates:
1. **"Montage Release Signing"**, a self-signed code-signing certificate in the login keychain (macOS asks for the login
   password to trust it). Same certificate every release = same designated requirement: Sparkle accepts updates and
   macOS keeps camera / microphone / speech permissions across updates.
2. **Sparkle's EdDSA key** (login keychain). Its public half goes into `app/Bundle/Info.plist` `SUPublicEDKey`
   (the script prints it; commit it).

Both are exported to the backup dir (default `~/MontageReleaseKeys`). **Keep it safe and never commit it**: without the
EdDSA private key, installed copies can never be updated again. New Mac: `scripts/release_setup.sh --import <backup dir>`.

## Cutting a release
1. `main` builds and passed the gate; push it (`git push origin main`).
2. `scripts/fetch_music_pack.sh` once (the library is required in release builds).
3. `scripts/release.sh 0.2.0 [--notes notes.md]` (`--dry-run` = build + appcast only). It builds the universal app
   (CFBundleVersion = commit count, so it always grows), signs it, zips it, makes deltas from the last 3 releases
   (their apps are cached in `~/Library/Application Support/MontageRelease/apps/<tag>`), writes `appcast.xml` and
   creates the GitHub release `v0.2.0` with `Montage.zip`, `appcast.xml` and the deltas.
4. Installed copies pick it up within their check interval.

Never delete or edit a published release's `Montage.zip`: the deltas of later releases are built against it.

## First install (no notarization)
- Recommended: `curl -fsSL https://raw.githubusercontent.com/lulupointu/valse/main/scripts/install.sh | bash`
  (curl downloads carry no quarantine flag: Montage opens without any Gatekeeper prompt).
- From the browser: unzip, move to Applications, open; macOS says it cannot verify Montage → Done → System Settings ▸
  Privacy & Security → **Open Anyway** (macOS 15 removed the right-click ▸ Open bypass). Only the first launch; Sparkle
  strips the quarantine flag of the updates it installs.
