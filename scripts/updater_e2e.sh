#!/bin/bash
# End-to-end check of automatic updates (SE-015), offline and invisible: builds a test copy of Montage (bundle id
# fr.montage.MontageUpdateTest, throwaway EdDSA key, feed + push stream on a localhost server, scripts/updater_e2e_server.py)
# as version 1 and 2, then runs version 1 offscreen (MONTAGE_UPDATER_TEST=1, --quit-after quits it) twice:
#   launch: version 2 is already published → the launch check downloads it, it installs when the app quits
#   push:   nothing new at launch; version 2 is published and pushed while the app runs → it downloads, installs on quit
# Signs with MONTAGE_SIGN_IDENTITY when set (the release identity), else ad-hoc. Needs an OpenSSL with Ed25519
# (Homebrew's). Not a gate: run it after changing the updater, Sparkle, build_app.sh or release_appcast.py.
# Usage: scripts/updater_e2e.sh [--no-build]
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,9p' "$0"; exit 0; fi
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
rm -rf "$WORK"; mkdir -p "$WORK/v1" "$WORK/v2" "$WORK/release/deltas" "$WORK/www"

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
    -c "Set :MontageUpdatePushURL http://127.0.0.1:$PORT/push/json" \
    -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$p"
  codesign --force --timestamp=none --sign "$IDENTITY" "$1/Montage.app" 2>/dev/null
}
variant "$WORK/v1" 0.0.1 1
variant "$WORK/v2" 0.0.2 2
ditto -c -k --sequesterRsrc --keepParent "$WORK/v2/Montage.app" "$WORK/release/Montage.zip"
"$SPARKLE_BIN/BinaryDelta" create "$WORK/v1/Montage.app" "$WORK/v2/Montage.app" "$WORK/release/deltas/Montage2-1.delta"
python3 -I scripts/release_appcast.py --version 0.0.2 --build 2 --repo test/test --tag v0.0.2 \
  --sign-update "$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/private.key" --base-url "http://127.0.0.1:$PORT/" \
  --zip "$WORK/release/Montage.zip" --deltas "$WORK/release/deltas" > "$WORK/release/appcast.xml"
mv "$WORK/release/deltas/Montage2-1.delta" "$WORK/release/"
EMPTY='<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Montage</title></channel></rss>'
publish() { cp "$WORK/release/Montage.zip" "$WORK/release/Montage2-1.delta" "$WORK/release/appcast.xml" "$WORK/www/"; }

python3 -I scripts/updater_e2e_server.py "$PORT" "$WORK/www" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

FAILED=0
scenario() {  # <name>: runs the installed version 1 for 25 s, expects version 2 installed after the quit
  local name="$1" app="$WORK/install-$1/Montage.app" v="?"
  echo "▶ $name: launching version 1 offscreen"
  MONTAGE_UPDATER_TEST=1 "$app/Contents/MacOS/Montage" --background --offscreen --home-demo 0 --quit-after 25 \
    > "$WORK/app-$name.log" 2>&1 || true
  for _ in $(seq 1 60); do
    v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || echo "?")"
    [[ "$v" == 2 ]] && break
    sleep 1
  done
  if [[ "$v" == 2 ]] && codesign --verify --deep --strict "$app" 2>/dev/null; then
    echo "  ✔ $name: installed bundle is version 2, signature valid"
  else
    echo "  ✘ $name: installed CFBundleVersion = $v (logs: $WORK/app-$name.log, $WORK/server.log)"; FAILED=1
  fi
}

# 1. launch check
mkdir -p "$WORK/install-launch" && ditto "$WORK/v1/Montage.app" "$WORK/install-launch/Montage.app"
publish
scenario launch

# 2. push while running: nothing at launch, then publish + push after 6 s
mkdir -p "$WORK/install-push" && ditto "$WORK/v1/Montage.app" "$WORK/install-push/Montage.app"
rm -f "$WORK/www/"*; printf '%s' "$EMPTY" > "$WORK/www/appcast.xml"
LINES_BEFORE="$(wc -l < "$WORK/server.log")"
( sleep 6; publish; touch "$WORK/www/.push" ) &
scenario push
PUSH_LOG="$(tail -n +"$((LINES_BEFORE + 1))" "$WORK/server.log")"
grep -q "push message sent" <<< "$PUSH_LOG" || { echo "  ✘ push: the app never opened the push stream"; FAILED=1; }
[[ "$(grep -c 'GET /appcast.xml' <<< "$PUSH_LOG")" -ge 2 ]] || { echo "  ✘ push: expected a launch check and a pushed check"; FAILED=1; }
grep -q 'GET /Montage2-1.delta' <<< "$PUSH_LOG" && echo "  (downloaded the delta)"

echo "requests:"; grep -oE '"GET [^"]+" [0-9]+|push [a-z ]+' "$WORK/server.log" | sed 's/^/  /'
if [[ $FAILED == 0 ]]; then echo "✔ UPDATER E2E OK (launch check + push)"; else echo "✘ UPDATER E2E FAILED"; exit 1; fi
