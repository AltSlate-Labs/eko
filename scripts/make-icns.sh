#!/bin/zsh
# Builds Resources/AppIcon.icns from scripts/make-icon.swift (no external tools needed).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  swift scripts/make-icon.swift $s "$SET/icon_${s}x${s}.png"
  swift scripts/make-icon.swift $((s*2)) "$SET/icon_${s}x${s}@2x.png"
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
