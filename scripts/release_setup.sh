#!/bin/bash
# Owner, once per release machine: creates the two keys scripts/release.sh signs with (SE-015, docs/RELEASING.md).
#   1. "Valse Release Signing": a self-signed code-signing certificate (20 years) in the login keychain, trusted for
#      code signing. Same certificate for every release = same designated requirement, so Sparkle accepts the update
#      and macOS keeps Valse's camera / microphone / speech permissions.
#   2. Sparkle's EdDSA update key (login keychain item "https://sparkle-project.org"); its public half goes into
#      app/Bundle/Info.plist SUPublicEDKey (printed at the end; commit it).
# Both are backed up into <backup dir> (default ~/ValseReleaseKeys): keep that folder somewhere safe (password
# manager / encrypted drive). Losing the EdDSA key means installed copies can never update again.
# Existing keys are kept (re-running only re-exports the backups). Restore on a new Mac: --import <backup dir>.
# Usage: scripts/release_setup.sh [<backup dir>] | --import <backup dir>
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then sed -n '2,11p' "$0"; exit 0; fi
cd "$(dirname "$0")/.."
NAME="Valse Release Signing"
KC="$HOME/Library/Keychains/login.keychain-db"
IMPORT=""
if [[ "${1:-}" == --import ]]; then IMPORT="$2"; BACKUP="$2"; else BACKUP="${1:-$HOME/ValseReleaseKeys}"; fi
swift package resolve >/dev/null
SPARKLE_BIN="$(cd .build/artifacts/sparkle/Sparkle/bin && pwd)"
mkdir -p "$BACKUP"; chmod 700 "$BACKUP"

# --- 1. code-signing certificate ---------------------------------------------------------------------------------------
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✔ code-signing identity \"$NAME\" already in the keychain"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  if [[ -n "$IMPORT" ]]; then
    cp "$IMPORT/valse-signing.p12" "$TMP/id.p12"; PASS="$(cat "$IMPORT/valse-signing.p12.password")"
    openssl pkcs12 -in "$TMP/id.p12" -passin "pass:$PASS" -nokeys -out "$TMP/cert.pem" 2>/dev/null \
      || openssl pkcs12 -legacy -in "$TMP/id.p12" -passin "pass:$PASS" -nokeys -out "$TMP/cert.pem"
  else
    PASS="$(openssl rand -hex 16)"
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes -subj "/CN=$NAME" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
      -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout "pass:$PASS" -out "$TMP/id.p12"
    cp "$TMP/id.p12" "$BACKUP/valse-signing.p12"; printf %s "$PASS" > "$BACKUP/valse-signing.p12.password"
  fi
  security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
  echo "▶ trusting the certificate for code signing (macOS asks for your login password)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"
  security find-identity -v -p codesigning | grep -q "\"$NAME\"" || { echo "✘ identity not usable for code signing"; exit 1; }
  echo "✔ code-signing identity \"$NAME\" created"
fi

# --- 2. Sparkle EdDSA key ----------------------------------------------------------------------------------------------
if [[ -n "$IMPORT" ]] && ! "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
  "$SPARKLE_BIN/generate_keys" -f "$IMPORT/sparkle-eddsa-private.key"
fi
"$SPARKLE_BIN/generate_keys" >/dev/null   # creates the key only when the keychain has none
[[ -f "$BACKUP/sparkle-eddsa-private.key" ]] || "$SPARKLE_BIN/generate_keys" -x "$BACKUP/sparkle-eddsa-private.key"
chmod 600 "$BACKUP"/* 2>/dev/null || true
PUB="$("$SPARKLE_BIN/generate_keys" -p)"
echo "✔ Sparkle update key ready. Backups: $BACKUP (keep it safe, never commit it)"
CUR="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' app/Bundle/Info.plist 2>/dev/null || true)"
if [[ "$CUR" == "$PUB" ]]; then
  echo "✔ app/Bundle/Info.plist already has this public key"
else
  echo "Public key (Info.plist SUPublicEDKey): $PUB"
  [[ -z "$CUR" ]] || echo "⚠ Info.plist has a DIFFERENT key ($CUR): installed copies only accept updates signed with that one"
fi
