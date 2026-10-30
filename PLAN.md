# eko — native macOS call recorder: plan

Date: 2026-10-29. Target machine: MacBook Pro, macOS 15.5 (Sequoia), Apple Silicon.

> **Status (2026-10-30):** decisions 1–4 taken as recommended (Core Audio taps, native Swift
> menu-bar app via SwiftPM, single mixed stereo AAC, global tap). Phases 0–3 implemented; see
> `README.md`. Verified: CLI records mic + system audio into a 48 kHz stereo .m4a on macOS 15.5
> without Xcode. Gotcha found: setting `name`/`isExclusive` on `CATapDescription` makes the
> aggregate device never run its IO proc. Second gotcha: with `kAudioAggregateDeviceTapAutoStartKey`
> the aggregate does not run until a tapped app plays audio (documented in AudioHardware.h), and
> without it the device dies as soon as one does; so the design moved to separate mic and tap
> captures aligned by host time in `MixBus` (section 3 below is superseded by README "How it works").
> Remaining: real Zoom/Meet test with earphones and AirPods switching mid-call (needs a human).

## 1. Goal (v1 scope)

A small native macOS utility that:

1. **Start recording** — captures (a) everything the Mac is *playing* (the other participants in Zoom / Google Meet / Teams / Slack, regardless of whether it is going to the built-in speakers, a monitor over DisplayPort, wired earphones, or AirPods) and (b) everything the *active microphone* picks up (you).
2. **Stop recording** — finalises a single audio file in a local folder with a descriptive name, e.g. `~/Documents/CallRecordings/2026-10-29 14-05 Zoom.m4a`.
3. Is controllable from a menu-bar icon and a global hotkey.

Explicitly out of scope for v1: transcription, auto-start on call detection, cloud upload, video, echo cancellation, per-participant separation.

## 2. What is on this machine (verified)

| Item | Finding | Implication |
|---|---|---|
| macOS | 15.5 (Darwin 24.5) | Core Audio process taps (14.2+) and ScreenCaptureKit audio (13+) both available. |
| Xcode | **Not installed**; only Command Line Tools (SDK 15.5) | Can still build with SwiftPM (`swift build`). Need to assemble the `.app` bundle + Info.plist ourselves, or install Xcode (~free, large download). |
| Swift | 6.1.2 | Fine. |
| CoreAudio tap headers | `CATapDescription.h`, `AudioHardwareTapping.h` present in CLT SDK | Native tap approach compiles without Xcode. |
| SwiftUI / ScreenCaptureKit / AVFAudio frameworks | present in CLT SDK | Menu-bar app via `MenuBarExtra` is possible. |
| Node | 22.20 | Electron route possible. |
| Rust | not installed | Tauri route needs a toolchain install first. |
| ffmpeg | `/opt/homebrew/bin/ffmpeg` | Handy for post-processing/verification, not required at runtime. |
| Audio devices | Built-in mic (default input), built-in speakers (default output), DisplayPort monitor output, "Microsoft Teams Audio Device" (virtual) | Output device switches are common on this machine; the capture method must not care which output is active. |
| Call apps | zoom.us, Google Chrome (Meet), Slack, Safari; Teams virtual device suggests Teams too | File-name app detection should cover these. |

## 3. Architecture (independent of the shell you pick)

```
            ┌───────────────────────────────┐
            │  UI shell (menu bar / hotkey)  │   start / stop / status / open folder
            └──────────────┬────────────────┘
                           │
            ┌──────────────▼────────────────┐
            │  RecordingSession              │   owns lifecycle, naming, errors
            └───────┬───────────────┬───────┘
                    │               │
      ┌─────────────▼───┐   ┌───────▼────────────┐
      │ SystemAudioTap   │   │ MicrophoneCapture  │
      │ (Core Audio tap) │   │ (same aggregate    │
      │                  │   │  device, or        │
      │                  │   │  AVAudioEngine)    │
      └─────────────┬────┘   └───────┬────────────┘
                    │                │
            ┌───────▼────────────────▼───────┐
            │ Mixer + AVAudioFile writer      │   48 kHz, AAC .m4a (or WAV)
            └─────────────────────────────────┘
```

Key design point: **put the microphone input device and the system-audio tap into the *same* Core Audio aggregate device** (sub-device list = default input device, tap list = the process tap, drift compensation on). One IO callback then delivers mic channels and tapped-output channels already sample-aligned, which sidesteps the classic "two clocks, two streams, drift" problem. Fallback if that proves awkward: capture mic via `AVAudioEngine` and mix through a ring buffer.

## 4. Decision 1 — how to capture the system (incoming) audio

### Option A — Core Audio process taps (`CATapDescription` + aggregate device) — **recommended**

- **Availability:** macOS 14.2+ (you have 15.5). Headers verified present in your SDK.
- **How:** create a global tap that excludes our own process (`initStereoGlobalTapButExcludeProcesses:`), wrap it in a private aggregate device, start an IO proc, receive 32-bit float PCM.
- **Permission:** "System Audio Recording Only" (TCC service `kTCCServiceAudioCapture`). Requires `NSAudioCaptureUsageDescription` in Info.plist. First `AudioDeviceStart` on the aggregate triggers the prompt. **No Screen Recording permission needed.**
- **Pros:** Pure audio, no video pipeline, lowest CPU; captures at the app-output layer so it does not matter whether sound goes to speakers, monitor, earphones or AirPods; can exclude noisy apps (Music, notifications) by PID; can also target a single app (Zoom) instead of everything; no third-party install; this is what Chromium/Electron 39+ now use internally.
- **Cons:** Sparse Apple documentation (but good open-source references: insidegui/AudioCap, makeusabrew/audiotee, Apple's "Capturing system audio with Core Audio taps"); **permission denial yields silence, not an error** — must detect all-zero buffers and tell the user; no public API to query permission state (AudioCap uses a private TCC call behind a build flag; alternative: probe by setting `kAudioTapPropertyDescription` and checking for `kAudioDevicePermissionsError`); a few forum reports of all-zero buffers on macOS 26 betas (not your OS).

### Option B — ScreenCaptureKit with `capturesAudio = true`

- **Availability:** macOS 13+.
- **How:** `SCStream` with a `.screen` output handler attached (required even for audio-only; drop the video frames) and an `.audio` handler. Set `excludesCurrentProcessAudio`.
- **Permission:** **Screen Recording** permission (the scarier "Screen & System Audio Recording" prompt), even though we never save video.
- **Pros:** Better documented than taps; has a Rust crate (`screencapturekit`) and Node bindings, so it is the easiest route for Tauri; also offers microphone capture in the same stream on macOS 15+.
- **Cons:** Wastes CPU producing screen frames you throw away (can minimise with 1×1 px, 1 fps config, but still a video pipeline); Screen Recording permission is heavier and gets re-prompted monthly on recent macOS for some apps; some reports of all-zero audio for VoIP background audio.

### Option C — Virtual audio driver (BlackHole / Loopback) + multi-output device

- **How:** install a virtual device, create a Multi-Output Device (real output + BlackHole), set it as system output, record BlackHole as an input.
- **Pros:** Works on any macOS version; well-known.
- **Cons:** Third-party kernel/driver install; you must re-route system output to a multi-output device (breaks volume keys, breaks on every earphone/AirPods switch, Teams/Zoom device pickers get confused); clearly the worst fit for "whatever output is active". Not recommended.

| | A. Core Audio taps | B. ScreenCaptureKit | C. Virtual driver |
|---|---|---|---|
| Min macOS | 14.2 | 13 | any |
| Permission | System Audio Recording Only | Screen Recording | none (but driver install) |
| Works with earphones/AirPods switch | yes | yes | fragile |
| CPU | lowest | medium (video pipeline) | low |
| Docs/ecosystem | thin, good samples | good | good |
| Swift effort | medium | medium | low |
| Non-Swift bindings | Electron 39+ built in; Python `catap`; Go bindings | Rust crate, Node bindings | any |

## 5. Decision 2 — app shell / tech stack

### Option 1 — Native Swift menu-bar app, built with SwiftPM (no Xcode) — **recommended**

- SwiftUI `MenuBarExtra` (macOS 13+) for the icon, menu, status; `KeyboardShortcuts` (sindresorhus) package for the global hotkey; `AVAudioFile` for writing.
- Build with `swift build -c release`, then a small script copies the binary into `eko.app/Contents/MacOS`, writes `Info.plist` (bundle id, `LSUIElement=1` for no Dock icon, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`), and `codesign -s - --force --deep` (ad-hoc). TCC permissions stick to the bundle id, so prompts behave normally.
- **Pros:** Direct access to all three capture APIs; smallest binary (~2 MB), zero runtime deps, lowest latency/CPU, best-behaved permissions; you already have the toolchain.
- **Cons:** Swift + Core Audio C API has a learning curve; without Xcode no GUI debugger/Instruments (can `xcode-select` to Xcode later with no code changes).
- **Risk to validate early:** that an ad-hoc-signed, SwiftPM-built bundle gets the System Audio Recording prompt. AudioTee proves a bare SwiftPM binary works (prompt attributed to the terminal); a bundle should be cleaner. If it misbehaves, install Xcode (fallback, ~1 hour, no code changes).

### Option 2 — Swift command-line tool first (`eko start` / `eko stop`), menu bar later

- Same engine as Option 1, just no UI; stop via `Ctrl-C` or a second invocation sending a signal / Unix socket.
- **Pros:** Fastest path to "it works" (a day); engine is reused unchanged by the menu-bar app.
- **Cons:** Permission prompts get attributed to the terminal app (Terminal/iTerm/Cursor) rather than to eko; iTerm reportedly swallows the prompt sometimes. It is a stepping stone, not the end state.
- Recommendation: do this as **Phase 1** of Option 1 rather than as a separate choice.

### Option 3 — Electron (TypeScript)

- Electron 39+ uses Core Audio taps under the hood for `getDisplayMedia` loopback audio; mic via `getUserMedia`; mix with Web Audio; write via `MediaRecorder` (WebM/Opus) or ffmpeg.
- **Pros:** JS/TS, which you already have; fast UI iteration; cross-platform later.
- **Cons:** 150–250 MB app for a utility; the loopback path goes through the screen-share picker UI (`setDisplayMediaRequestHandler` workaround required); `MediaRecorder` output is WebM/Opus, so a transcode step is needed for `.m4a`; permission edge cases are reported as silent (ended track, no error); still needs `NSAudioCaptureUsageDescription` in the packaged Info.plist.

### Option 4 — Tauri 2 + Rust

- Rust backend using the `screencapturekit` crate (Option B capture) or hand-written Core Audio FFI (Option A); web UI.
- **Pros:** Small binary (~10 MB), web UI, cross-platform story.
- **Cons:** Rust toolchain not installed; Core Audio tap FFI from Rust is unergonomic (Objective-C class `CATapDescription`), so in practice you'd be pushed to ScreenCaptureKit and the Screen Recording permission; two languages for a one-feature utility.

| | 1. Swift menu bar (SwiftPM) | 3. Electron | 4. Tauri/Rust |
|---|---|---|---|
| Capture API fit | all three, native | taps via Chromium (indirect) | SCK via crate; taps painful |
| Permission UX | cleanest | OK, some silent failures | Screen Recording prompt |
| Binary size | ~2 MB | ~200 MB | ~10 MB |
| Toolchain ready today | yes | yes | no (install Rust) |
| Output control (.m4a) | native `AVAudioFile` | transcode step | via ffmpeg or Rust crate |
| Effort to v1 | ~3–5 focused sessions | ~3–4 | ~5+ |

## 6. Decision 3 — output file format and track layout

| Layout | Pros | Cons |
|---|---|---|
| **(a) Single mixed stereo .m4a (AAC 48 kHz, 128–192 kbps)** — recommended default | Plays anywhere, small (~1 MB/min), one file per call | Mic and remote audio can't be separated later |
| (b) Stereo "split" .m4a: Left = mic, Right = remote | Trivial to separate speakers later for transcription/diarisation; still one file | Sounds odd on headphones unless downmixed; remote stereo becomes mono |
| (c) Two files (`…-mic.m4a`, `…-system.m4a`) + optional mixed | Max flexibility | Clutter; sync depends on identical start timestamps |
| WAV instead of AAC | Lossless, trivially robust to crashes (header fixable) | ~11 MB/min at 48 kHz stereo 16-bit |

Suggested: default (a), with a Settings toggle for (b). Write with `AVAudioFile` incrementally so a crash mid-call still leaves a playable file (for .m4a, finalise on stop; consider writing `.caf` during the call and converting on stop if crash-safety matters more).

## 7. Decision 4 — tap scope: everything vs. the call app only

- **Global tap, excluding self** (recommended): captures all system audio. Simple, works for every app, never misses a browser helper process. Downside: notification dings and Spotify get recorded (mitigate: exclude known PIDs such as Music/Spotify, or just mute them).
- **Per-app tap** (`initStereoMixdownOfProcesses:` with Zoom's PID): cleaner. Downside: Chrome/Meet audio comes from helper processes, so you must enumerate all processes of the bundle; a tap on a PID that is not currently playing can fail. Good as a v1.1 option ("Record only: Zoom").

## 8. Permissions, signing, Info.plist

- `NSMicrophoneUsageDescription` — microphone prompt (standard `AVCaptureDevice.requestAccess(for: .audio)`).
- `NSAudioCaptureUsageDescription` — System Audio Recording Only prompt; appears on first `AudioDeviceStart` of the aggregate device. Not in Xcode's dropdown; add by hand.
- `LSUIElement = true` — menu-bar-only app.
- Ad-hoc code signing is enough for personal use. No notarisation needed when launched locally.
- Detect denial: if the first ~2 s of tap buffers are all zeros while the mic is non-silent, surface "System Audio Recording permission missing" with a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`.
- Legal note: many jurisdictions require consent of all parties to record a call. The app will not announce itself; that is on you as the user.

## 9. File naming and storage

- Folder: `~/Documents/CallRecordings/` (created on first run; configurable).
- Name: `YYYY-MM-DD HH-mm <App>.m4a`, e.g. `2026-10-29 14-05 Zoom.m4a`, `2026-10-29 16-30 Google Meet.m4a`.
- App detection (best effort, in this order): (1) if a known call app's process is currently producing audio via the tap's process list (`kAudioHardwarePropertyProcessIsRunningOutput`), use it; (2) else frontmost app at start; (3) else `Call`. Map Chrome/Safari → `Google Meet` only if a tab title contains "Meet" (optional, needs Accessibility; otherwise just `Chrome`).
- Also write a sidecar `.json` (start/end time, app, devices, sample rate) — cheap, useful later for transcription.

## 10. Implementation phases (for the recommended stack)

**Phase 0 — spike (½ day).** SwiftPM executable: global tap → aggregate device (with default input device as sub-device) → IO proc → write 20 s WAV. Verify in Zoom test meeting with (i) speakers, (ii) wired earphones, (iii) AirPods, switching mid-recording. *Gate:* both voices audible and in sync in the WAV. This de-risks Decision 1 and the no-Xcode build.

**Phase 1 — engine (1 day).** `RecordingSession` with start/stop, mixer, AAC `.m4a` writer, incremental writes, device-change listeners (`kAudioHardwarePropertyDefaultInputDevice`), permission detection, structured errors. Unit test the mixer with synthetic buffers.

**Phase 2 — menu-bar app (1 day).** `MenuBarExtra` with Start/Stop, elapsed timer, red icon while recording, "Open recordings folder", Settings (folder, format, hotkey). Global hotkey via `KeyboardShortcuts`. Bundle script + Info.plist + ad-hoc sign. Launch-at-login via `SMAppService`.

**Phase 3 — polish (½–1 day).** App-name detection for filenames, sidecar JSON, low-disk guard, notification on save, crash-safety check (kill -9 during recording → file still playable or recoverable).

Later (v1.1+): per-app tap, auto-start when Zoom/Meet starts a call, local transcription (WhisperKit), split-track option.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Silent TCC denial (all-zero buffers) | Zero-buffer detector + explicit guidance; probe permission via `kAudioTapPropertyDescription` error. |
| SwiftPM-built bundle and TCC attribution | Validate in Phase 0; fallback is installing Xcode (no code change). |
| Mic device changes mid-call (plug earphones with mic, AirPods) | Listen for default-input changes; rebuild aggregate device; keep writer open so file is continuous. |
| Bluetooth HFP lowers mic quality when AirPods mic is used | Inherent to Bluetooth; document; prefer built-in mic in Settings (optional override). |
| Echo (speakers + built-in mic) | Expected in v1; no AEC. Headphones avoid it. |
| Long calls / disk | Incremental writes; warn under 1 GB free. |
| Browser audio from helper processes | Use global tap in v1. |
| Apple API regressions (reports on macOS 26 betas) | You are on 15.5; re-test before upgrading. |

## 12. Proposed project layout (Swift option)

```
eko/
  Package.swift
  Sources/
    EkoCore/        # library: tap, aggregate device, mic, mixer, writer, session
    eko-cli/        # Phase 0/1 executable (start/stop from terminal)
    EkoApp/         # Phase 2 SwiftUI MenuBarExtra app
  Tests/EkoCoreTests/
  scripts/bundle.sh     # builds .app, writes Info.plist, ad-hoc signs
  Resources/Info.plist
```

## 13. Sources consulted

- Apple: Capturing system audio with Core Audio taps — https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- Apple: SCStreamConfiguration (capturesAudio, excludesCurrentProcessAudio) — https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration
- Apple forums: audio-only ScreenCaptureKit needs a .screen handler — https://developer.apple.com/forums/thread/718279
- Apple forums: requesting System Audio Recording Only permission — https://developer.apple.com/forums/thread/771864
- insidegui/AudioCap (Swift sample, macOS 14.4+) — https://github.com/insidegui/AudioCap
- makeusabrew/audiotee (SwiftPM CLI, no Xcode needed) — https://github.com/makeusabrew/audiotee
- Recall.ai: Core Audio taps overview — https://www.recall.ai/blog/core-audio-taps
- Electron desktopCapturer docs (Core Audio tap default since 39.0.0-beta.4) — https://electronjs.org/docs/api/desktop-capturer
- screencapturekit Rust crate (Tauri example) — https://docs.rs/crate/screencapturekit/8.0.1
- DEV: silent TCC denial write-up — https://dev.to/nickdelv/2000-buffers-of-nothing-3i8
- Rogue Amoeba on macOS 26 capture bugs — https://weblog.rogueamoeba.com/2025/11/

## Distribution (added 2026-10-30)

Downloadable DMG path implemented: `VERSION` file, `Resources/Eko.entitlements` (audio-input only),
hardened runtime on every build, `UNIVERSAL=1` two-triple build merged with lipo (SwiftPM's
`--arch` needs Xcode's xcbuild), `scripts/make-dmg.sh` (hdiutil + Applications symlink, signed),
`scripts/release.sh` (tests, Developer ID, notarize+staple app, DMG, notarize+staple DMG, spctl
checks, sha256). Running from a read-only volume (mounted DMG or App Translocation) shows an
"Install Eko first" alert. Still required from the maintainer: Apple Developer Program membership,
a Developer ID Application certificate, and `notarytool store-credentials eko-notary`.
Deliberately not done: Sparkle/auto-update, GitHub Actions, Mac App Store (sandbox + review).

In-app updates (2026-10-30): `Sources/EkoApp/Updater.swift`, no dependency. Daily check of
`https://api.github.com/repos/<EkoUpdateRepository>/releases/latest` (toggle in the menu), menu
item becomes "Update Available: Eko x.y.z", dialog → download the release .dmg (https, github.com,
the configured repo's `releases/download/` path only) → hdiutil attach → copy the app next to the
installed one → `SecStaticCodeCheckValidity` of the copy against the running app's own designated
requirement (same bundle id + certificate/Team ID) → version check → rename swap with rollback →
old copy to Trash as "Eko <old>.app" → relaunch through /bin/sh + open. Tested end to end with a
local feed (EKO_UPDATE_FEED, development only): dev-signed 0.1.1 installs; ad-hoc 0.1.2 rejected.
Release tags must be `v<VERSION>`; UPDATE_REPO in scripts/bundle.sh must match the GitHub repo.

Free distribution path (2026-10-30): `scripts/get-eko.sh` one-line installer (latest release →
sha256 check → clear quarantine → /Applications → launch; GITHUB_TOKEN for private repos,
EKO_VERSION to pin), `scripts/release.sh --local` (universal DMG signed with the stable "Eko Dev"
certificate, no notarization). The in-app updater works with that certificate because it compares
the update against the running app's own designated requirement; ad-hoc builds (like the 0.1.0
pre-release) cannot update and now say so. The certificate is the trust root: back it up.
