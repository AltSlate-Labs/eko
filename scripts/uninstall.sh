#!/bin/zsh
# Removes the app, its settings, its signing certificate and its privacy grants.
# Recordings in ~/Documents/CallRecordings are left untouched.
set -uo pipefail
pkill -x Eko 2>/dev/null || true
rm -rf /Applications/Eko.app "$HOME/Applications/Eko.app"
defaults delete com.altslate.eko 2>/dev/null || true
tccutil reset Microphone com.altslate.eko 2>/dev/null || true
tccutil reset AudioCapture com.altslate.eko 2>/dev/null || true
security delete-identity -c "Eko Dev" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
rm -f "$HOME/Library/Logs/Eko.log"
echo "Eko removed. Recordings kept in ~/Documents/CallRecordings."
