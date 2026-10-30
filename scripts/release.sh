#!/bin/zsh
# Builds a downloadable release: tests → universal app signed with Developer ID + hardened runtime
# → notarize and staple the app → signed DMG → notarize and staple the DMG → Gatekeeper checks.
# Output: dist/Eko-<version>.dmg (+ .sha256). Nothing is uploaded; attach the DMG to a GitHub Release.
#
#   ./scripts/release.sh --local
# Same build and DMG signed with the local "Eko Dev" certificate, no notarization. Users install it
# with scripts/get-eko.sh; later releases signed with the SAME certificate install through the
# in-app updater. Refuses ad-hoc signing, which would break updates and permissions.
#
# One-time prerequisites (see README > Releasing):
#   1. A "Developer ID Application" certificate in the login keychain (Apple Developer Program).
#   2. Notarization credentials saved in the keychain under a profile name:
#        xcrun notarytool store-credentials eko-notary --apple-id you@example.com --team-id TEAMID
#      (prompts for an app-specific password; nothing is stored in this repo)
#   NOTARY_PROFILE=… / SIGN_IDENTITY=… override the defaults.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Eko}"
NOTARY_PROFILE="${NOTARY_PROFILE:-eko-notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/${APP_NAME}.app"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

LOCAL=0
[[ "${1:-}" == "--local" ]] && LOCAL=1

if [[ $LOCAL == 1 ]]; then
  SIGN_IDENTITY="${SIGN_IDENTITY:-Eko Dev}"
  security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\"" || {
    echo "No \"$SIGN_IDENTITY\" certificate in the keychain. Run ./scripts/make-signing-cert.sh once (and keep"
    echo "a backup of it: every release must be signed with the same certificate for updates to install)."
    exit 1
  }
else
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  fi
  [[ -n "$SIGN_IDENTITY" ]] || {
    echo "No 'Developer ID Application' certificate in the keychain. Releases must be signed with one"
    echo "(Apple Developer Program), or use ./scripts/release.sh --local for a build installed via get-eko.sh."
    exit 1
  }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "No notarization credentials under keychain profile '$NOTARY_PROFILE'. Create them with:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>"
    exit 1
  }
fi

# Submits one file and waits; prints the notary log and fails on anything but "Accepted".
notarize() {
  local out id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  echo "$out"
  if ! grep -q "status: Accepted" <<< "$out"; then
    id="$(sed -n 's/^ *id: //p' <<< "$out" | head -1)"
    echo "Notarization of $1 failed."
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
}

echo "== Tests"
swift test
echo "== Build $APP_NAME $VERSION (universal, hardened runtime, signed with: $SIGN_IDENTITY)"
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/bundle.sh

if [[ $LOCAL == 1 ]]; then
  SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/make-dmg.sh
  codesign --verify --deep --strict --verbose=2 "$APP"
  (cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
  echo "Local release ready: $DMG (not notarized; install with scripts/get-eko.sh)"
  exit 0
fi

echo "== Notarize the app"   # the ticket then travels with the app when it is copied out of the DMG
mkdir -p dist
ZIP="dist/${APP_NAME}-${VERSION}-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"

echo "== Disk image"
SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/make-dmg.sh
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "== Gatekeeper checks"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Release ready: $DMG"
