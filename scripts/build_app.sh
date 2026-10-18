#!/bin/bash
# Builds build/Montage.app (release by default; `--debug` for a debug build). Ad-hoc signed.
# Bundles the music + sound-effect library (Contents/Resources/Content) from the scripts/fetch_music_pack.sh cache
# and verifies every manifest item (file present, SHA-256) — fails if the cache is incomplete; `--no-content` skips it
# (a missing cache only warns unless MONTAGE_REQUIRE_CONTENT=1).
# Usage: scripts/build_app.sh [--debug] [--no-content]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release
CONTENT=1
for a in "$@"; do
  case "$a" in
    --debug) CONFIG=debug;;
    --no-content) CONTENT=0;;
  esac
done
swift build -c "$CONFIG" --product Montage >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=build/Montage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Montage" "$APP/Contents/MacOS/Montage"
cp app/Bundle/Info.plist "$APP/Contents/Info.plist"
cp app/Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R app/Bundle/en.lproj app/Bundle/fr.lproj "$APP/Contents/Resources/"
# SwiftPM resource bundles (localized strings of every module) → Contents/Resources (found by ResourceBundleLocator)
for b in "$BIN"/Montage_*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
CACHE="${MONTAGE_CONTENT_CACHE:-$HOME/Library/Caches/MontageDev/content}/out"
if [[ $CONTENT == 1 && ! -d "$CACHE" && "${MONTAGE_REQUIRE_CONTENT:-0}" != 1 ]]; then
  echo "warning: music/SFX library not fetched ($CACHE missing) — app built WITHOUT it. Run scripts/fetch_music_pack.sh" \
       "(MONTAGE_REQUIRE_CONTENT=1 makes this an error for release packaging)." >&2
  CONTENT=0
fi
if [[ $CONTENT == 1 ]]; then
  python3 -I - "app/Sources/MontageEngine/Resources/ContentLibrary/content_manifest.json" "$CACHE" "$APP/Contents/Resources/Content" <<'EOF' >&2
import hashlib, json, os, shutil, sys
manifest, src, dst = sys.argv[1:4]
items = json.load(open(manifest))["items"]
missing, bad, total = [], [], 0
for i in items:
    p = os.path.join(src, i["file"])
    if not os.path.exists(p):
        missing.append(i["file"]); continue
    if hashlib.sha256(open(p, "rb").read()).hexdigest() != i["sha256"]:
        bad.append(i["file"]); continue
    q = os.path.join(dst, i["file"])
    os.makedirs(os.path.dirname(q), exist_ok=True)
    shutil.copyfile(p, q)
    total += os.path.getsize(q)
if missing or bad:
    sys.exit(f"content library incomplete in {src}: {len(missing)} missing, {len(bad)} checksum mismatches "
             f"(e.g. {(missing + bad)[:3]}). Run scripts/fetch_music_pack.sh (or build with --no-content).")
print(f"bundled {len(items)} library items ({total / 1e6:.1f} MB) into {dst}")
EOF
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed" >&2
echo "$APP"
