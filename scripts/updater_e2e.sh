#!/bin/bash
# End-to-end check of automatic updates (SE-015) and of the Montage → Valse bridge, offline and invisible. Test copies
# (bundle ids fr.montage.MontageUpdateTest / fr.valse.ValseUpdateTest, throwaway EdDSA key, feed + push stream on a
# localhost server, scripts/updater_e2e_server.py), all run offscreen with --quit-after:
#   old      a pre-rename Montage (built from --old-ref, default the last commit before the rename) as build 1
#   bridge   this checkout as build 2, archived as Montage.app (Valse-bridge.zip, item without channel)
#   channel  this checkout as build 3, archived as Valse.app (Valse.zip + delta from 2, item on the `valse` channel)
# Scenarios:
#   1. bridge:   old (Montage.app) + appcast [bridge] → installs build 2 into Montage.app on quit; its first launch
#                renames the bundle to Valse.app and migrates settings, folders (sandboxed home), keychain item, and
#                an old .montage project (old content IDs, media in the old Application Support) opens complete
#   2. channel:  that migrated Valse.app + appcast [bridge, channel] → updates to build 3 (Valse.app, delta or zip)
#   3. skipped:  a fresh old copy + appcast [bridge, channel] (it skipped the bridge release) → lands on build 2, not 3
#   4. push:     a Valse build 2 sees nothing at launch; build 3 is published and pushed while it runs → installs on quit
# Folders are migrated inside a sandboxed home (CFFIXED_USER_HOME), never the real ~/Library or ~/Movies; settings use
# the test domains above (deleted before and after), the keychain a test service. Signs with VALSE_SIGN_IDENTITY when
# set, else ad-hoc. Needs an OpenSSL with Ed25519 (Homebrew's). Not a gate: run it after changing the updater, Sparkle,
# the migration, build_app.sh, release.sh or release_appcast.py.
# Usage: scripts/updater_e2e.sh [--no-build] [--old-ref <git ref>]
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,20p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD=1; OLD_REF="a89916ad"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift;;
    --old-ref) OLD_REF="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
WORK="$ROOT/build/updater_e2e"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OPENSSL=""
for o in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
  if "$o" genpkey -algorithm ed25519 >/dev/null 2>&1; then OPENSSL="$o"; break; fi
done
[[ -n "$OPENSSL" ]] || { echo "✘ no OpenSSL with Ed25519 (brew install openssl)"; exit 1; }
IDENTITY="${VALSE_SIGN_IDENTITY:--}"
PORT=$((20000 + RANDOM % 20000))
OLD_ID=fr.montage.MontageUpdateTest
NEW_ID=fr.valse.ValseUpdateTest
KC_OLD=fr.montage.online-audio.updater-e2e   # the test copies' keychain services (KeychainSecretStore)
KC_NEW=fr.valse.online-audio.updater-e2e
cleanup_prefs() {
  defaults delete "$OLD_ID" >/dev/null 2>&1 || true; defaults delete "$NEW_ID" >/dev/null 2>&1 || true
  security delete-generic-password -s "$KC_OLD" -a freesound >/dev/null 2>&1 || true
  security delete-generic-password -s "$KC_NEW" -a freesound >/dev/null 2>&1 || true
}
cleanup_prefs
rm -rf "$WORK"; mkdir -p "$WORK/www" "$WORK/release/deltas"

# --- builds ------------------------------------------------------------------------------------------------------------
[[ $BUILD == 0 ]] || scripts/build_app.sh --host-only --no-content >/dev/null
OLD_SHA="$(/usr/bin/git rev-parse --short "$OLD_REF")"
OLD_SRC="$ROOT/build/updater_e2e_old/$OLD_SHA"      # kept between runs: the old build is slow
if [[ ! -x "$OLD_SRC/build/Montage.app/Contents/MacOS/Montage" ]]; then
  echo "▶ building the pre-rename app from $OLD_REF ($OLD_SHA), once"
  rm -rf "$OLD_SRC"; mkdir -p "$OLD_SRC"
  /usr/bin/git archive "$OLD_REF" | tar -x -C "$OLD_SRC"
  (cd "$OLD_SRC" && scripts/build_app.sh --host-only --no-content >/dev/null)
fi

# throwaway key: Sparkle wants the base64 32-byte seed (private) and 32-byte public key
"$OPENSSL" genpkey -algorithm ed25519 -outform DER -out "$WORK/key.der"
tail -c 32 "$WORK/key.der" | base64 > "$WORK/private.key"
PUB="$("$OPENSSL" pkey -inform DER -in "$WORK/key.der" -pubout -outform DER | tail -c 32 | base64)"

variant() {  # <source .app> <dest .app> <bundle id> <push key> <version> <build>
  ditto "$1" "$2"
  local p="$2/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $3" \
    -c "Set :CFBundleShortVersionString $5" -c "Set :CFBundleVersion $6" \
    -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" -c "Set :SUPublicEDKey $PUB" \
    -c "Set :$4 http://127.0.0.1:$PORT/push/json" \
    -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$p"
  codesign --force --timestamp=none --sign "$IDENTITY" "$2" 2>/dev/null
}
mkdir -p "$WORK/v1" "$WORK/v2" "$WORK/v3"
variant "$OLD_SRC/build/Montage.app" "$WORK/v1/Montage.app" "$OLD_ID" MontageUpdatePushURL 0.0.1 1
variant build/Valse.app "$WORK/v2/Valse.app" "$NEW_ID" ValseUpdatePushURL 0.0.2 2
variant build/Valse.app "$WORK/v3/Valse.app" "$NEW_ID" ValseUpdatePushURL 0.0.3 3
# the bridge archive: build 2 under the pre-rename bundle name (what release.sh --bridge publishes)
mkdir -p "$WORK/v2b" && ditto "$WORK/v2/Valse.app" "$WORK/v2b/Montage.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK/v2b/Montage.app" "$WORK/release/Valse-bridge.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK/v3/Valse.app" "$WORK/release/Valse.zip"
"$SPARKLE_BIN/BinaryDelta" create "$WORK/v2/Valse.app" "$WORK/v3/Valse.app" "$WORK/release/deltas/Valse3-2.delta"
appcast() {  # <bridge|channel> → stdout
  if [[ $1 == bridge ]]; then
    python3 -I scripts/release_appcast.py --version 0.0.2 --build 2 --repo test/test --tag v0.0.2 --bridge \
      --sign-update "$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/private.key" --base-url "http://127.0.0.1:$PORT/" \
      --zip "$WORK/release/Valse-bridge.zip"
  else
    python3 -I scripts/release_appcast.py --version 0.0.3 --build 3 --repo test/test --tag v0.0.3 \
      --sign-update "$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/private.key" --base-url "http://127.0.0.1:$PORT/" \
      --zip "$WORK/release/Valse.zip" --deltas "$WORK/release/deltas" --previous-appcast "$WORK/release/appcast-bridge.xml"
  fi
}
appcast bridge > "$WORK/release/appcast-bridge.xml"
appcast channel > "$WORK/release/appcast-channel.xml"
grep -q "<sparkle:channel>valse</sparkle:channel>" "$WORK/release/appcast-channel.xml" \
  && [[ "$(grep -c "<item>" "$WORK/release/appcast-channel.xml")" == 2 ]] || { echo "✘ the channel appcast lacks the bridge or channel item"; exit 1; }
EMPTY='<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Valse</title></channel></rss>'
serve() {  # <bridge|channel|empty>
  rm -f "$WORK/www/"*
  case "$1" in
    empty) printf '%s' "$EMPTY" > "$WORK/www/appcast.xml";;
    *) cp "$WORK/release/Valse-bridge.zip" "$WORK/release/Valse.zip" "$WORK/release/deltas/Valse3-2.delta" "$WORK/www/"
       cp "$WORK/release/appcast-$1.xml" "$WORK/www/appcast.xml";;
  esac
}

python3 -I scripts/updater_e2e_server.py "$PORT" "$WORK/www" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; cleanup_prefs' EXIT
sleep 1

FAILED=0
ok() { echo "  ✔ $*"; }
ko() { echo "  ✘ $*"; FAILED=1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
wait_build() {  # <app> <build>: waits ≤ 60 s for the installed bundle to be that build
  for _ in $(seq 1 60); do [[ "$(plist "$1" CFBundleVersion)" == "$2" ]] && return 0; sleep 1; done; return 1
}
run_old() {  # <app> <log>: the pre-rename copy (reads MONTAGE_UPDATER_TEST)
  MONTAGE_UPDATER_TEST=1 "$1/Contents/MacOS/Montage" --background --offscreen --home-demo 0 --quit-after 25 > "$2" 2>&1 || true
}
run_new() {  # <app> <log> [extra env…]: a Valse copy
  local app="$1" log="$2"; shift 2
  env VALSE_UPDATER_TEST=1 "$@" "$app/Contents/MacOS/Valse" --background --offscreen --home-demo 0 --quit-after 25 > "$log" 2>&1 || true
}

# --- 1. bridge ---------------------------------------------------------------------------------------------------------
echo "▶ 1. bridge: pre-rename copy, appcast with the bridge item"
I1="$WORK/install-bridge"; mkdir -p "$I1" && ditto "$WORK/v1/Montage.app" "$I1/Montage.app"
serve bridge
run_old "$I1/Montage.app" "$WORK/app-1-old.log"
if wait_build "$I1/Montage.app" 2 && [[ "$(plist "$I1/Montage.app" CFBundleIdentifier)" == "$NEW_ID" ]]; then
  ok "the old copy installed the bridge build into Montage.app (bundle id $NEW_ID)"
else
  ko "after the update Montage.app is build $(plist "$I1/Montage.app" CFBundleVersion) ($(plist "$I1/Montage.app" CFBundleIdentifier)); logs: $WORK/app-1-old.log"
fi
# legacy data for the first launch: a sandboxed home with the old folders, the old settings domain, a keychain item
HOME_E2E="$WORK/home"
LS="$HOME_E2E/Library/Application Support/Montage"
mkdir -p "$LS/Models/e2e-model" "$LS/Pasted Media" "$HOME_E2E/Library/Caches/Montage/thumbs" "$HOME_E2E/Movies/Montage"
printf 'model' > "$LS/Models/e2e-model/weights.bin"
printf 'thumb' > "$HOME_E2E/Library/Caches/Montage/thumbs/t.jpg"
python3 -I scripts/updater_e2e_fixture.py "$ROOT/app/Tests/UIScripts/fixtures/legacy/Old Film.montage" "$HOME_E2E" \
  "$HOME_E2E/Movies/Montage/Old Film.montage" >/dev/null
defaults write "$OLD_ID" MontageHomeSort -string name
defaults write "$OLD_ID" montage.media.sort -string duration
defaults write "$OLD_ID" montage.assets.favoriteEffects -array montage.effect.blur montage.filter.warm
security add-generic-password -s "$KC_OLD" -a freesound -w e2e-secret -A >/dev/null
# first launch from Montage.app: renames itself to Valse.app (VALSE_SELF_RENAME: also in this tooling launch) and
# migrates; nothing is published beyond the bridge, so it stays build 2
run_new "$I1/Montage.app" "$WORK/app-1-first.log" VALSE_SELF_RENAME=1 CFFIXED_USER_HOME="$HOME_E2E" \
  VALSE_LEGACY_DEFAULTS_DOMAIN="$OLD_ID"
A1="$I1/Valse.app"
if [[ -d "$A1" && ! -e "$I1/Montage.app" && "$(plist "$A1" CFBundleIdentifier)" == "$NEW_ID" ]]; then
  ok "first launch renamed the bundle: $A1"
else
  ko "no Valse.app after the first launch (log: $WORK/app-1-first.log)"; A1="$I1/Montage.app"
fi
NS="$HOME_E2E/Library/Application Support/Valse"
if [[ -f "$NS/Models/e2e-model/weights.bin" && ! -e "$LS" && -f "$HOME_E2E/Library/Caches/Valse/thumbs/t.jpg" \
      && -d "$HOME_E2E/Movies/Valse/Old Film.montage" && ! -e "$HOME_E2E/Movies/Montage" ]]; then
  ok "folders moved (Application Support, Caches, Movies library); the .montage project kept its name"
else
  ko "folders not migrated: $(cd "$HOME_E2E" && find . -maxdepth 4 -type d | sort | tr '\n' ' ')"
fi
[[ "$(defaults read "$NEW_ID" ValseHomeSort 2>/dev/null)" == name && "$(defaults read "$NEW_ID" valse.media.sort 2>/dev/null)" == duration ]] \
  && defaults read "$NEW_ID" valse.assets.favoriteEffects 2>/dev/null | grep -q "valse.effect.blur" \
  && ok "settings migrated (renamed keys, content IDs in values)" || ko "settings not migrated: $(defaults read "$NEW_ID" 2>&1 | head -20)"
[[ "$(security find-generic-password -s "$KC_NEW" -a freesound -w 2>/dev/null)" == e2e-secret ]] \
  && ok "keychain item copied to the new service" || ko "keychain item not migrated"
grep -q "/Movies/Valse/Old Film.montage" "$NS/library.json" 2>/dev/null && ! grep -q "/Movies/Montage/" "$NS/library.json" \
  && ok "library index paths rewritten" || ko "library.json still points at the old folder: $(cat "$NS/library.json" 2>&1)"
CHECK="$(CFFIXED_USER_HOME="$HOME_E2E" "$A1/Contents/MacOS/Valse" --check-project "$HOME_E2E/Movies/Valse/Old Film.montage" 2>&1 || true)"
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1].strip().splitlines()[-1]); sys.exit(0 if d["ok"] and d["clips"] > 0 and not d["legacyIDs"] and not d["unknownIDs"] and not d["missingMedia"] else 1)' "$CHECK" \
  && ok "the old .montage project opens: $(tail -1 <<< "$CHECK")" || ko "old project check: $CHECK"

# --- 2. channel --------------------------------------------------------------------------------------------------------
echo "▶ 2. channel: the migrated copy, appcast with the bridge and the channel item"
serve channel
run_new "$A1" "$WORK/app-2.log"
wait_build "$A1" 3 && codesign --verify --deep --strict "$A1" 2>/dev/null && [[ -d "$A1" ]] \
  && ok "updated to build 3 in place ($A1)" || ko "migrated copy is build $(plist "$A1" CFBundleVersion) (log $WORK/app-2.log)"

# --- 3. skipped bridge -------------------------------------------------------------------------------------------------
echo "▶ 3. skipped: a pre-rename copy that missed the bridge release"
I3="$WORK/install-skip"; mkdir -p "$I3" && ditto "$WORK/v1/Montage.app" "$I3/Montage.app"
defaults delete "$OLD_ID" >/dev/null 2>&1 || true
run_old "$I3/Montage.app" "$WORK/app-3.log"
wait_build "$I3/Montage.app" 2 && [[ "$(plist "$I3/Montage.app" CFBundleIdentifier)" == "$NEW_ID" ]] \
  && ok "it took the bridge (build 2), not the channel build" || ko "old copy is build $(plist "$I3/Montage.app" CFBundleVersion) (log $WORK/app-3.log)"

# --- 4. push -----------------------------------------------------------------------------------------------------------
echo "▶ 4. push: nothing at launch, build 3 pushed while build 2 runs"
I4="$WORK/install-push"; mkdir -p "$I4" && ditto "$WORK/v2/Valse.app" "$I4/Valse.app"
serve empty
LINES_BEFORE="$(wc -l < "$WORK/server.log")"
( sleep 6; serve channel; touch "$WORK/www/.push" ) &
run_new "$I4/Valse.app" "$WORK/app-4.log"
wait_build "$I4/Valse.app" 3 && ok "pushed update installed (build 3)" || ko "push copy is build $(plist "$I4/Valse.app" CFBundleVersion)"
PUSH_LOG="$(tail -n +"$((LINES_BEFORE + 1))" "$WORK/server.log")"
grep -q "push message sent" <<< "$PUSH_LOG" || ko "push: the app never opened the push stream"
[[ "$(grep -c 'GET /appcast.xml' <<< "$PUSH_LOG")" -ge 2 ]] || ko "push: expected a launch check and a pushed check"
grep -q 'GET /Valse3-2.delta' "$WORK/server.log" && echo "  (a delta was downloaded)"

echo "requests:"; grep -oE '"GET [^"]+" [0-9]+|push [a-z ]+' "$WORK/server.log" | sed 's/^/  /'
if [[ $FAILED == 0 ]]; then echo "✔ UPDATER E2E OK (bridge + migration, channel, skipped bridge, push)"; else echo "✘ UPDATER E2E FAILED"; exit 1; fi
