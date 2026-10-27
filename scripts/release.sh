#!/bin/bash
# Owner: publish a Valse release that installed copies pick up automatically (SE-015, docs/RELEASING.md).
#   1. builds build/Valse.app from the main checkout's HEAD (universal, music/SFX library required), version <version>,
#      build number = commit count, signed with the self-signed "Valse Release Signing" identity
#   2. Valse.zip + EdDSA-signed binary deltas from the last 3 releases (small downloads for existing users)
#   3. appcast.xml (the feed every installed Valse reads: releases/latest/download/appcast.xml)
#   4. GitHub release v<version> on lulupointu/valse with those assets (the newest release is the one served)
#   5. push to the ntfy topic (Info.plist ValseUpdatePushURL): running copies check at once, the others at launch
# One-time setup first: scripts/release_setup.sh. HEAD must be pushed to origin/main.
# Usage: scripts/release.sh <version, e.g. 0.2.0> [--notes <file.md>] [--dry-run (build + appcast, publish nothing)]
set -euo pipefail
if [[ $# -lt 1 || "$1" == -h || "$1" == --help ]]; then sed -n '2,11p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
VERSION="$1"; shift
NOTES=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "✘ version must look like 1.2 or 1.2.3"; exit 2; }
REPO=lulupointu/valse
IDENTITY="${VALSE_SIGN_IDENTITY:-Valse Release Signing}"
STORE="${VALSE_RELEASE_DIR:-$HOME/Library/Application Support/ValseRelease}"
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

# --- deltas from the previous releases (their apps are kept in $STORE/apps/<tag>, fetched from GitHub if missing) ----
mkdir -p "$STORE/apps"
PREV_TAGS="$(gh release list -R "$REPO" --limit 3 --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName' 2>/dev/null || true)"
for t in $PREV_TAGS; do
  OLD="$STORE/apps/$t/Valse.app"
  if [[ ! -d "$OLD" ]]; then
    tmp="$(mktemp -d)"
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

# --- appcast -----------------------------------------------------------------------------------------------------------
python3 -I scripts/release_appcast.py --version "$VERSION" --build "$BUILD" --repo "$REPO" --tag "$TAG" \
  --sign-update "$SPARKLE_BIN/sign_update" --zip "$OUT/Valse.zip" --deltas "$OUT/deltas" > "$OUT/appcast.xml"
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
gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "Valse $VERSION" --notes-file "$NOTES_FILE" \
  "$OUT/Valse.zip" "$OUT/appcast.xml" "$OUT"/deltas/*.delta
# keep this app for the next releases' deltas; drop apps of tags that are no longer among the last 3 before it
mkdir -p "$STORE/apps/$TAG" && ditto "$APP" "$STORE/apps/$TAG/Valse.app"
for d in "$STORE"/apps/*; do
  t="$(basename "$d")"
  [[ "$t" == "$TAG" ]] || grep -qx "$t" <<< "$PREV_TAGS" || rm -rf "$d"
done
# --- tell running copies (ntfy topic of Info.plist ValseUpdatePushURL); the others check at their next launch -----
PUSH="$(/usr/libexec/PlistBuddy -c 'Print :ValseUpdatePushURL' app/Bundle/Info.plist 2>/dev/null || true)"
if [[ -n "$PUSH" ]]; then
  curl -fsS -m 20 -H "Title: Valse $VERSION" -d "Valse $VERSION is available" "${PUSH%/json}" >/dev/null \
    && echo "✔ push sent: running copies check within a minute" \
    || echo "⚠ push failed: running copies get $VERSION at their next launch (re-send: curl -d x ${PUSH%/json})"
fi
echo "✔ released $TAG"
