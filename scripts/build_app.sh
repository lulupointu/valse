#!/bin/bash
# Builds build/Valse.app (release by default; `--debug` for a debug build). Ad-hoc signed unless
# VALSE_SIGN_IDENTITY names a code-signing identity (scripts/release.sh: the self-signed "Valse Release Signing").
# VALSE_VERSION / VALSE_BUILD set CFBundleShortVersionString / CFBundleVersion (release builds; Sparkle compares
# CFBundleVersion). Sparkle.framework (automatic updates, SE-015) is embedded in Contents/Frameworks.
# Bundles the music + sound-effect library (Contents/Resources/Content) from the scripts/fetch_music_pack.sh cache
# and verifies every manifest item (file present, SHA-256) — fails if the cache is incomplete; `--no-content` skips it
# (a missing cache only warns unless VALSE_REQUIRE_CONTENT=1).
# Bundles the AI sidecar runtimes (whisper-cli, demucs, llama-completion) into Contents/Helpers from
# scripts/build_ai_runtimes.sh's install dir (VALSE_AI_BIN_DIR, default Application Support/Valse/bin); each must
# contain every built arch. Missing / thin runtimes only warn unless VALSE_REQUIRE_RUNTIMES=1 (release packaging).
# The executable is universal (arm64 + x86_64, macOS 13+ per Info.plist / LC_BUILD_VERSION): each arch is built
# separately and merged with lipo; the resource bundles are architecture-independent (taken from the host build).
# `--host-only` (or VALSE_APP_ARCHS="arm64") builds only the listed / host arch, for quicker local iterations.
# Usage: scripts/build_app.sh [--debug] [--no-content] [--host-only]
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,15p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
CONFIG=release
CONTENT=1
HOST="$(uname -m)"
ARCHS="${VALSE_APP_ARCHS:-arm64 x86_64}"
for a in "$@"; do
  case "$a" in
    --debug) CONFIG=debug;;
    --no-content) CONTENT=0;;
    --host-only) ARCHS="$HOST";;
  esac
done
SLICES=()
for arch in $ARCHS; do
  swift build -c "$CONFIG" --product Valse --arch "$arch" >&2
  SLICES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Valse")
done
# resource bundles: from the host-arch build when it is in the list, else the first one
BIN="$(dirname "${SLICES[0]}")"
for arch in $ARCHS; do [[ "$arch" == "$HOST" ]] && BIN="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"; done
APP=build/Valse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Valse"
cp app/Bundle/Info.plist "$APP/Contents/Info.plist"
[[ -n "${VALSE_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VALSE_VERSION" "$APP/Contents/Info.plist"
[[ -n "${VALSE_BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VALSE_BUILD" "$APP/Contents/Info.plist"
# Sparkle (SwiftPM puts the framework next to the binary, found there through @loader_path; in the bundle it lives in
# Contents/Frameworks). Universal framework: the host build's copy serves every slice.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Valse"
cp app/Bundle/ValseIcon.icns "$APP/Contents/Resources/ValseIcon.icns"
cp -R app/Bundle/en.lproj app/Bundle/fr.lproj "$APP/Contents/Resources/"
# SwiftPM resource bundles (localized strings of every module) → Contents/Resources (found by ResourceBundleLocator)
for b in "$BIN"/Valse_*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
CACHE="${VALSE_CONTENT_CACHE:-$HOME/Library/Caches/ValseDev/content}/out"
if [[ $CONTENT == 1 && ! -d "$CACHE" && "${VALSE_REQUIRE_CONTENT:-0}" != 1 ]]; then
  echo "warning: music/SFX library not fetched ($CACHE missing) — app built WITHOUT it. Run scripts/fetch_music_pack.sh" \
       "(VALSE_REQUIRE_CONTENT=1 makes this an error for release packaging)." >&2
  CONTENT=0
fi
if [[ $CONTENT == 1 ]]; then
  python3 -I - "app/Sources/ValseEngine/Resources/ContentLibrary/content_manifest.json" "$CACHE" "$APP/Contents/Resources/Content" <<'EOF' >&2
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
# AI sidecar runtimes → Contents/Helpers (looked up there first by WhisperRuntime / DemucsRuntime / LlamaRuntime).
# Without them a user's Mac has no whisper (captions fall back to Apple speech, absent on Intel), no stems, no local LLM.
RUNTIMES="${VALSE_AI_BIN_DIR:-$HOME/Library/Application Support/Valse/bin}"
HELPERS=()
RT_PROBLEMS=()
for b in whisper-cli demucs llama-completion; do
  src="$RUNTIMES/$b"
  if [[ ! -x "$src" ]]; then RT_PROBLEMS+=("$b missing"); continue; fi
  thin=""
  for arch in $ARCHS; do lipo "$src" -verify_arch "$arch" 2>/dev/null || thin="$thin $arch"; done
  if [[ -n "$thin" ]]; then RT_PROBLEMS+=("$b lacks$thin"); continue; fi
  mkdir -p "$APP/Contents/Helpers"
  cp "$src" "$APP/Contents/Helpers/$b"
  HELPERS+=("$APP/Contents/Helpers/$b")
done
if [[ ${#RT_PROBLEMS[@]} -gt 0 ]]; then
  msg="AI runtimes not bundled (${RT_PROBLEMS[*]} in $RUNTIMES). Run scripts/build_ai_runtimes.sh."
  if [[ "${VALSE_REQUIRE_RUNTIMES:-0}" == 1 ]]; then echo "error: $msg" >&2; exit 1; fi
  echo "warning: $msg" >&2
fi
# Inside-out signing (Sparkle's helpers first, never --deep): one identity for everything, so the designated
# requirement stays the same from release to release (Sparkle and the camera / microphone permissions rely on it).
IDENTITY="${VALSE_SIGN_IDENTITY:--}"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }
if [[ "$IDENTITY" == - ]]; then
  { for x in "$SPK"/XPCServices/*.xpc "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" ${HELPERS[@]+"${HELPERS[@]}"}; do
      [[ -e "$x" ]] && sign "$x"; done; sign "$APP"; } >/dev/null 2>&1 || echo "warning: codesign failed" >&2
else
  for x in "$SPK"/XPCServices/*.xpc "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" ${HELPERS[@]+"${HELPERS[@]}"}; do
    [[ -e "$x" ]] && sign "$x"
  done
  sign "$APP"
  codesign --verify --deep --strict "$APP"
fi
echo "$APP"
