#!/bin/sh
# Installs or updates Eko from the latest GitHub release, for Macs without the App Store path:
#
#   curl -fsSL https://raw.githubusercontent.com/AltSlate-Labs/eko/main/scripts/get-eko.sh | sh
#
# Downloads the release DMG and its .sha256, verifies the checksum, clears the quarantine flag
# (this is the step that skips Gatekeeper's "Apple could not verify" dialog, so only run it for a
# source you trust), copies Eko to /Applications and launches it. Safe to re-run: it replaces the
# installed copy and keeps settings, permissions and recordings.
#   EKO_VERSION=v0.1.1   install that release instead of the latest
#   EKO_DEST=~/Applications   install somewhere else
#   GITHUB_TOKEN=…        needed only while the repository is private
set -eu

REPO="${EKO_REPO:-AltSlate-Labs/eko}"
API="https://api.github.com/repos/$REPO/releases/${EKO_VERSION:+tags/}${EKO_VERSION:-latest}"
DEST="${EKO_DEST:-/Applications}"
AUTH=""
[ -n "${GITHUB_TOKEN:-}" ] && AUTH="Authorization: Bearer $GITHUB_TOKEN"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() { hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

json="$(curl -fsSL -H "Accept: application/vnd.github+json" ${AUTH:+-H "$AUTH"} "$API")" \
  || { echo "Could not read release information from $API (is the repository public, or GITHUB_TOKEN set?)" >&2; exit 1; }
tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"

# Prints the download URL of the asset whose name ends with $1 (e.g. ".dmg"). The asset's API
# "url" line precedes its "name" line in the release JSON; private repos must use the API URL.
asset_url() {
  printf '%s' "$json" | tr ',' '\n' | awk -v suffix="$1" -v private="$AUTH" '
    /"url": *"https:\/\/api\.github\.com\/[^"]*\/releases\/assets\/[0-9]+"/ { api=$0; sub(/.*"url": *"/, "", api); sub(/".*/, "", api) }
    /"name": *"/ && api != "" { n=$0; sub(/.*"name": *"/, "", n); sub(/".*/, "", n)
      if (length(n) >= length(suffix) && substr(n, length(n) - length(suffix) + 1) == suffix) { want=api } }
    /"browser_download_url": *"/ && want != "" && api == want { b=$0; sub(/.*"browser_download_url": *"/, "", b); sub(/".*/, "", b)
      print (private != "" ? api : b); exit }
  '
}
fetch() {  # url file
  if [ -n "$AUTH" ]; then
    # Private releases: the API redirects to short-lived storage that must not see the token.
    loc="$(curl -fsS -o /dev/null -w '%{redirect_url}' -H "Accept: application/octet-stream" -H "$AUTH" "$1")"
    curl -fsSL -o "$2" "$loc"
  else
    curl -fsSL -o "$2" "$1"
  fi
}

dmg_url="$(asset_url .dmg)"
[ -n "$dmg_url" ] || { echo "Release $tag has no .dmg attached." >&2; exit 1; }
sum_url="$(asset_url .dmg.sha256)"
name="$(printf '%s' "$json" | grep -o '"name": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\([^"]*\.dmg\)"/\1/')"
[ -n "$name" ] || name="Eko.dmg"

echo "Downloading Eko ${tag}..."
fetch "$dmg_url" "$TMP/$name"
if [ -n "$sum_url" ]; then
  fetch "$sum_url" "$TMP/$name.sha256"
  (cd "$TMP" && shasum -a 256 -c "$name.sha256" >/dev/null) || { echo "Checksum mismatch; the download was not installed." >&2; exit 1; }
else
  echo "warning: release has no .sha256 file; checksum not verified" >&2
fi

xattr -d com.apple.quarantine "$TMP/$name" 2>/dev/null || true
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$TMP/$name"
app="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "The disk image contains no app." >&2; exit 1; }
appname="$(basename "$app")"

if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
if pkill -x "${appname%.app}" 2>/dev/null; then sleep 1; fi
rm -rf "$DEST/$appname"
ditto "$app" "$DEST/$appname"
xattr -dr com.apple.quarantine "$DEST/$appname" 2>/dev/null || true
hdiutil detach -quiet "$MNT"
open "$DEST/$appname"
echo "Installed $DEST/$appname ($tag). Look for the waveform icon in the menu bar; approve the Microphone and System Audio prompts on the first recording."
