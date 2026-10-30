# Eko

Minimal native macOS menu-bar utility that records your calls (Zoom, Google Meet, Teams,
Slack, FaceTime, …) into one audio file: everything the Mac plays, whichever output is active
(speakers, monitor, earphones, AirPods), mixed with the active microphone.

- One click or one hotkey to start/stop; a floating prompt offers to record when a call starts
- Output: `~/Documents/CallRecordings/yyyy-MM-dd HH-mm <App>.m4a` (AAC 48 kHz stereo, about
  1 MB per minute) plus a small `.json` sidecar with times and the call app heard
- Native Swift, no third-party dependencies, no Xcode needed, ~1 MB download, nothing leaves the Mac

## Requirements

- macOS 14.2 (Sonoma) or newer. Built and tested on macOS 15.5. Apple Silicon or Intel.
- To use the downloaded DMG: nothing else.
- To build from source: Xcode **Command Line Tools** (not full Xcode) and about 2 minutes for
  the first build. If `xcode-select -p` prints nothing, run:

  ```sh
  xcode-select --install
  ```

## Install (no build tools needed)

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/AltSlate-Labs/eko/main/scripts/get-eko.sh | sh
```

It downloads the latest release DMG, verifies its SHA-256 against the release, copies Eko to
Applications and launches it. Re-running it later installs the newest version over the old one;
settings, permissions and recordings are kept. Continue with [First-run setup](#first-run-setup).

**While this repository is private**, GitHub needs a login for both the script and the release.
Collaborators with the GitHub CLI installed and signed in (`gh auth login`) run this instead:

```sh
git clone https://github.com/AltSlate-Labs/eko.git && cd eko
GITHUB_TOKEN=$(gh auth token) sh scripts/get-eko.sh
```

The in-app update check also needs anonymous access, so on a private repository it stays quiet;
re-run the two lines above to update.

Why a script rather than just double-clicking the DMG: releases are signed with the project's own
certificate, not an Apple Developer ID, so macOS shows "Apple could not verify…" for a manually
downloaded copy. The script clears that internet-download flag after checking the checksum. Only
run it if you trust this repository. If you prefer the manual way: download `Eko-<version>.dmg`
from https://github.com/AltSlate-Labs/eko/releases/latest, run
`xattr -d com.apple.quarantine ~/Downloads/Eko-<version>.dmg`, open it, drag **Eko** onto the
**Applications** shortcut, eject, and open Eko from Applications. Opening Eko straight from the
disk image asks you to install it first.

Release images are a universal binary (Apple Silicon and Intel). Should a release ever be signed
with an Apple Developer ID and notarized, the DMG opens like any other downloaded app and the
script is no longer needed.

## Install from source

```sh
git clone https://github.com/AltSlate-Labs/eko.git && cd eko
./scripts/install.sh
```

The script:

1. creates a self-signed "Eko Dev" code-signing certificate in your login keychain (needed so
   macOS remembers the app's permissions across rebuilds; Keychain Access may ask for your
   login password once),
2. builds the app with SwiftPM and signs it,
3. copies it to `/Applications/Eko.app` (or `~/Applications` if that is not writable),
4. registers it with Launch Services and Spotlight, and launches it. A waveform icon appears
   in the menu bar, and Cmd+Space "Eko" opens it from then on.

Prefer to do it by hand? The same steps are `./scripts/make-signing-cert.sh`,
`./scripts/bundle.sh`, `cp -R build/Eko.app /Applications/`, `open /Applications/Eko.app`.

## First-run setup

1. Click the menu-bar icon and choose **Start Recording** (or press **⌃⌥⌘R**).
2. Approve the **Microphone** prompt.
3. Approve the **System Audio Recording** prompt. If it does not appear, open
   System Settings → Privacy & Security → Screen & System Audio Recording → *System Audio
   Recording Only* and enable Eko, then stop and start the recording again.
4. Say something and play any audio, then **Stop Recording**. The file opens with
   "Show Last Recording" in the menu.
5. Optional: enable **Launch at Login** in the menu.

Both permissions are asked only once thanks to the local certificate.

## Everyday use

- **Start / stop**: menu-bar icon, hotkey ⌃⌥⌘R, or `open eko://start` / `open eko://stop`
  (handy for Shortcuts, Raycast or scripts; `eko://toggle` also works).
- **Call prompt**: when a known call app takes the microphone, a panel appears under the menu
  bar: *Record this call?* → **Start recording** / **Not now** (auto-dismisses after 20 s).
  When the app releases the mic while recording, it offers to stop. The menu item
  *When a call starts* can switch this to automatic start and/or stop.
- **Recordings folder**: default `~/Documents/CallRecordings`. Change it from the menu
  (*Recordings Folder → Change…*); the choice is remembered and applies to the next recording.
  The CLI uses `--out DIR`.
- **Icon**: heavy waveform when idle; solid red dot with elapsed time while recording.
- **Updates**: *Check for Updates…* in the menu, or the daily check; see [Update](#update).
- **Quit** while recording stops and saves first.

Press Start before the call connects: the system-audio side only spins up once an app begins
playing, so the first half second of the very first sound can be missed otherwise.

## Update

**Downloaded builds update themselves.** Eko checks GitHub Releases once a day (one HTTPS
request; turn it off with *Check for Updates Daily* in the menu, or check by hand with
*Check for Updates…*). When a newer version exists the menu shows **Update Available: Eko x.y.z**.
Click it to see the version and release notes, then **Download and Install**: Eko downloads
the DMG, opens it, verifies that the new app is signed with the same certificate as the running
copy (same bundle identifier and signing certificate, checked by macOS's code-signing APIs;
anything else is refused and nothing changes), swaps it into place, moves the old version to the
Trash and relaunches. No Gatekeeper dialog appears because the app installs the update itself.
Settings, permissions and recordings are kept. Updates wait until you stop a recording. You can
always re-run the install command instead; it does the same thing.

From source:

```sh
git pull
./scripts/install.sh
```

A source build on another machine is signed with that machine's own certificate, so it keeps
its permissions across rebuilds but will not accept the published DMGs as updates (different
certificate by design); update it with `git pull` as above.

## Uninstall

```sh
./scripts/uninstall.sh
```

Removes the app, its settings, the certificate and its privacy grants. Recordings are kept.

## Troubleshooting

- **Recording is silent or empty.** Check `~/Library/Logs/Eko.log`: while recording it prints
  mic and system peak levels every 2 seconds. `system peak 0.000` throughout while something was
  playing means the System Audio Recording permission is missing (see First-run setup, step 3).
  `mic peak 0.000` throughout means the Microphone permission is missing.
- **Prompt never appears for a Meet call.** Browser detection relies on the browser holding
  the mic; check with `.build/release/eko --watch` during a call. Supported browsers:
  Chrome, Safari, Arc, Brave, Edge, Firefox.
- **Spurious prompt.** Any site using the microphone in a browser looks like a call. Click
  *Not now*, or turn the prompt off under *When a call starts*.
- **"Eko can't be opened" / unidentified developer.** Only happens if the app was downloaded
  rather than built here. Build it with `install.sh`, or run
  `xattr -dr com.apple.quarantine /Applications/Eko.app`.
- **Echo of the remote side.** With speakers plus the built-in mic the remote voice is also
  picked up by the mic. Use headphones.
- **App was force-killed mid-recording.** The `.m4a` will not be finalised. Record with
  `eko --wav` on the command line if crash safety matters more than file size.

## Command line

The same engine is available as a CLI after `swift build -c release`:

```sh
.build/release/eko                   # record until Ctrl-C
.build/release/eko --wav --seconds 30 --out ~/Desktop
.build/release/eko --devices         # default input/output devices
.build/release/eko --apps            # processes playing audio / using the mic
.build/release/eko --watch           # print call start/end detections
EKO_DEBUG=1 .build/release/eko   # diagnostics on stderr
```

## Releasing (maintainers)

Releases are built on one Mac and signed with one certificate that never changes. Installed
copies accept an update only if it is signed with the same certificate as the copy they are
running, so the certificate is the trust root for every user: back it up (Keychain Access →
export "Eko Dev" as a password-protected `.p12`) and never regenerate it.

```sh
./scripts/make-signing-cert.sh          # once per build machine
vi VERSION                               # bump, e.g. 0.1.1
./scripts/release.sh --local             # tests, universal build, signed DMG + .sha256 in dist/
git commit -am "0.1.1" && git push
git tag v0.1.1 && git push origin v0.1.1
gh release create v0.1.1 dist/Eko-0.1.1.dmg dist/Eko-0.1.1.dmg.sha256 --title "Eko 0.1.1"
```

The release tag must be `v<VERSION>`, the repository must be public for the installer and the
updater to reach it, and releases marked *pre-release* are ignored by both (GitHub's "latest"
release excludes them). `UPDATE_REPO` at the top of `scripts/bundle.sh` (default
`AltSlate-Labs/eko`, baked into Info.plist as `EkoUpdateRepository`) must name the GitHub
`owner/name` that hosts the releases.

### Notarized releases (optional, Apple Developer Program)

`./scripts/release.sh` without `--local` produces the same DMG signed with a Developer ID
certificate and notarized: it notarizes and staples the app, wraps it in a signed DMG, notarizes
and staples that too, and finishes with the Gatekeeper checks a user's Mac performs. Such a DMG
opens by double-click without the install script. Switching an existing user base to a Developer
ID is a one-time reinstall for them, because the certificate changes. One-time setup, all outside
the repository:

1. Join the Apple Developer Program and create a **Developer ID Application** certificate
   (developer.apple.com → Certificates; make the signing request in Keychain Access → Certificate
   Assistant → Request a Certificate From a Certificate Authority). Download it and double-click
   to add it to the login keychain. `security find-identity -v -p codesigning` must list it.
2. Create an app-specific password at account.apple.com and store the notarization credentials
   in the keychain (the password is never written to disk in this repo):

   ```sh
   xcrun notarytool store-credentials eko-notary --apple-id <apple-id> --team-id <TEAMID>
   ```

3. Per release: the same commands as above without `--local`.

Only the Command Line Tools are needed; `notarytool` and `stapler` ship with them.

## How it works

Two independent captures feed one time-aligned mixer:

- **Microphone**: an IO proc directly on the default input device. Starts within ~100 ms and
  defines the recording timeline.
- **System audio**: a Core Audio **process tap** (macOS 14.2+) covering every app except this
  one, wrapped in a private aggregate device. macOS deliberately does not run this device until
  some app actually plays audio, and it then keeps running through silence. So the tap is never
  waited on: its buffers are placed into the mix by HAL host timestamp whenever they arrive, and
  silence is written for any stretch where nothing played.

`MixBus` does the alignment and summing (system stereo + mic mono, clamped) and an
`AVAudioFile` encodes AAC on the fly. Call detection polls the Core Audio process list for
known call apps holding an input device. See `PLAN.md` for the alternatives considered.

Two Core Audio quirks worth knowing if you touch the capture code: setting `name` or
`isExclusive` on `CATapDescription` makes the aggregate never run on macOS 15.5, and
`kAudioAggregateDeviceTapAutoStartKey` behaves as described above.

## Repository layout

```
Sources/EkoCore   MicCapture, SystemAudioCapture (tap), MixBus, AudioFileWriter,
                      RecordingSession, CallDetector, process/app detection
Sources/eko       command-line recorder
Sources/EkoApp    SwiftUI menu-bar app, nudge panel, Carbon global hotkey, self-updater
Tests/EkoCoreTests
scripts/get-eko.sh        one-line installer: latest release DMG → checksum → /Applications
scripts/install.sh        build + sign + copy to /Applications + launch (from source)
scripts/bundle.sh         build and sign build/Eko.app (UNIVERSAL=1, APP_NAME, SIGN_IDENTITY)
scripts/make-dmg.sh       wrap build/Eko.app in a signed dist/Eko-<version>.dmg
scripts/release.sh        universal DMG for GitHub Releases (--local: own certificate; default: notarized)
scripts/make-signing-cert.sh   local "Eko Dev" certificate for development builds
scripts/uninstall.sh
Resources/Eko.entitlements     hardened-runtime entitlements (microphone only)
VERSION                   single source of the app version
PLAN.md               design notes and the options that were considered
```

## Privacy and consent

Recordings and settings stay on your Mac. The only network access is the daily update check
(a request to api.github.com for the latest release, then the DMG download when you choose to
install); switch it off with *Check for Updates Daily* in the menu. Recording calls may require the consent of all participants
depending on where you and they are; the app does not announce itself. That is on you.
