#!/bin/zsh
# One-shot install: builds Eko, signs it with a local certificate, copies it to /Applications
# (or ~/Applications if /Applications is not writable) and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run:  xcode-select --install   then re-run this script."
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install the Command Line Tools (xcode-select --install) and retry."
  exit 1
fi

./scripts/make-signing-cert.sh
./scripts/bundle.sh

DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

pkill -x Eko 2>/dev/null || true
rm -rf "$DEST/Eko.app"
cp -R build/Eko.app "$DEST/"
# Register with Launch Services and Spotlight right away (Cmd+Space, "Open With", URL scheme).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Eko.app" >/dev/null 2>&1 || true
mdimport "$DEST/Eko.app" >/dev/null 2>&1 || true
open "$DEST/Eko.app"

cat <<MSG

Installed $DEST/Eko.app and launched it (look for the waveform icon in the menu bar).

First recording: click the icon > Start Recording (or press ⌃⌥⌘R) and approve the two
macOS prompts: Microphone, then System Audio Recording. They are asked once.
Recordings go to ~/Documents/CallRecordings. Log: ~/Library/Logs/Eko.log
MSG
