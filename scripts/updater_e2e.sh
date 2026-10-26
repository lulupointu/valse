#!/bin/bash
# End-to-end check of automatic updates (SE-015), offline and invisible: builds a test copy of Montage (bundle id
# fr.montage.MontageUpdateTest, throwaway EdDSA key, feed on a localhost server) as version 1 and 2, serves version 2's
# zip + delta + appcast, launches version 1 offscreen (MONTAGE_UPDATER_TEST=1: checks at launch, --quit-after quits),
# and expects the installed bundle to be version 2 after the quit (silent download, install on quit).
# Signs with MONTAGE_SIGN_IDENTITY when set (the release identity), else ad-hoc. Needs an OpenSSL with Ed25519
# (Homebrew's). Not a gate: run it after changing the updater, Sparkle, build_app.sh or release_appcast.py.
# Usage: scripts/updater_e2e.sh [--no-build]
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,8p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$ROOT/build/updater_e2e"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OPENSSL=""
for o in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
  if "$o" genpkey -algorithm ed25519 >/dev/null 2>&1; then OPENSSL="$o"; break; fi
done
[[ -n "$OPENSSL" ]] || { echo "✘ no OpenSSL with Ed25519 (brew install openssl)"; exit 1; }
IDENTITY="${MONTAGE_SIGN_IDENTITY:--}"
PORT=$((20000 + RANDOM % 20000))
rm -rf "$WORK"; mkdir -p "$WORK/v1" "$WORK/v2" "$WORK/www/deltas" "$WORK/install"

[[ "${1:-}" == --no-build ]] || scripts/build_app.sh --host-only --no-content >/dev/null

# throwaway key: Sparkle wants the base64 32-byte seed (private) and 32-byte public key
"$OPENSSL" genpkey -algorithm ed25519 -outform DER -out "$WORK/key.der"
tail -c 32 "$WORK/key.der" | base64 > "$WORK/private.key"
PUB="$("$OPENSSL" pkey -inform DER -in "$WORK/key.der" -pubout -outform DER | tail -c 32 | base64)"

variant() {  # <dir> <version> <build>
  ditto build/Montage.app "$1/Montage.app"
  local p="$1/Montage.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.montage.MontageUpdateTest" \
    -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" \
    -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" -c "Set :SUPublicEDKey $PUB" \
    -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$p"
  codesign --force --timestamp=none --sign "$IDENTITY" "$1/Montage.app" 2>/dev/null
}
variant "$WORK/v1" 0.0.1 1
variant "$WORK/v2" 0.0.2 2
ditto -c -k --sequesterRsrc --keepParent "$WORK/v2/Montage.app" "$WORK/www/Montage.zip"
"$SPARKLE_BIN/BinaryDelta" create "$WORK/v1/Montage.app" "$WORK/v2/Montage.app" "$WORK/www/deltas/Montage2-1.delta"
python3 -I scripts/release_appcast.py --version 0.0.2 --build 2 --repo test/test --tag v0.0.2 \
  --sign-update "$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/private.key" --base-url "http://127.0.0.1:$PORT/" \
  --zip "$WORK/www/Montage.zip" --deltas "$WORK/www/deltas" > "$WORK/www/appcast.xml"
mv "$WORK/www/deltas/Montage2-1.delta" "$WORK/www/"

ditto "$WORK/v1/Montage.app" "$WORK/install/Montage.app"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

echo "▶ launching version 1 offscreen (feed http://127.0.0.1:$PORT/appcast.xml)"
MONTAGE_UPDATER_TEST=1 "$WORK/install/Montage.app/Contents/MacOS/Montage" --background --offscreen --home-demo 0 \
  --quit-after 25 > "$WORK/app.log" 2>&1 || true
echo "▶ quit; waiting for the installer"
for _ in $(seq 1 60); do
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WORK/install/Montage.app/Contents/Info.plist" 2>/dev/null || echo "?")"
  [[ "$v" == 2 ]] && break
  sleep 1
done
echo "requests:"; grep -oE '"GET [^"]+" [0-9]+' "$WORK/server.log" | sed 's/^/  /'
if [[ "$v" == 2 ]] && codesign --verify --deep --strict "$WORK/install/Montage.app" 2>/dev/null; then
  grep -q 'GET /Montage2-1.delta' "$WORK/server.log" && how="delta" || how="full zip"
  echo "✔ UPDATER E2E OK: installed bundle is version 2 ($how), signature valid"
else
  echo "✘ UPDATER E2E FAILED: installed CFBundleVersion = $v (logs: $WORK/app.log, $WORK/server.log)"; exit 1
fi
