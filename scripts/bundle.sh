#!/bin/zsh
# Builds the menu-bar app and wraps it in a signed .app bundle at build/<AppName>.app
#   UNIVERSAL=1      build arm64 + x86_64 slices and merge them (release builds)
#   SIGN_IDENTITY=…  override the signing identity (auto: "Eko Dev" if present, else ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Eko}"
BUNDLE_ID="${BUNDLE_ID:-com.altslate.eko}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
# GitHub "owner/name" whose Releases host the DMGs; the in-app updater checks it. Empty disables updates.
UPDATE_REPO="${UPDATE_REPO-AltSlate-Labs/eko}"
ENTITLEMENTS="Resources/Eko.entitlements"

# Signing identity: "Eko Dev" (see scripts/make-signing-cert.sh) when present, else ad-hoc ("-").
# Ad-hoc signatures change on every build, so macOS re-asks for permissions each time.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Eko Dev"'; then
    SIGN_IDENTITY="Eko Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/${APP_NAME}"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # SwiftPM's --arch flag needs Xcode's xcbuild; building each triple separately works with
  # the Command Line Tools alone, then lipo merges the slices.
  for triple in arm64-apple-macosx x86_64-apple-macosx; do
    swift build -c release --product EkoApp --triple "$triple"
  done
  lipo -create -output "$BIN" \
    .build/arm64-apple-macosx/release/EkoApp \
    .build/x86_64-apple-macosx/release/EkoApp
else
  swift build -c release --product EkoApp
  cp .build/release/EkoApp "$BIN"
fi

[[ -f Resources/AppIcon.icns ]] || ./scripts/make-icns.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>EkoUpdateRepository</key><string>${UPDATE_REPO}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}.control</string>
      <key>CFBundleURLSchemes</key><array><string>$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')</string></array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>${APP_NAME} records your microphone so your side of the call is in the recording.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>${APP_NAME} records the audio the Mac is playing so the other participants are in the recording.</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# Hardened runtime + entitlements on every build so dev and release behave the same; the
# secure timestamp (needed for notarization) only applies to a real Developer ID identity.
SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")
[[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP v${VERSION} ($(lipo -archs "$BIN"); signed with: $SIGN_IDENTITY)"
