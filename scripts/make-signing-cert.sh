#!/bin/zsh
# Creates a self-signed "Eko Dev" code-signing certificate in your login keychain so the app
# keeps a stable identity across rebuilds (otherwise macOS re-asks for Microphone and
# System Audio Recording permission after every build). Run once; you may be asked for your
# login password by Keychain Access.
set -euo pipefail
NAME="${1:-Eko Dev}"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:tmp -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmp -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
# Let Apple's signing tools use the key without a "codesign wants to access key" dialog on
# every build. Needs your login password once; press Enter to skip and click "Always Allow" instead.
read -rs "PW?Login password (lets codesign use the key silently; Enter to skip): " </dev/tty || PW=""
echo
if [[ -n "$PW" ]]; then
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 \
    || echo "(Could not update key access; click Always Allow when codesign asks for the key.)"
fi
unset PW
# Trust it for code signing (user trust domain; a password dialog may appear).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" || true
security find-identity -v -p codesigning | grep "$NAME"
echo "Done. Rebuild with ./scripts/bundle.sh (it picks \"$NAME\" up automatically)."
