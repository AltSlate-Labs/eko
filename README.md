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

## Download (no build tools needed)

1. Download `Eko-<version>.dmg` from https://github.com/AltSlate-Labs/eko/releases/latest and open it.
2. Drag **Eko** onto the **Applications** shortcut in the window that appears, then eject the image.
3. Open Eko from Applications (or Cmd+Space, "Eko"). Continue with [First-run setup](#first-run-setup).

Release images are a universal binary (Apple Silicon and Intel), signed with a Developer ID
certificate and notarized by Apple, so macOS opens them like any other downloaded app. If you
open Eko straight from the disk image instead of Applications it asks you to install it first.
To check a download: `shasum -a 256 Eko-<version>.dmg` must match the `.sha256` file on the
release, and `spctl --assess --type open --context context:primary-signature -v Eko-<version>.dmg`
must print `accepted`.

## Install from source

```sh
git clone <repo-url> eko && cd eko
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
the DMG, opens it, verifies that the new app is signed by the same publisher as the running
copy (same bundle identifier and Team ID, checked by macOS's code-signing APIs; anything else is
refused and nothing changes), swaps it into place, moves the old version to the Trash and
relaunches. Settings, permissions and recordings are kept. Updates wait until you stop a
recording. You can always install a new DMG by hand instead.

From source:

```sh
git pull
./scripts/install.sh
```

Source builds signed with the local "Eko Dev" certificate also keep their permissions, but
they cannot self-update from the published DMGs (different publisher by design).

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

`./scripts/release.sh` produces `dist/Eko-<version>.dmg` plus a `.sha256` file: it runs the
tests, builds a universal binary, signs it with the hardened runtime and
`Resources/Eko.entitlements`, notarizes and staples the app, wraps it in a signed DMG, notarizes
and staples that too, and finishes with the same Gatekeeper checks a user's Mac performs.
Nothing is uploaded; attach the DMG and `.sha256` to a GitHub Release for the tag. The in-app
updater reads that repository's latest release: `UPDATE_REPO` at the top of `scripts/bundle.sh`
(default `AltSlate-Labs/eko`, baked into Info.plist as `EkoUpdateRepository`) must name the GitHub
`owner/name` that hosts the releases, and the release tag must be `v<VERSION>`.

One-time setup, all outside the repository:

1. Join the Apple Developer Program and create a **Developer ID Application** certificate
   (developer.apple.com → Certificates; make the signing request in Keychain Access → Certificate
   Assistant → Request a Certificate From a Certificate Authority). Download it and double-click
   to add it to the login keychain. `security find-identity -v -p codesigning` must list it.
2. Create an app-specific password at account.apple.com and store the notarization credentials
   in the keychain (the password is never written to disk in this repo):

   ```sh
   xcrun notarytool store-credentials eko-notary --apple-id <apple-id> --team-id <TEAMID>
   ```

3. Per release: bump `VERSION`, run `./scripts/release.sh`, test the DMG on a clean user
   account, tag the commit (`git tag v$(cat VERSION)`), and publish the release.

Only the Command Line Tools are needed; `notarytool` and `stapler` ship with them. Local
development keeps using the self-signed "Eko Dev" certificate; release builds are the same code
signed with the Developer ID, so permissions survive the switch only for users of the signed
build, not between a source build and a downloaded one.

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
scripts/install.sh        build + sign + copy to /Applications + launch (from source)
scripts/bundle.sh         build and sign build/Eko.app (UNIVERSAL=1, APP_NAME, SIGN_IDENTITY)
scripts/make-dmg.sh       wrap build/Eko.app in a signed dist/Eko-<version>.dmg
scripts/release.sh        signed + notarized universal DMG for GitHub Releases
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
