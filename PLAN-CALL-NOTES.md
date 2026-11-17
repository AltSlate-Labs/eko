# Eko — automatic call transcript and summary: implementation plan

Status: plan only, no code yet. Written 2026-11-09.
Decision taken: start with **Hex for speech-to-text + llama.cpp (`llama-server`) for the summary**, built so
either side can later be switched (first candidate: whisper.cpp) by changing one word in a config file.
Background and option research: `PLAN-SUMMARY.md` and `reports/Local call transcription and summary options.md`.
Update 2026-11-15: the first build uses Google Gemini with the user's own key instead (`PLAN-GEMINI.md`); this
local plan becomes the later "private mode" behind the same engine interfaces and file formats.

---

## 1. What the user gets

When a call recording stops and Eko has saved the file, Eko automatically, with no clicks:

1. transcribes it on this Mac, and writes `<filename>-transcript.txt` next to the recording;
2. summarises the transcript with a local model, using an editable prompt, and writes `<filename>-summary.txt`.

```
~/Documents/CallRecordings/
  2026-11-09 14-30 Zoom.m4a                  (recording, unchanged)
  2026-11-09 14-30 Zoom.json                 (existing sidecar, gains a "channels" field)
  2026-11-09 14-30 Zoom-transcript.txt       (new)
  2026-11-09 14-30 Zoom-summary.txt          (new)
```

Nothing leaves the Mac. Both files appear only when complete (written atomically), so a half-written file is
never visible. If the summary step fails, the transcript is still kept.

## 2. Principles that make switching cheap

1. **Engines are separate programs, never linked into Eko.** Eko starts them as child processes (or talks to
   them on 127.0.0.1). The Eko binary stays dependency-free and its build is unaffected by engine changes.
2. **Two seams, nothing engine-specific outside them.** A `SpeechEngine` interface and a `SummaryEngine`
   interface. Trigger, queue, audio preparation, speaker labels, file formats, prompt and checks are shared.
3. **Engines declare capabilities; the pipeline adapts.** E.g. Hex takes ≤30 s WAV clips and returns no
   timestamps; whisper.cpp takes a whole track and returns timestamps. The pipeline picks the strategy.
4. **The output files have one fixed format**, whatever engine made them. The header records which engine,
   model and version produced them, so results from different engines can be compared later.
5. **Config, not code, picks the engine.** Settings for every engine sit side by side, so switching back and
   forth loses nothing.

## 3. Architecture

```
RecordingSession .stopped(url)            (file closed, renamed, sidecar written)
        │
        ▼
NotesQueue  (persisted; one job at a time; pauses while a new call records)
        │
        ▼
NotesPipeline ──────────────────────────────────────────────────────────────────────┐
  1. Read sidecar → channel layout (split / mixed), start time, apps heard            │
  2. AudioPrep: decode .m4a → per-track 16 kHz mono PCM                                │  engine-
  3. Segmenter: energy VAD → speech regions → clips (≤ engine's max clip length)       │  neutral
  4. SpeechEngine.transcribe(clip) for each clip  ◄── seam 1: hex | whisper.cpp | …    │
  5. Merge tracks by time, label You / Others, drop mic-bleed duplicates               │
  6. Write <name>-transcript.txt (atomic, 0600)                                        │
  7. Render prompt template with the transcript                                        │
  8. SummaryEngine.complete(prompt)  ◄── seam 2: llama-server | ollama | command       │
  9. Check cited timestamps exist; write <name>-summary.txt (atomic, 0600)             │
─────────────────────────────────────────────────────────────────────────────────────┘
```

New code lives in `Sources/EkoCore/Notes/` (pipeline, engines, formats) plus small hooks in
`Sources/EkoApp/RecorderModel.swift` (trigger, menu status) and `Sources/eko/main.swift` (CLI).

### 3.1 The two interfaces (sketch)

```swift
struct SpeechCapabilities {
    var input: Input              // .clips(maxSeconds: 28) or .wholeTrack
    var returnsTimestamps: Bool   // false → pipeline uses clip offsets
    var languages: Set<String>    // ["en"], ["hi", "en", …] or ["*"]
}

protocol SpeechEngine {
    var id: String { get }                                  // "hex", "whisper.cpp"
    var capabilities: SpeechCapabilities { get }
    func prepare() async throws -> EngineInfo               // installed? version? model present? start app if needed
    func transcribe(_ audio: PreparedAudio) async throws -> [TimedText]   // 16 kHz mono WAV + its offset
    func finish() async                                     // e.g. quit Hex if Eko started it
}

protocol SummaryEngine {
    var id: String { get }                                  // "llama-server", "ollama", "command"
    func prepare(estimatedPromptTokens: Int) async throws -> EngineInfo  // e.g. launch llama-server sized to the job
    func complete(prompt: String, maxOutputTokens: Int) async throws -> String
    func finish() async                                     // stop the server, free memory
}
```

`TimedText` = start, end, text. `EngineInfo` = name, version, model, used in the file headers.

### 3.2 The config file

`~/Library/Application Support/Eko/notes.json` (0600). Created with these defaults on first enable.

```json
{
  "version": 1,
  "enabled": true,
  "minimumRecordingSeconds": 30,
  "language": "auto",
  "speech": {
    "engine": "hex",
    "engines": {
      "hex": {
        "app": "/Applications/Hex.app",
        "model": "nemotron_3_5_asr",
        "quitHexIfEkoStartedIt": true
      },
      "whisper.cpp": {
        "binary": "whisper-cli",
        "model": "~/Library/Application Support/Eko/models/ggml-large-v3-turbo-q5_0.bin"
      }
    }
  },
  "summary": {
    "engine": "llama-server",
    "promptFile": "~/Library/Application Support/Eko/summary-prompt.txt",
    "engines": {
      "llama-server": {
        "binary": "llama-server",
        "model": "~/Library/Application Support/Eko/models/Qwen3-8B-Q4_K_M.gguf",
        "modelSHA256": "<pinned at download>",
        "fallbackModel": "~/Library/Application Support/Eko/models/Qwen3-4B-Q4_K_M.gguf",
        "maxContext": 32768
      },
      "ollama": { "model": "qwen3:8b", "maxContext": 32768 }
    }
  }
}
```

**To switch speech-to-text to whisper.cpp later:** change `"engine": "hex"` to `"engine": "whisper.cpp"`.
**To switch summaries to Ollama** (already installed on this Mac): change `"llama-server"` to `"ollama"`.
`"summary": {"engine": "none"}` gives transcripts only. Binaries are found by name on PATH plus
`/opt/homebrew/bin` and `/usr/local/bin` (a menu-bar app does not inherit the shell PATH), or by absolute path.

### 3.3 Engine capability table

| Engine | Kind | Input | Timestamps | Status in this plan |
|---|---|---|---|---|
| **Hex** (`hex transcribe`) | speech | WAV clips; Eko uses ≤ 28 s (file cap 64 MiB) | No (Eko uses clip offsets) | **Build first** |
| whisper.cpp (`whisper-cli`) | speech | Whole track WAV | Yes (`-oj` JSON) | Later switch, ~1 day |
| transcribe.cpp CLI, Apple Speech, others | speech | via a generic "command" adapter | Depends | Optional |
| **llama-server** (llama.cpp) | summary | Prompt over 127.0.0.1 | n/a | **Build first** |
| Ollama | summary | Prompt over 127.0.0.1, `num_ctx` set per request | n/a | Optional, ~½ day |
| Any CLI reading stdin | summary | Prompt on stdin | n/a | Optional, ~½ day |

Meetily cannot be an engine: its free edition has no command-line or API hand-off.

## 4. Pipeline details (engine-neutral)

### 4.1 Trigger

- Hook: `RecorderModel.handle(.stopped(url, duration))`. `RecordingSession.stop()` emits `.stopped` only
  after the writer has closed the file, the file has been renamed, and the `.json` sidecar has been written,
  so the file is complete at that point.
- Skip if `enabled` is false or the duration is under `minimumRecordingSeconds` (accidental recordings).
- Enqueue `{recording path, size, mtime}` in `~/Library/Application Support/Eko/notes-queue.json`.
- **Catch-up on launch:** resume jobs still in the queue (Eko quit or crashed mid-job).
- **Scope (D5, decided 2026-11-10): new recordings only.** Only calls recorded after the feature is switched
  on are processed automatically. Existing recordings are never backfilled; any of them can still be
  processed on request (§4.8), without You/Others labels.
- **While a new call is recording:** the queue pauses after the current clip, and `llama-server` is never
  started (or is stopped and the job re-queued). This protects the live recording and memory.
- Hold an idle-sleep assertion (`ProcessInfo.beginActivity(.idleSystemSleepDisabled)`) while a job runs.

### 4.2 Speaker labels need the split-channel recording (prerequisite, §7)

| Recording | What the pipeline does | Transcript lines |
|---|---|---|
| New, `"channels": "split-v1"` in sidecar | Left = microphone → **You**; right = call audio → **Others** | `[00:01:02] You: …` |
| Old (no field) | Mono mix of both channels | `[00:01:02] …` (no labels) |

Recordings made before the capture change can never get You/Others labels.

### 4.3 Audio preparation and segmentation

- Decode with AVFoundation in chunks (an hour-long call is never fully in memory), pick the track, resample to
  16 kHz mono 16-bit WAV, the format every engine here accepts.
- Energy VAD on 30 ms frames with an adaptive noise floor: speech regions padded by 200 ms, gaps under 0.8 s
  merged, regions over 28 s split at the quietest frame. This (a) satisfies Hex's limits, (b) gives each line
  a start time, (c) skips silence, where speech models hallucinate.
- Clips go to a private temporary folder (0700), deleted when the job ends, success or failure.
- Whole-track engines (whisper.cpp) get the full track instead and return their own timestamps.

### 4.4 Merge and clean-up

- Interleave both tracks by start time.
- **Mic bleed:** if the user is on speakers, the mic also hears the other side. Drop a You line that overlaps an
  Others line in time and has similar text (word overlap ≥ 60%). Headphones avoid the problem entirely.
- Collapse runs of identical lines (a known model failure on noise).

### 4.5 Transcript file

`<name>-transcript.txt`. UTF-8, plain text, parseable back into segments (needed for "re-summarise only").

```
Eko call transcript
Recording: 2026-11-09 14-30 Zoom.m4a
Date: 2026-11-09 14:30 · Duration: 00:42:10 · Apps: Zoom
Speech-to-text: Hex 3.3.0, model nemotron_3_5_asr, language auto
Speakers: You = this Mac's microphone · Others = call audio (other people are not told apart)
------------------------------------------------------------
[00:00:03] You: Hi, can you hear me?
[00:00:05] Others: Yes, loud and clear. Shall we start with the pricing update?
```

### 4.6 Summary

- Prompt: `~/Library/Application Support/Eko/summary-prompt.txt`, created from the default in Appendix A,
  edited freely by the user. Placeholders: `{{transcript}}`, `{{title}}`, `{{date}}`, `{{duration}}`,
  `{{speakers}}`. Editing it changes future summaries; `eko notes --summary-only` redoes an old one.
- Eko adds a header and a footer around the model's text. The footer comes from a deterministic check: every
  `[hh:mm:ss]` the model cites must exist in the transcript. Local models are weaker than cloud ones, so the
  summary is labelled a draft.

```
Eko call summary — DRAFT made on this Mac; check it against the transcript
Recording: 2026-11-09 14-30 Zoom.m4a
Model: Qwen3-8B Q4_K_M via llama.cpp 0.9.0 · Prompt: summary-prompt.txt (edited 2026-11-09)
------------------------------------------------------------
<model output>
------------------------------------------------------------
Checks: 12 of 12 cited timestamps found in the transcript.
```

### 4.7 Naming and overwrite rules

- `<recording name without extension>-transcript.txt` / `-summary.txt`, same folder, for `.m4a` and `.wav`.
- Write to a temporary file in the same folder, then rename (atomic); permissions 0600.
- An automatic job never overwrites existing files (a hand-edited summary is never lost). Manual re-runs need
  `--force`.

### 4.8 Manual commands (CLI and menu)

```
eko notes "<recording>.m4a"                     transcribe + summarise one file
eko notes --summary-only "<recording>.m4a"      re-summarise from the existing transcript (new prompt or engine)
eko notes --speech whisper.cpp "<recording>"    one-off engine override, for comparing engines
eko notes --force …                             allow overwriting existing output
eko notes --check                               check setup: Hex, lab, model, llama-server, model files, memory
```

**Completion signal (D6, decided 2026-11-10):** the two files appearing in the recordings folder; no
notification. The menu stays quiet on success and shows a line only while a job runs ("Transcribing
2026-11-09 14-30 Zoom…") or when one fails or setup is missing, with the fix. Menu actions:
"Transcribe & summarise a recording…" and "Edit summary prompt". Eko's log (`~/Library/Logs/Eko/notes.log`) records timings, engines and errors, **never transcript
text**.

## 5. Speech engine: Hex adapter

Verified against Hex's source and docs (`docs/cli.md`, `src/control/cli/transcribe.rs`, v3.3.0, 2026-11-02).

### 5.1 How it is called

```
/Applications/Hex.app/Contents/MacOS/hex transcribe <clip.wav> --model <id> [--language <code>] --json
```

- Always use the `hex` **inside Hex.app**: a different version answers `version-mismatch`.
- Labs › Transcribe files must be on: `hex labs on transcribe-files` (off by default; answers `disabled`).
- On macOS Hex must be running (`not-running`, exit 3). Eko runs `hex start` (opens Hex and waits until it
  answers), and quits it after the job with `hex quit` if Eko started it (`quitHexIfEkoStartedIt`).
- The command sends the WAV to Hex's own local API (127.0.0.1, owner-only token file). Clips up to 30 s run on
  the already-loaded dictation model; longer ones make Hex load a second copy, another reason for ≤ 28 s clips.
- Hex does not paste, save to History, or apply its text "modes" to this output.
- Input must be WAV (Eko converts; no ffmpeg needed). Output is text only, no timestamps.

### 5.2 Exit codes and replies → pipeline behaviour

| Hex answer | Meaning | Eko does |
|---|---|---|
| exit 0 | transcript on stdout | use it |
| exit 4 `no-speech` | silent clip | skip clip |
| exit 3 `not-running` | Hex not open | `hex start`, retry once |
| `busy`, `queue-full` | Hex occupied (e.g. user dictating) | retry after 2 s, 5 s, 10 s, then fail job |
| `disabled`, `not-installed`, `unknown-model`, `not-ready` | setup missing | fail job, menu shows the fix |
| `resource-exhausted`, `unsupported` | clip too big / bad WAV | bug in Eko: fail job, log details |
| no answer in 120 s | hung | terminate, retry once, then fail job |

### 5.3 Which Hex model (D1 decided 2026-11-10: calls are mixed Hindi/English → `nemotron_3_5_asr`)

| Calls are | Hex model id | Download | Evidence |
|---|---|---|---|
| English only | `parakeet_unified_en` (Hex default) | 731 MB | Strong on English; no Hindi |
| Hindi or mixed Hindi/English | `nemotron_3_5_asr` | 751 MB | Hindi 14.18 OIWER vs Whisper turbo 41.55; weaker on English (leaderboard avg 11.09 vs about 7 for Parakeet) |
| Hindi, best available | Qwen3-ASR-1.7B imported as a custom model | about 2.2 GB | Hindi 12.74 OIWER; "not tested by Hex"; Q8_0 files only |

Correction to earlier advice: Hex's "QwenCleo-ASR 1.7B" is an **Arabic-only** model (`languages: ["ar"]`
in Hex's catalog), not a general Qwen model, and is no use here. No open model has a published Hinglish
(code-switched) score, so the choice is confirmed only by testing your own calls (Phase 1).

### 5.4 Hex settings Eko expects (set once during setup)

- `hex labs on transcribe-files`
- `hex model install <id>` (download once)
- `hex settings set meetings.summaries off` (Hex's own summaries would use Apple Intelligence or OpenCode)
- Leave Hex's Meetings feature off: Eko records the calls.

## 6. Summary engine: llama-server adapter

### 6.1 Install and models

- `brew install llama.cpp` (Homebrew bottle, currently 0.9.0, MIT). Homebrew verifies its checksum; nothing
  is built locally, so no Xcode needed. Eko records the version in each summary header and warns when it changes.
- Models, downloaded once, with SHA-256 pinned in the config:
  - main: **Qwen3-8B Q4_K_M** (5.02 GB), from Qwen's official GGUF repository on Hugging Face;
  - fallback: **Qwen3-4B Q4_K_M** (about 2.5 GB), used when memory is short (§6.3);
  - challenger for mixed Hindi/English: Gemma 4 12B QAT Q4 (6.97 GB). Phase 1 compares it with Qwen3-8B on
    your calls; it becomes the main model only if clearly better and memory allows.

**Decided 2026-11-10 (D3): start with Qwen3-8B, switchable with no code change.** The model is only a
file path in `notes.json` (`"model"`, `"fallbackModel"`), so switching means download a GGUF file and edit
one line. This works because:
- `llama-server` runs any GGUF chat model and reads its chat template from the file, so Eko never formats
  model-specific prompts.
- Eko speaks only the standard `/v1/chat/completions` API and never names the model in a request.
- Thinking output is switched off with the generic `--reasoning off` flag, and any `<think>` text is stripped.
- Context size and the memory check are computed from the model file's size and the job, not hard-coded per
  model.
- The summary header records which model wrote it, so results from different models can be compared, and
  `eko notes --summary-only` re-summarises an old call with the new model.

Rules for keeping it that way: no model names in code, no per-model branches. If a model ever needs special
flags, they go in the config's `extraArguments`, not in Swift. Two optional extras help compare models
without editing the config: a per-run override (`eko notes --summary-model <path> --summary-only <file>`)
and an optional per-model prompt file.

### 6.2 Job-scoped server

Started for one job, stopped right after:

```
llama-server -m <model.gguf>
  --host 127.0.0.1 --port <random free port>
  --api-key-file <job folder>/key   (random key, file 0600)
  -c <context sized to the job> -np 1
  --no-webui --no-slots --offline
  --reasoning off                    (no "thinking" output; Eko also strips <think> tags)
  -fa on -ctk q8_0 -ctv q8_0         (halves memory for the context)
  --log-file <job folder>/server.log
```

All of these flags appear in llama.cpp's current server README. Phase 1 confirms them on the installed version.

- Wait for `GET /health` = 200 (model loading, ~10–30 s), then one `POST /v1/chat/completions` with
  `temperature 0.2`, `max_tokens 2048`.
- Context size = estimated prompt tokens + 2,048, rounded up to 4K, minimum 8K, maximum `maxContext`
  (32K ≈ a two-hour call). Exact count via `POST /tokenize` before generating; if it does not fit, restart with
  the larger size once.
- Server killed on finish, error, cancellation or Eko quit. Its PID is written to the job folder, so an orphan
  is killed on next launch.

### 6.3 Memory gate (important on this Mac)

Memory needed ≈ model file + context (Qwen3-8B with q8_0 cache: about 0.07 MB per token, so ~1.1 GB at 16K)
+ 1 GB margin. That is about 7–8 GB for an hour-long call with the 8B model.

1. Before launch, read free + inactive memory (`host_statistics64`).
2. If it is short, use the fallback 4B model.
3. If still short, defer the summary (transcript already written): retry every 15 min, 4 times, then report.

**On 2026-11-09 this Mac had 19.1 GB of its 19.5 GB swap in use.** Under that pressure even the 4B model may
be deferred. It is worth finding what is holding memory before Phase 1.

### 6.4 Long calls

Transcripts beyond `maxContext` (≈ over two hours): v1 writes the transcript and reports "too long to
summarise". Chunked summarising (summarise each part, then combine) is in Phase 6.

## 7. Prerequisite Eko changes (Phase 0)

**Final spec, shipped as Eko 0.1.2 (2026-11-11).** Supersedes the notes below where they differ.

| # | Change | Where |
|---|---|---|
| 1 | Left channel = microphone only; right channel = everything the Mac plays, downmixed to mono `(L+R)/2`. Sidecar gets `"channels": "split-v1"` | `MixBus.drain`, `RecordingNamer.writeSidecar` |
| 2 | New recordings and sidecars are created 0600; a recordings folder Eko creates is 0700. Existing files and folders are not touched | `AudioFileWriter.init`, `writeSidecar`, `RecordingSession.beginRecording` |
| 3 | Warn when the recordings folder syncs to iCloud (`isUbiquitousItem` on the folder or its nearest existing parent): menu shows "Recordings Folder: … (syncs to iCloud)" with an explanation; CLI prints a warning | `RecordingOptions.syncsToICloud`, `MenuContent`, `eko` CLI |
| 4 | Tests (routing, stereo downmix, late system audio on the right channel, sidecar field and 0600) and README; `VERSION` 0.1.2 | `MixBusTests`, `README.md` |

Checked 2026-11-11 before building: `~/Documents` is already 0700, so on the default folder other users could
not read recordings (the 0644 note below overstated it; 0600 is a safeguard for custom folders). iCloud
"Desktop & Documents" sync **is on** for this Mac, so recordings in `~/Documents/CallRecordings` already go to
iCloud; moving the folder is the user's decision.

Out of scope: transcription, an "Export mixed copy" item, moving or changing existing recordings.

Ship sequence: branch → unit tests → install the build locally and make a real test recording (left ≠ right,
speech on the right, 0600, sidecar field) → PR and merge → `release.sh --local` on `main` → tag `v0.1.2` and
GitHub release → reinstall from the published release with `get-eko.sh` → smoke test.

Original notes:

1. **Channel split.** Today `MixBus` adds the microphone into both channels, so You/Others cannot be
   recovered. Change: left = microphone, right = call audio as mono. Write `"channels": "split-v1"` into the
   sidecar `.json` (`RecordingNamer.writeSidecar`). About 2 lines plus the sidecar field and a test update
   (`Tests/EkoCoreTests/MixBusTests.swift`).
   **Decided 2026-11-10 (D2 = Option A): the split file is the only file saved.** This matches common practice
   (Twilio and call-centre tools store each party on its own channel and mix down on demand). Rejected
   alternative B (keep today's blended file, write a temporary split file for transcription, then delete it):
   about a day more work, and it throws away the only split copy, so later re-transcription could not
   recover speaker labels.
   Consequences: on headphones playback is one-sided (you left, them right); macOS fixes this with System
   Settings → Accessibility → Audio → "Play stereo audio as mono". A blended copy can always be made later;
   verified on 2026-11-10 with built-in tools on a synthetic split file:
   `afconvert --mix -c 1 -f WAVE -d LEI16 in.m4a mix.wav && afconvert -f m4af -d aac mix.wav "in (mixed).m4a"`
   (each side about 3 dB quieter; an optional "Export mixed copy" menu item could match today's levels).
   Call audio is stored mono, which loses nothing for calls: the 2026-10-30 Zoom recording had identical
   left and right channels.
2. **Private files.** Recordings are currently created 0644 (readable by other local users). Create
   recordings, sidecars, transcripts and summaries 0600, and the folder 0700.
3. **iCloud.** `~/Documents` can sync to iCloud ("Desktop & Documents" setting), which would upload
   recordings and transcripts. Detect it and warn in the menu, and offer a non-synced folder.

## 8. Security and privacy

- **No network in the pipeline.** Hex and llama-server listen only on 127.0.0.1, behind a bearer token or
  API key. llama-server runs `--offline`, without the web UI or slots endpoint, on a random port.
- **Hex is a whole app with its own permissions.** It is a dictation app: on first run it asks for
  microphone (and accessibility, for pasting) access and registers a dictation shortcut. Phase 1 checks
  whether `hex transcribe` works without granting those, and whether Hex writes transcript text to its own
  logs (`hex logs`). Hex checks for updates online; Phase 1 confirms it never installs one without asking, so
  it cannot change under Eko silently. Settings: Meetings off, summaries off.
- **Temporary audio clips** live in a 0700 folder and are deleted at job end, including on failure.
- **Outputs** are 0600 and never overwrite a hand-edited file automatically.
- **Prompt injection.** The transcript is untrusted text: someone on a call could say "ignore your
  instructions". The model has no tools and its output is only written to a text file, so the worst case is
  a misleading summary. Hence the "draft" label and the timestamp check.
- **Supply chain.** Hex release zip: check `codesign -dv` and `spctl -a` in Phase 1. llama.cpp via Homebrew.
  Model files: SHA-256 pinned and checked before first use. Eko itself gains no dependencies.

## 9. Failure handling

| Failure | Behaviour |
|---|---|
| Engine not installed / lab off / model missing | Fail fast, no files written, menu shows the exact fix (`eko notes --check`) |
| Hex busy or not running | Retry / `hex start` (§5.2) |
| llama-server fails to start or crashes | Log tail saved; retry once with fallback model; else transcript only + error |
| Not enough memory | Fallback model, then defer (§6.3) |
| New recording starts mid-job | Pause after current clip; no llama-server during recording; resume after |
| Eko quits or Mac restarts mid-job | Job stays queued; resumes on next launch; orphan server killed |
| Transcript too long for the model | Transcript kept; summary skipped with message (chunking in Phase 6) |
| Disk full / write error | Atomic write fails, so no partial file; error shown |

## 10. Testing

- **Unit tests** (Swift Testing, as in `Tests/EkoCoreTests`): config decoding and defaults, VAD on synthetic
  audio, clip limits, merge and bleed removal, transcript write → parse round trip, prompt rendering,
  timestamp check, naming and overwrite rules, queue persistence.
- **Adapter contract tests with fake engines.** Tiny shell scripts stand in for `hex` and `llama-server` and
  return each exit code and reply in §5.2 / §9. This tests error handling without Hex or models, and the same
  tests run against any future adapter.
- **Real-engine smoke test** (`eko notes --check --smoke`): a bundled 10-second WAV with known words through the
  configured engines. Re-run after any Hex, llama.cpp or model update.
- **Engine comparison set**, which is what makes "switch later" a measured decision: 3–6 consented real calls
  with hand-corrected 3-minute windows, kept outside the repo. A small script computes word error rate per
  engine from `eko notes --speech <engine>` runs. Under 1 point difference is a tie.

## 11. Build phases

| Phase | Work | Estimate | Done when |
|---|---|---|---|
| **0. Prerequisites** | Channel split + sidecar field, 0600/0700 permissions, iCloud warning | 1 day | New recordings are split; tests pass |
| **1. Hands-on check (no Eko code)** | Install Hex, `hex labs on transcribe-files`, install model; convert 2–3 real calls with `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a out.wav` and run `hex transcribe`; `brew install llama.cpp`, download Qwen3-8B, run llama-server with §6.2 flags on one transcript + the Appendix A prompt; watch memory, speed, Hex permissions and logs, network | ½–1 day | **Go/no-go:** transcripts and summaries acceptable, no surprises in permissions/logs/network. If Hex fails, start with whisper.cpp instead: only Phase 3 changes |
| **2. Engine-neutral core** | Config, queue, audio prep, VAD, merge, file formats, prompt, timestamp check, interfaces, fake engines + unit tests | 2–3 days | Pipeline runs end to end with fake engines |
| **3. Hex adapter** | §5: start/quit, per-clip calls, exit-code handling, retries, `--check` | 1 day | Real recordings → `-transcript.txt` |
| **4. llama-server adapter** | §6: launch, health, sizing, memory gate, fallback, cleanup, orphan kill | 1–1.5 days | Real transcripts → `-summary.txt` |
| **5. App + CLI integration** | `.stopped` trigger, pause during recording, catch-up, menu status/actions, `eko notes` commands | 1–1.5 days | Ending a real call produces both files with no clicks |
| **6. Hardening** | Two-hour call test, failure injection (§9), chunked summary for long calls, README section | 1–2 days | All §9 cases behave as specified |

Total: about 8–11 working days. Phases 0 and 1 can run in parallel. Phase 1 is the cheapest place to learn
something that changes the plan.

**Disk:** Hex about 64 MB + speech model 731–751 MB + llama.cpp + Qwen3-8B 5.0 GB + Qwen3-4B about 2.5 GB
≈ 8.5 GB. **Time per one-hour call (estimate, unmeasured):** speech-to-text 2–5 min, summary 1–3 min. Phase 1
measures both.

## 12. Switching to whisper.cpp later (about 1 day)

1. `brew install whisper-cpp` (provides `whisper-cli`); download `ggml-large-v3-turbo-q5_0.bin` and pin its SHA-256.
2. Add `WhisperCppEngine`: capabilities `.wholeTrack`, timestamps yes; runs
   `whisper-cli -m <model> -f <track.wav> -l <lang> -oj -of <out> -np` and reads `<out>.json`
   (`transcription[].offsets.from/to` in ms, `.text`).
3. Run the fake-engine contract tests against it, then the comparison set (§10).
4. Flip `"speech": {"engine": "whisper.cpp"}`. Trigger, queue, VAD, labels, file formats, prompt and summary
   are untouched. Hex can be uninstalled or kept as the other choice.

The same steps apply to any future engine: transcribe.cpp's own CLI, Apple's SpeechAnalyzer on macOS 26, or
Ollama for summaries (its adapter must send `num_ctx`, because its 4K default would silently cut transcripts).

## 13. Risks

| Risk | Mitigation |
|---|---|
| Hex is young (repo created July 2026, 5.9k stars) and built on transcribe.cpp (2.2k stars, v0.4.1) | Engine behind the seam; whisper.cpp switch is ~1 day; smoke test after every Hex update |
| `hex transcribe` is a Labs feature and could change or disappear | Adapter checks capabilities in `prepare()`; clear error; switch engine via config |
| Hex needs mic/accessibility permissions just to serve transcriptions | Checked in Phase 1; if unacceptable, start with whisper.cpp |
| Memory pressure (swap nearly full on 2026-11-09) | Memory gate, 4B fallback, deferral, never during recording |
| Local summaries miss or invent items | "Draft" label, timestamp check, editable prompt, `--summary-only` re-runs |
| Hindi / Hinglish accuracy unknown for every model | Phase 1 on your calls; model is a config value |
| Mic bleed on speakers duplicates lines | Bleed filter; headphones recommended |

## 14. Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| D1 | Are calls English-only or mixed Hindi/English? | **Decided 2026-11-10: mixed.** Hex model `nemotron_3_5_asr`, language `auto`; Phase 1 also tries `hi` and an imported Qwen3-ASR-1.7B |
| D2 | Channel split in the main file (one-sided playback) or a separate temporary file | **Decided 2026-11-10: Option A, split main file only** (§7.1) |
| D3 | Summary model | **Decided 2026-11-10: Qwen3-8B** (Qwen3-4B fallback); switching is a config edit, no code (§6.1) |
| D4 | Summary language when calls mix Hindi and English | **Decided 2026-11-10: English**; Hinglish later by editing one prompt line, no code (Appendix A) |
| D5 | Process old recordings automatically? | **Decided 2026-11-10: new recordings only**; old ones on request (§4.1) |
| D6 | How completion is signalled | **Decided 2026-11-10: the two files in the recording's folder**; no notification; menu shows only running jobs and errors (§4.8) |

All decisions are taken. Next step: Phases 0 and 1 (§11).

---

## Appendix A. Default summary prompt (`summary-prompt.txt`)

```
You are writing notes for a recorded call. Use only what the transcript says. Never guess.

Call: {{title}}
Date: {{date}}    Duration: {{duration}}
Speakers: {{speakers}}

Write the notes in exactly this format, as plain text without Markdown:

SUMMARY
Two to four sentences: what the call was about and where it ended up.

DECISIONS
- <decision> [hh:mm:ss]

ACTION ITEMS
- <task> | Owner: <You, Others, a name said in the call, or Not stated> | Due: <date said in the call, or Not stated> [hh:mm:ss]

OPEN QUESTIONS
- <question> [hh:mm:ss]

FOLLOW-UPS
- <follow-up> [hh:mm:ss]

Rules:
- End every bullet with the timestamp of the transcript line that supports it.
- Do not invent owners, dates, names, numbers or commitments.
- If a section has nothing, write "None stated."
- Write in English, even where the call is in Hindi. Keep names, and Hindi terms with no good English
  equivalent, as they were spoken.

TRANSCRIPT
{{transcript}}
```

`{{speakers}}` for split recordings: "You = the person who recorded the call. Others = everyone else (not told
apart)." For old mixed recordings: "Speakers are not labelled."
