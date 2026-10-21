#!/bin/bash
# Builds build/Montage.app (release by default; `--debug` for a debug build). Ad-hoc signed.
# Bundles the music + sound-effect library (Contents/Resources/Content) from the scripts/fetch_music_pack.sh cache
# and verifies every manifest item (file present, SHA-256) — fails if the cache is incomplete; `--no-content` skips it
# (a missing cache only warns unless MONTAGE_REQUIRE_CONTENT=1).
# The executable is universal (arm64 + x86_64, macOS 13+ per Info.plist / LC_BUILD_VERSION): each arch is built
# separately and merged with lipo; the resource bundles are architecture-independent (taken from the host build).
# `--host-only` (or MONTAGE_APP_ARCHS="arm64") builds only the listed / host arch, for quicker local iterations.
# Usage: scripts/build_app.sh [--debug] [--no-content] [--host-only]
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,9p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
CONFIG=release
CONTENT=1
HOST="$(uname -m)"
ARCHS="${MONTAGE_APP_ARCHS:-arm64 x86_64}"
for a in "$@"; do
  case "$a" in
    --debug) CONFIG=debug;;
    --no-content) CONTENT=0;;
    --host-only) ARCHS="$HOST";;
  esac
done
SLICES=()
for arch in $ARCHS; do
  swift build -c "$CONFIG" --product Montage --arch "$arch" >&2
  SLICES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Montage")
done
# resource bundles: from the host-arch build when it is in the list, else the first one
BIN="$(dirname "${SLICES[0]}")"
for arch in $ARCHS; do [[ "$arch" == "$HOST" ]] && BIN="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"; done
APP=build/Montage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Montage"
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
