# Eko — notes for Claude

Native macOS menu-bar call recorder (Swift, SwiftPM, no dependencies). See README.md.

## Installing for a user

- Default: `sh scripts/get-eko.sh` — installs the latest signed release into /Applications.
  No build tools needed. Use it unless the user asks to build from source.
- From source (only if asked; needs Command Line Tools): `./scripts/install.sh`. It creates a
  local "Eko Dev" certificate; macOS may show a keychain prompt the user must approve.
- After installing, tell the user to click the menu-bar waveform → Start Recording and approve
  the Microphone and System Audio Recording prompts. Claude cannot approve those.
- Test recording: `open eko://start`, then `open eko://stop`; files land in
  ~/Documents/CallRecordings (or the folder chosen in the menu).

## Don't, unless the user explicitly asks

- Run `scripts/uninstall.sh` or delete/regenerate the "Eko Dev" certificate (it is the release
  signing key on the maintainer's Mac).
- Read, move or upload recordings: they are private call audio.

## Development

- Tests: `swift test`. Build app: `./scripts/bundle.sh`. CLI: `swift build -c release`.
- Releasing: see "Releasing (maintainers)" in README.md.
