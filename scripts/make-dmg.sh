#!/bin/zsh
# Packages a built .app into a compressed, signed disk image: dist/<AppName>-<version>.dmg
# The image holds the app plus an "Applications" shortcut (drag-to-install).
#   APP=build/Eko.app   bundle to package (default)
#   SIGN_IDENTITY=…     DMG signing identity (default: the identity that signed the app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/Eko.app}"
[[ -d "$APP" ]] || { echo "No app at $APP. Run ./scripts/bundle.sh first."; exit 1; }
APP_NAME="$(basename "$APP" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(codesign -d -vv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # ad-hoc when the app has no certificate chain
fi

DMG="dist/${APP_NAME}-${VERSION}.dmg"
mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"

SIGN_FLAGS=(--force)
[[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose=1 "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1); signed with: $SIGN_IDENTITY)"
