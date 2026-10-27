#!/bin/bash
# Owner: publish a Valse release that installed copies pick up automatically (SE-015, docs/RELEASING.md).
#   1. builds build/Valse.app from the main checkout's HEAD (universal, music/SFX library required), version <version>,
#      build number = commit count, signed with the release identity (VALSE_SIGN_IDENTITY, see below)
#   2. Valse.zip + EdDSA-signed binary deltas from the last 3 Valse releases (small downloads for existing users)
#   3. appcast.xml (the feed every installed copy reads: releases/latest/download/appcast.xml): this release on the
#      `valse` channel + the bridge item for copies installed before the rename (scripts/release_appcast.py)
#   4. GitHub release v<version> on lulupointu/valse with those assets (the newest release is the one served)
#   5. push to the ntfy topics (Info.plist ValseUpdatePushURL, and the pre-rename topic old copies listen on)
# --bridge: the ONE release that moves pre-rename copies (Montage ≤ 0.4, fr.montage.Montage) to Valse: also publishes
#   Valse-bridge.zip (this Valse build under the bundle name Montage.app, the name those copies look for), its appcast
#   item has no channel, no deltas. Later appcasts repeat that item for one week after the bridge release, then drop it
#   (owner 2026-10-27; scripts/release_appcast.py --bridge-days).
# One-time setup first: scripts/release_setup.sh. HEAD must be pushed to origin/main.
# Usage: scripts/release.sh <version, e.g. 0.4.0> [--bridge] [--notes <file.md>] [--dry-run (build + appcast, publish nothing)]
set -euo pipefail
if [[ $# -lt 1 || "$1" == -h || "$1" == --help ]]; then sed -n '2,15p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
VERSION="$1"; shift
NOTES=""; DRY=0; BRIDGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --bridge) BRIDGE=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "✘ version must look like 1.2 or 1.2.3"; exit 2; }
REPO=lulupointu/valse
# The certificate keeps its pre-rename name: the designated requirement every installed copy checks names its leaf
# certificate, and macOS ties camera / microphone permissions to it; re-issuing it under a new name would change both.
IDENTITY="${VALSE_SIGN_IDENTITY:-Montage Release Signing}"
STORE="${VALSE_RELEASE_DIR:-$HOME/Library/Application Support/ValseRelease}"
LEGACY_STORE="$HOME/Library/Application Support/MontageRelease"   # pre-rename location of the release store
# ntfy topic of the pre-rename Info.plist (MontageUpdatePushURL): copies installed before the rename listen there
LEGACY_PUSH="https://ntfy.sh/montage-valse-91d5915283fb1a9e5a9b/json"
TAG="v$VERSION"

# --- preconditions -----------------------------------------------------------------------------------------------------
[[ -z "$(git status --porcelain)" ]] || { echo "✘ uncommitted changes: release from a clean checkout"; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "✘ not on main"; exit 1; }
if [[ $DRY == 0 ]]; then
  git fetch -q origin main
  git merge-base --is-ancestor HEAD origin/main || { echo "✘ HEAD is not on origin/main: push main first"; exit 1; }
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && { echo "✘ release $TAG already exists"; exit 1; }
fi
KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' app/Bundle/Info.plist 2>/dev/null || true)"
[[ -n "$KEY" ]] || { echo "✘ SUPublicEDKey is empty in app/Bundle/Info.plist: run scripts/release_setup.sh"; exit 1; }
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "✘ no code-signing identity \"$IDENTITY\": run scripts/release_setup.sh"; exit 1; }
BUILD="$(git rev-list --count HEAD)"
if [[ ! -d "$STORE" && -d "$LEGACY_STORE" ]]; then mv "$LEGACY_STORE" "$STORE"; fi
# the latest published appcast: carries the bridge item (repeated for a week) or is already a post-rename appcast
PREV_APPCAST="$(mktemp -t valse-prev-appcast)"
LATEST_TAG="$(gh release list -R "$REPO" --limit 1 --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName' 2>/dev/null || true)"
[[ -n "$LATEST_TAG" ]] && gh release download "$LATEST_TAG" -R "$REPO" -p appcast.xml -O "$PREV_APPCAST" --clobber >/dev/null 2>&1 || true
if [[ $BRIDGE == 0 ]] && ! grep -q -e "Valse-bridge.zip" -e "<sparkle:channel>valse</sparkle:channel>" "$PREV_APPCAST" 2>/dev/null; then
  echo "✘ the latest release ($LATEST_TAG) has no bridge item: publish the bridge release first (--bridge, docs/RELEASING.md)"; exit 1
fi

# --- build -------------------------------------------------------------------------------------------------------------
swift package resolve >/dev/null
SPARKLE_BIN="$(cd .build/artifacts/sparkle/Sparkle/bin && pwd)"
VALSE_REQUIRE_CONTENT=1 VALSE_REQUIRE_RUNTIMES=1 VALSE_SIGN_IDENTITY="$IDENTITY" VALSE_VERSION="$VERSION" VALSE_BUILD="$BUILD" \
  scripts/build_app.sh >/dev/null
APP=build/Valse.app
OUT="build/release/$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT/deltas"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Valse.zip"
echo "▶ Valse $VERSION ($BUILD): $(du -h "$OUT/Valse.zip" | cut -f1) zip"
if [[ $BRIDGE == 1 ]]; then
  # the same signed bundle under the pre-rename file name (a bundle's name is not part of its code signature)
  mkdir -p "$OUT/bridge" && ditto "$APP" "$OUT/bridge/Montage.app"
  codesign --verify --deep --strict "$OUT/bridge/Montage.app"
  ditto -c -k --sequesterRsrc --keepParent "$OUT/bridge/Montage.app" "$OUT/Valse-bridge.zip"
  rm -rf "$OUT/bridge"
  echo "▶ bridge archive (Montage.app inside): $(du -h "$OUT/Valse-bridge.zip" | cut -f1)"
fi

# --- deltas from the previous Valse releases (their apps are kept in $STORE/apps/<tag>, fetched if missing) -----------
mkdir -p "$STORE/apps"
PREV_TAGS="$(gh release list -R "$REPO" --limit 3 --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName' 2>/dev/null || true)"
if [[ $BRIDGE == 0 ]]; then
  for t in $PREV_TAGS; do
    OLD="$STORE/apps/$t/Valse.app"
    if [[ ! -d "$OLD" ]]; then
      tmp="$(mktemp -d)"
      # releases before the bridge have no Valse.zip: no delta from them (their copies take the bridge first anyway)
      if gh release download "$t" -R "$REPO" -p Valse.zip -D "$tmp" >/dev/null 2>&1; then
        ditto -x -k "$tmp/Valse.zip" "$tmp/x" && mkdir -p "$STORE/apps/$t" && ditto "$tmp/x/Valse.app" "$OLD"
      fi
      rm -rf "$tmp"
    fi
    [[ -d "$OLD" ]] || continue
    b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OLD/Contents/Info.plist")"
    [[ "$b" != "$BUILD" ]] || continue
    "$SPARKLE_BIN/BinaryDelta" create "$OLD" "$APP" "$OUT/deltas/Valse$BUILD-$b.delta"
    echo "  delta from $t ($b): $(du -h "$OUT/deltas/Valse$BUILD-$b.delta" | cut -f1)"
  done
fi

# --- appcast -----------------------------------------------------------------------------------------------------------
if [[ $BRIDGE == 1 ]]; then
  python3 -I scripts/release_appcast.py --version "$VERSION" --build "$BUILD" --repo "$REPO" --tag "$TAG" \
    --sign-update "$SPARKLE_BIN/sign_update" --zip "$OUT/Valse-bridge.zip" --bridge > "$OUT/appcast.xml"
else
  python3 -I scripts/release_appcast.py --version "$VERSION" --build "$BUILD" --repo "$REPO" --tag "$TAG" \
    --sign-update "$SPARKLE_BIN/sign_update" --zip "$OUT/Valse.zip" --deltas "$OUT/deltas" \
    --previous-appcast "$PREV_APPCAST" > "$OUT/appcast.xml"
fi
rm -f "$PREV_APPCAST"
echo "▶ appcast: $OUT/appcast.xml"

if [[ $DRY == 1 ]]; then echo "dry run: nothing published"; exit 0; fi

# --- publish -----------------------------------------------------------------------------------------------------------
NOTES_FILE="$OUT/notes.md"
if [[ -n "$NOTES" ]]; then cp "$NOTES" "$NOTES_FILE"; else : > "$NOTES_FILE"; fi
cat >> "$NOTES_FILE" <<EOF

---
**Install** (first time): in Terminal, run
\`\`\`
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash
\`\`\`
or download **Valse.zip**, unzip it, move Valse to Applications and open it. macOS will say it "can't verify" Valse:
click **Done**, open **System Settings ▸ Privacy & Security**, scroll down and click **Open Anyway** (once).
Already installed? Valse updates itself.
EOF
shopt -s nullglob
ASSETS=("$OUT/Valse.zip" "$OUT/appcast.xml" "$OUT"/deltas/*.delta)
[[ $BRIDGE == 1 ]] && ASSETS+=("$OUT/Valse-bridge.zip")
gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "Valse $VERSION" --notes-file "$NOTES_FILE" "${ASSETS[@]}"
# keep this app for the next releases' deltas; drop apps of tags that are no longer among the last 3 before it
mkdir -p "$STORE/apps/$TAG" && ditto "$APP" "$STORE/apps/$TAG/Valse.app"
for d in "$STORE"/apps/*; do
  t="$(basename "$d")"
  [[ "$t" == "$TAG" ]] || grep -qx "$t" <<< "$PREV_TAGS" || rm -rf "$d"
done
# --- tell running copies (ntfy: the current topic and the pre-rename one); the others check at their next launch -----
PUSH="$(/usr/libexec/PlistBuddy -c 'Print :ValseUpdatePushURL' app/Bundle/Info.plist 2>/dev/null || true)"
for p in "$PUSH" "$LEGACY_PUSH"; do
  [[ -n "$p" ]] || continue
  curl -fsS -m 20 -H "Title: Valse $VERSION" -d "Valse $VERSION is available" "${p%/json}" >/dev/null \
    && echo "✔ push sent (${p%/json}): running copies check within a minute" \
    || echo "⚠ push failed (${p%/json}): running copies get $VERSION at their next launch (re-send: curl -d x ${p%/json})"
done
echo "✔ released $TAG"
