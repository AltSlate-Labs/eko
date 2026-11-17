# Eko — call transcript and summary with Gemini: implementation plan

Status: plan only, no code yet. Written 2026-11-15.
Decision taken (2026-11-15): the **first** transcript + summary feature uses **Google Gemini with the user's own API
key** (cloud is acceptable). The local route in `PLAN-CALL-NOTES.md` (Hex + llama.cpp) is not dropped: it stays
the later "private mode" behind the same two engine interfaces, writing the same file formats.
Background: `PLAN-SUMMARY.md` (all options), `PLAN-CALL-NOTES.md` (local plan, decisions D1–D6),
`reports/Local call transcription and summary options.md`.

---

## 1. What the user gets

After a call recording stops (or on request from the menu or CLI), Eko:

1. splits the recording into its two sides (left = microphone = **You**, right = call audio = **Others**),
2. sends each side to Gemini, which returns a timestamped transcript **in Roman script** (Hinglish romanised,
   never Devanagari),
3. merges both sides into `<name>-transcript.txt`,
4. sends the transcript text to Gemini for notes and writes `<name>-summary.txt`.

```
~/Documents/CallRecordings/
  2026-11-13 11-23 Chrome.m4a              (recording, unchanged)
  2026-11-13 11-23 Chrome.json             (existing sidecar, unchanged)
  2026-11-13 11-23 Chrome-transcript.txt   (new, 0600)
  2026-11-13 11-23 Chrome-summary.txt      (new, 0600)
```

Wall time for a 40-minute call: about 1 minute (both sides run in parallel; one side took 29–48 s in tests).
Nothing is stored in Google's Files service: audio goes inline in the request (verified 2026-11-15, §2).

## 2. Evidence this plan is built on (tests on 2026-11-13/15, real calls)

| Finding | Design consequence |
|---|---|
| Gemini **3.6 Flash** beat Hex on Hinglish: coherent fast English, Roman script directly, digits for numbers, no stray CJK characters, one line per utterance | Flash is the engine for both steps |
| **3.5 Transcribe**: returned only the last 39 words of a 19-min side; on a 2-min clip it dropped Hindi, gave no timestamps, ignored instructions, invented "Tick tick" | Not used |
| Flash with default thinking spent ~63k tokens thinking on a 39-min side and was cut off (`MAX_TOKENS`); `thinkingLevel: low` finished in 29 s with `STOP` | Always send `thinkingLevel: low`; treat `MAX_TOKENS` as a retryable chunking signal |
| Per-side transcription (L and R separately) gave clean You/Others labels with no speaker model | Keep two requests per call |
| **Inline audio works**: 19-min side, 32 kbps mono AAC = 4.4 MB file, 5.9 MB request, 39 s, 2,743 words vs 2,735 via Files API upload | No upload/poll/delete code, no orphaned files on Google |
| Timestamps came back as `[HH:MM:SS]` on one run and `[MM:SS]` on another, despite the prompt | Tolerant line parser (§5.5) |
| Remaining errors: name spellings vary (Devsur/Devsoor, Nirdesh→Nitesh), Claude→"cloud", MCP→"MCBs" | User-editable names & terms list injected into the prompt (§5.4) |
| Free-tier keys hit HTTP 429 often; 3.5 Transcribe was 503 "high demand" for ~7 min | Backoff + retry inside a request, a persistent queue across minutes/hours |
| Audio costs **25 tokens per second** per side (28,810 tokens for 19m12s, measured) | Cost model below |

## 3. Cost (Gemini 3.6 Flash, paid tier, prices read 2026-11-15)

Prices per 1M tokens: input (audio and text) **$0.75 until 2026-12-31, then $1.50**; output incl. thinking
**$3.75, then $7.50**. Measured usage per side: input 25 tokens/s; output ~5k tokens for 19–39 min of speech.

| Per call | Until 2026-12-31 | From 2027-01-01 |
|---|---|---|
| 40-minute call (2 sides ≈ 120k audio tokens + ~10k out; summary ≈ 12k in + 2k out) | ≈ $0.14 | ≈ $0.28 |
| 1-hour call | ≈ $0.21 | ≈ $0.42 |
| 40 hours of calls a month | ≈ $8 | ≈ $17 |

The model id is a setting, not code (§6.2), so a cheaper model can be tried later without a release.

**Key tier (decided 2026-11-15, G3):** Eko does not ask about or explain free vs paid tiers. It guides the user
to create a key and paste it (§7.1). If a free-tier key runs out of quota, Eko detects that error during
transcription and says so clearly (§5.3, §9).

## 4. Architecture

```
RecordingSession .stopped(url, duration)        (file closed, renamed, sidecar written)
        │  RecorderModel: enabled? key present? duration ≥ 30 s?
        ▼
NotesQueue (persisted JSON, one job at a time, survives quit/crash)
        ▼
NotesPipeline (EkoCore/Notes) ─────────────────────────────────────────────────────────────┐
  1. Read sidecar: channels "split-v1"? start time, apps heard                              │
  2. AudioPrep: decode .m4a → per side mono 16 kHz AAC 32 kbps, ≤ 40-min chunks, temp 0700  │
  3. SpeechEngine.transcribe(part) per side/chunk, sides in parallel ◄─ seam 1: Gemini      │
  4. Parse lines → offset chunk times → validate (range, repeats, script) → merge You/Others│
  5. Write <name>-transcript.txt (atomic, 0600, never overwrite automatically)              │
  6. Render summary prompt (built-in default or user file) with transcript + names          │
  7. SummaryEngine.summarise(prompt) ◄─ seam 2: Gemini                                       │
  8. Check cited timestamps against transcript → write <name>-summary.txt                   │
  9. Delete temp folder (always), log timings + token counts (never text, never the key)    │
───────────────────────────────────────────────────────────────────────────────────────────┘
```

Seams are the same idea as `PLAN-CALL-NOTES.md` §3.1, so Hex / whisper.cpp / llama.cpp can be added later as
engines without touching trigger, queue, audio prep, merge, formats or UI. Only Gemini is built now.

### 4.1 New and changed files

| File | Purpose | Est. lines |
|---|---|---|
| `Sources/EkoCore/Notes/NotesSettings.swift` | Defaults (`com.altslate.eko` suite, shared by app and CLI), model ids, chunk length, paths of the prompt and names files | 80 |
| `Sources/EkoCore/Notes/KeyStore.swift` | Gemini key in the login Keychain (`SecItem*`, generic password); `GEMINI_API_KEY` env wins (CLI) | 70 |
| `Sources/EkoCore/Notes/AudioPrep.swift` | Read recording, pick channel, resample to 16 kHz mono, find chunk cut points at quiet moments, write AAC parts | 170 |
| `Sources/EkoCore/Notes/GeminiClient.swift` | One `generateContent` call over URLSession: request JSON, inline base64 audio, retries, error mapping, host lock | 200 |
| `Sources/EkoCore/Notes/Engines.swift` | `SpeechEngine` / `SummaryEngine` protocols, `GeminiSpeech`, `GeminiSummary`, transcription prompt | 120 |
| `Sources/EkoCore/Notes/TranscriptText.swift` | Parse model lines, validate, merge sides, bleed filter, render/parse the transcript file | 200 |
| `Sources/EkoCore/Notes/Summary.swift` | Prompt template rendering, timestamp check, summary file rendering | 90 |
| `Sources/EkoCore/Notes/NotesPipeline.swift` | Orchestrates one job, progress callbacks, cancellation, temp cleanup | 140 |
| `Sources/EkoCore/Notes/NotesQueue.swift` | Persisted queue, job retry schedule, launch catch-up | 110 |
| `Sources/EkoCore/Notes/OutputFile.swift` | Atomic 0600 write, no-overwrite rule, names (`-transcript.txt`, `-summary.txt`) | 40 |
| `Sources/EkoApp/NotesModel.swift` | ObservableObject: status line, run queue, menu actions, key dialog, first-run consent | 180 |
| `Sources/EkoApp/EkoApp.swift` | "Transcripts" submenu (§7.2) | +40 |
| `Sources/EkoApp/RecorderModel.swift` | On `.stopped`: hand the URL to `NotesModel` | +5 |
| `Sources/eko/main.swift` | `eko notes …` subcommand (§7.3) | +70 |
| `Tests/EkoCoreTests/*` | Parser, merge, audio prep, client (stubbed network), summary check, queue, output rules | 450 |

About 1,500 lines of Swift plus 450 of tests on today's 2,928. **No dependencies added**: URLSession,
AVFoundation, Security are system frameworks. No entitlement change: a hardened-runtime, non-sandboxed app may
make outbound HTTPS connections without one.

### 4.2 Interfaces (sketch)

```swift
public enum Speaker: String, Codable { case you = "You", others = "Others", unlabelled = "" }

public struct AudioPart {            // one side, or one chunk of one side
    public let file: URL             // mono 16 kHz AAC in the job's temp folder
    public let speaker: Speaker
    public let offset: TimeInterval  // where this chunk starts in the recording
    public let duration: TimeInterval
}

public struct Segment: Equatable { public var start: TimeInterval; public var speaker: Speaker; public var text: String }

public struct EngineInfo { public let name: String; public let model: String }   // goes into file headers
public struct Usage { public var inputTokens = 0, outputTokens = 0, thoughtTokens = 0 }

public protocol SpeechEngine {
    var info: EngineInfo { get }
    /// Segments with times relative to the part; the pipeline adds `offset`.
    func transcribe(_ part: AudioPart, names: [String]) async throws -> (segments: [Segment], usage: Usage)
}

public protocol SummaryEngine {
    var info: EngineInfo { get }
    func summarise(prompt: String) async throws -> (text: String, usage: Usage)
}
```

## 5. Pipeline details

### 5.1 Trigger and queue

- Hook in `RecorderModel.handle(.stopped(url, duration))` (the file is complete at that point: writer closed,
  file renamed, sidecar written; see `RecordingSession.stop()`).
- Enqueue only if: automatic mode on (**default on**, decided 2026-11-15, G1), a key is stored, duration ≥ 30 s
  (accidental recordings).
- Queue file: `~/Library/Application Support/Eko/notes-queue.json` (0600): `{path, size, mtime, addedAt,
  attempts, nextTryAt, lastError}`. One job at a time. Jobs whose recording was moved or deleted are dropped.
- **Catch-up on launch**: unfinished jobs resume. **Scope (D5 carried over)**: only recordings made after the
  feature is on are automatic; older ones on request ("Transcribe a Recording…", `eko notes`).
- **Recording in progress**: jobs may run (network-bound; audio prep is a few seconds of `.utility` QoS work),
  but audio prep of a new job does not start while a recording is in its first 10 s (device spin-up).
- Hold `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` during a job.
- Job-level retry for network/server failures: after 1 min, 5 min, 30 min, 2 h; then "failed" with a Retry
  action. Key or model errors fail immediately (no point retrying).

### 5.2 Audio preparation

- Read the sidecar: `"channels": "split-v1"` → two parts (left = You, right = Others). No field (recordings
  before 0.1.2) → one part, both channels mixed, `Speaker.unlabelled`.
- Decode in blocks with `AVAudioFile` (an hour is never fully in memory), take the channel, resample with
  `AVAudioConverter` to 16 kHz mono (Gemini downsamples to 16 kHz anyway), encode AAC 32 kbps into
  `.m4a` with `AVAudioFile(forWriting:)`. Size ≈ 14 MB/hour/side.
- **Silent side**: if a side's peak stays under −50 dBFS for the whole call (mic muted throughout, or no system
  audio captured), skip it, saving cost, and say so in the transcript header.
- **Chunking**: sides longer than `chunkMinutes` (default 40, the longest length tested in one request) are cut
  at the quietest 500 ms window in the 3 minutes before each boundary, so no word is cut. No overlap, so no
  de-duplication needed. Each chunk keeps its `offset`.
- Temp folder: `FileManager.temporaryDirectory/eko-notes-<uuid>` (0700), removed in `defer`; leftovers from a
  crash are removed on launch.

### 5.3 Gemini client

- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`.
  Key in the `x-goog-api-key` header (never in the URL, so it cannot leak into logs or error text).
- Ephemeral `URLSession` (no cache, no cookies), request timeout 300 s, resource timeout 900 s.
  A redirect delegate refuses any redirect (the API never redirects; a redirect off-host is a red flag).
  The host is a constant, as `Updater.checkSource` does for GitHub.
- Body: one user turn with `inline_data {mime_type: "audio/mp4", data: <base64>}` + the text prompt, or text
  only for the summary. A 40-min chunk ≈ 9.6 MB file ≈ 13 MB request; the inline limit is 100 MB.
- `generationConfig`: `thinkingConfig.thinkingLevel = "low"`, `maxOutputTokens = 65536`,
  `temperature: 0` (Phase 0: no loops; the default temperature let 2 non-Latin letters through).
- Response: join `candidates[0].content.parts[].text` (also accept `audioTranscription.text`, seen on the
  Transcribe model); read `finishReason` and `usageMetadata` (prompt, candidates, thoughts tokens).
- Retries inside one call:

| Response | Action |
|---|---|
| 200 + `STOP` | done |
| 200 + `MAX_TOKENS` | `chunkTooLong`: pipeline halves the chunk at a quiet point and retries once |
| 200 + `SAFETY` / `RECITATION` / `OTHER` / no candidates | fail part with the reason (logged, no text) |
| 429, per-minute limit | honour `RetryInfo.retryDelay` if present, else 10 s, 30 s, 60 s, 120 s; then job-level retry |
| 429, **daily quota exhausted** (`RESOURCE_EXHAUSTED` whose `QuotaFailure` violation names a per-day quota, e.g. `quotaId` contains `PerDay`) | `quotaExhausted`: no in-call retries; queue paused until the next quota reset (midnight Pacific time), then resumes by itself; menu shows the message in §9 |
| 500 / 503 / 504, timeouts, connection lost | 5 s, 15 s, 45 s, 120 s; then job-level retry |
| 400 | fail (bug or unsupported audio); log status and Google's error message (no content) |
| 401 / 403 | `keyRejected`: stop the queue, menu says the key is invalid or the API is not enabled |
| 404 | `modelNotFound`: menu says the model id is retired and how to change it (§6.3) |

### 5.4 The transcription request

Prompt (Appendix A) asks for verbatim Hinglish in Roman script, one line per utterance as `[HH:MM:SS] text`,
no translation, no summarising, silence skipped. It appends the user's **names and terms** (from
`~/Library/Application Support/Eko/names.txt`, one per line, e.g. company, colleague and product names) as
"Spell these as written when they occur". The prompt is built in (not user-editable) so the output stays
parseable; the names list is the user's lever.

### 5.5 Parse, validate, merge

1. **Parse** each line with `^\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]\s*(.*)$` (accepts `[HH:MM:SS]`, `[H:MM:SS]`,
   `[MM:SS]`); a line without a timestamp is joined to the previous segment. If more than 20 % of non-empty
   lines fail to parse, the part counts as failed and is retried once.
2. **Range**: drop segments that start after the part's duration + 5 s (hallucinated tail); count them.
3. **Order**: stable sort by start (the model is usually monotonic; this fixes the odd swap).
4. **Repeats**: collapse more than 3 consecutive identical lines (a known model failure on noise).
5. **Script check** (Roman-script rule): count letters outside Latin/digits/punctuation (Devanagari
   U+0900–U+097F, CJK, others). Above 1 % of letters → retry the part once with a firmer instruction; if still
   above, keep it and flag it in the header.
6. **Offset**: add the chunk's `offset`.
7. **Merge** both sides by start time; ties keep You before Others.
8. **Mic bleed** (user on speakers, so the mic also hears the other side): drop a You segment that starts within
   3 s of an Others segment, has ≥ 4 words, and shares ≥ 60 % of its words with it. Headphones avoid it.

### 5.6 Transcript file (same format as `PLAN-CALL-NOTES.md` §4.5, so engines are interchangeable)

```
Eko call transcript
Recording: 2026-11-13 11-23 Chrome.m4a
Date: 2026-11-13 11:23 · Duration: 00:38:51 · Apps: Chrome
Speech-to-text: Gemini gemini-3.6-flash (Google cloud; audio sent to Google) · Eko 0.2.0
Speakers: You = this Mac's microphone · Others = call audio (other people are not told apart)
Checks: script OK · 0 out-of-range lines removed · 2 echo lines removed
------------------------------------------------------------
[00:00:03] You: Hello.
[00:00:05] Others: Haan, audible hai. Shall we start with the pricing update?
```

UTF-8 plain text; parseable back into segments, so `--summary-only` works without re-sending audio and a
hand-corrected transcript can be re-summarised.

### 5.7 Summary

- Prompt: `~/Library/Application Support/Eko/summary-prompt.txt` if the user created one ("Edit Summary Prompt"
  writes the default out first), else the built-in default (Appendix B = `PLAN-CALL-NOTES.md` Appendix A with
  two additions: Roman script for any Hindi, and the user's name). Placeholders `{{transcript}}`, `{{title}}`,
  `{{date}}`, `{{duration}}`, `{{speakers}}`, `{{names}}`. English output (D4 carried over).
- `names.txt` may contain a line `me: <name>`; then `{{speakers}}` reads "You = <name>, who recorded the call.
  Others = everyone else (not told apart)", so action items say "Owner: Nirdesh" instead of "Owner: You".
- Same model, text only, `thinkingLevel: medium` (Phase 0: richer action items for ~$0.015 more per call).
- **Timestamp check**: every `[hh:mm:ss]` the model cites must match a transcript line within ±10 s. Footer:
  `Checks: 14 of 15 cited timestamps match a transcript line.` The summary is labelled "check against the
  transcript": the transcript is untrusted input (§8) and the model can still miss or invent items.

```
Eko call summary (made by Gemini gemini-3.6-flash; check it against the transcript)
Recording: 2026-11-13 11-23 Chrome.m4a · Prompt: built-in default
------------------------------------------------------------
<model output>
------------------------------------------------------------
Checks: 14 of 15 cited timestamps match a transcript line.
```

### 5.8 Output rules (as `PLAN-CALL-NOTES.md` §4.7)

- Same folder as the recording; `<base>-transcript.txt`, `<base>-summary.txt`; works for `.m4a` and `.wav`.
- Write to a temp file in the same folder, then rename (atomic); permissions 0600.
- Automatic jobs never overwrite existing files (a hand-edited transcript or summary is never lost). Manual runs
  ask first (menu) or need `--force` (CLI).
- If the summary fails, the transcript is kept and the job is marked "summary failed" (retry re-summarises only).

## 6. Key, settings and files

### 6.1 API key

- Stored in the login Keychain as a generic password (service `com.altslate.eko.gemini`, account `api-key`) via
  `SecItemAdd`/`SecItemCopyMatching`. Not the data-protection keychain: that needs a provisioning profile,
  which the self-signed "Eko Dev" release identity does not have.
- The Keychain ties access to the app's signature, so signed updates keep access silently; ad-hoc development
  builds will show a Keychain prompt (expected).
- The CLI reads `GEMINI_API_KEY` first (a different binary would trigger a Keychain prompt on every run), then
  the Keychain.
- Never written to disk elsewhere, never logged, never put in a URL, never echoed in error text. The menu shows
  only "Gemini key: set (…last 4 characters)".
- Validated when entered with `GET /v1beta/models/<model>` (no tokens used).

### 6.2 Settings (UserDefaults suite `com.altslate.eko`, read by app and CLI)

| Key | Default | Notes |
|---|---|---|
| `notes.auto` | `true` (G1) | transcribe every call ≥ 30 s automatically; menu toggle turns it off |
| `notes.minimumSeconds` | 30 | skip shorter recordings |
| `notes.transcribeModel` | `gemini-3.6-flash` | model ids are retired often: change with `defaults write com.altslate.eko notes.transcribeModel <id>`, no release needed |
| `notes.summaryModel` | `gemini-3.6-flash` | |
| `notes.thinkingLevel` / `notes.summaryThinkingLevel` | `low` / `medium` | Phase 0 (§11.1) |
| `notes.chunkMinutes` | 40 | also used to exercise chunking on short calls in tests |

### 6.3 Files in `~/Library/Application Support/Eko/` (folder 0700, files 0600)

`notes-queue.json`, `names.txt` (created with explanatory comment lines, empty list), `summary-prompt.txt`
(only if the user chose to edit it).

## 7. User interface

### 7.1 Setting the key (G3: guide, don't lecture)

Shown from "Transcripts ▸ Set Gemini Key…", and once after the first recording stops while no key is set
(not again after Cancel; the menu keeps showing "Set Gemini Key…"). One dialog (NSAlert + secure text field):

> **Get transcripts and summaries of your calls**
> Eko uses Google Gemini. You need a free API key:
> 1. Click **Get a Key** (opens aistudio.google.com/api-keys) and sign in with your Google account.
> 2. Click **Create API key**, then copy it.
> 3. Paste it below and click **Save**.
> Eko sends each call's audio to Gemini to transcribe it.
> [ key field ]   [Save] [Get a Key] [Cancel]

- **Get a Key** opens the page and keeps the dialog open.
- **Save** trims whitespace and checks the key with `GET /v1beta/models/gemini-3.6-flash`, which uses no tokens.
  - Valid: store it in the Keychain and show "Key saved. New calls will be transcribed automatically."
  - Rejected (400/401/403): "Google did not accept this key. Copy it again from AI Studio." The dialog stays open.
  - Offline: "Couldn't reach Google to check the key. Saved anyway; it will be checked on the next call."
- No tier, billing or pricing text in the app. The README gives the same three steps, plus one line on what is sent.

The same steps work from the CLI: `export GEMINI_API_KEY=…` or `eko notes --set-key` (reads the key from stdin
so it stays out of shell history, then stores it in the Keychain).

### 7.2 Menu

```
Recording / status line
───────────
Start Recording            ⌘R
───────────
Show Last Recording
Open Recordings Folder
Recordings Folder: … ▸
Transcripts ▸
    Transcribing 2026-11-13 11-23 Chrome… (2 of 3: summary)    ← only while running
    Last transcript failed: network offline. Retry             ← only after a failure
    Transcribe Last Recording
    Transcribe a Recording…                                    ← file picker, any older recording
    ───────────
    ✓ Transcribe Every Call Automatically
    Names & Terms…                                             ← opens names.txt in TextEdit
    Edit Summary Prompt…
    ───────────
    Set Gemini Key…                        ← when no key is stored
    Gemini Key: set (…uM) ▸  Replace… · Remove · Get a Key (opens AI Studio)
When a call starts ▸
…
```

Completion signal (D6 carried over): the two files appear next to the recording; no notification; success is
silent. "Show Last Recording" selects the recording in Finder, so the transcript sits beside it. When the folder
syncs to iCloud, the existing warning adds: "Transcripts and summaries sync too."

### 7.3 CLI (`eko notes`)

```
eko notes "<recording>.m4a"              transcribe + summarise one recording
eko notes --summary-only "<recording>"   re-summarise from the existing transcript (no audio sent)
eko notes --force …                      overwrite existing outputs
eko notes --model <id> …                 one-off model override, for comparisons
eko notes --check                        key valid? models reachable? (no audio sent)
eko notes --set-key                      read a key from stdin, check it, store it in the Keychain
```

Prints progress and token usage on stderr; key from `GEMINI_API_KEY`, else the Keychain. `main.swift` checks
for `notes` as the first argument before its existing option loop.

## 8. Security and privacy

- **What leaves the Mac, and only when a key is set:** each side's audio (as AAC), then the transcript text,
  to `generativelanguage.googleapis.com` over TLS. Nothing else; no file names (no Files API, so no display
  names either). Today Eko's only network use is the GitHub update check; the README says this changes.
- **Tiers**: not explained in the app (G3). The README links to Google's Gemini API terms.
- **Key**: Keychain; header only; never logged (§6.1). A unit test checks that thrown errors and log lines
  never contain the key.
- **Logs** (`~/Library/Logs/Eko.log`): job id, durations, part sizes, token counts, HTTP status, finish reason.
  Never transcript or summary text, never the key.
- **Temp audio**: 0700 folder, deleted at job end and swept on launch.
- **Outputs**: 0600, atomic, never overwritten automatically.
- **Prompt injection**: someone on a call can say "ignore your instructions". The model has no tools and its
  output only becomes a text file, so the worst case is a misleading summary; hence the "check it" label and
  the timestamp check.
- **Host lock**: fixed host, redirects refused, HTTPS only (ATS default).
- **Consent**: sending other people's voices to a processor raises the consent bar; the README says the user is
  responsible. (The CLAUDE.md rule "don't upload recordings unless asked" stays for Claude
  sessions.)

## 9. Failure handling

| Failure | Behaviour |
|---|---|
| No key / key rejected (401/403) | Nothing sent; menu shows "Add / replace Gemini key"; queue paused |
| Model retired (404) | Job fails with the exact `defaults write` fix; queue paused |
| Daily quota exhausted (free-tier limit) | Queue paused; menu status: **"Gemini's free daily limit is used up. Transcripts will continue after it resets (about 1:30 pm IST)."** The reset time is shown in local time, calculated from midnight Pacific. A "Get a Key" item stays available. Waiting jobs resume by themselves after the reset; no files are written meanwhile. CLI: same message, exit code 3 |
| Offline, timeouts, 5xx, per-minute 429 | In-call retries (§5.3), then job retries at 1 min, 5 min, 30 min, 2 h; then "failed" + Retry |
| `MAX_TOKENS` | Chunk halved at a quiet point, retried once; then failed with reason |
| Output in Devanagari | Retry once with firmer instruction; else kept and flagged in header |
| Side silent | Skipped, noted in header |
| Summary fails | Transcript kept; "summary failed"; Retry re-summarises only |
| Eko quits / Mac restarts mid-job | Job resumes on next launch; temp folder swept |
| Recording moved/deleted before the job runs | Job dropped, logged |
| Output file already exists | Automatic: skip and log; manual: ask / `--force` |
| Disk full | Atomic write fails, no partial file; error shown |

## 10. Testing

**Unit tests** (Swift Testing, as in `Tests/EkoCoreTests`; no network, no real call content in the repo):
- `TranscriptText`: parse `[HH:MM:SS]` / `[MM:SS]` / continuation lines, range drop, repeat collapse, script
  check (Devanagari and CJK samples), offsets, merge order, bleed filter, render → parse round trip.
- `AudioPrep`: synthetic stereo file (tone on left, silence on right) → left part has audio, right flagged
  silent; chunk cut lands in a quiet gap; output is mono 16 kHz AAC; mixed (no sidecar field) → one unlabelled part.
- `GeminiClient` with a stub `URLProtocol` (Foundation, no deps): request shape (header key, no key in URL,
  base64 audio, thinking config), 503→200 retry, 429 with `retryDelay`, 429 daily-quota body → `quotaExhausted`
  with no retries (fixture shaped like Google's `RESOURCE_EXHAUSTED` + `QuotaFailure` error), 401/404 mapping, `MAX_TOKENS` signal,
  off-host redirect refused, key absent from every error description.
- `Summary`: placeholder rendering, `me:` line, timestamp check (exact, ±10 s, missing).
- `NotesQueue`: persistence, retry schedule, dropped missing files. `OutputFile`: 0600, atomic, no overwrite.

**Acceptance on real calls** (local only; outputs never committed):
- The two 2026-11-13 calls through `eko notes`: within ±5 % of the word counts of the 2026-11-13 Gemini runs
  (`You 2,309 / Others 3,289` and `You 2,561 / Others 318`), no Devanagari, last timestamp within 30 s of the
  end, summary timestamp check ≥ 90 %, wall time < 2 min per call, tokens logged.
- Chunking on real audio: same call with `notes.chunkMinutes = 15`; check the seams (no lost or duplicated lines).
- One pre-0.1.2 (mixed) recording → unlabelled transcript.
- A real call ended with the menu: both files appear with no clicks.

## 11. Build phases

| Phase | Work | Estimate | Done when |
|---|---|---|---|
| **0. Remaining checks** | ✅ Done 2026-11-15, results in §11.1 | ½ day | Thinking, temperature and prompt chosen with evidence |
| **1. Core library** | §4.1 EkoCore files + unit tests | 2–2.5 days | `swift test` green; pipeline runs end to end against the stubbed client |
| **2. CLI** | `eko notes` (§7.3) | ½ day | Acceptance runs on the 13 Nov calls pass (§10) — **usable from here** |
| **3. App** | Queue, `.stopped` hook, Transcripts menu, key dialog + consent, status/errors, names & prompt editing | 1–1.5 days | Ending a real call produces both files with no clicks |
| **4. Hardening** | Chunking on real audio, failure injection (offline, 429, daily quota, bad key, retired model, quit mid-job), long call | 1 day | All §9 rows behave as specified |
| **5. Docs + release 0.2.0** | README "Transcripts and summaries" (get and set a key in 3 steps, what is sent, CLI), CLAUDE.md note, `VERSION` 0.2.0, PR, `release.sh`, GitHub release, reinstall with `get-eko.sh`, smoke test | ½ day | Release installed from GitHub transcribes a real call |

### 11.1 Phase 0 results (2026-11-15)

| Check | Result | Decision |
|---|---|---|
| Inline audio | 19-min side, 5.9 MB request, 39 s, same transcript as Files API | Inline only, no Files API |
| AVFoundation encode | Swift splitter: 19-min side → mono 16 kHz AAC ~30 kbps, 4.5 MB, **2 s per side**. The file must be closed (`AVAudioFile.close()` on macOS 15, release the object on 14) or it has no `moov` atom and is unreadable | AudioPrep as designed; explicit close |
| Thinking, transcription | low/minimal/default-temperature: all `STOP`, 2,766–2,781 words, **0 thinking tokens** in every case, ~27–37 s. Differences are romanisation spellings (yeh/ye, mein/me); minimal once kept a sentence low shortened | `low`, temperature 0 (0 non-Latin letters; default temperature produced 2) |
| Timestamps | All three runs used `[MM:SS]` for a 19-min side | Tolerant parser confirmed necessary |
| Summary, `low` | 39-min call: 9 s, 14.5k in / 0.3k out / 1.2k thinking; 7/7 cited timestamps exact; accurate but sparse (2 decisions, 2 actions) | — |
| Summary, `medium` | 20 s, 4.1k thinking (+≈ $0.015); 8/8 exact; one more open question, action items carry more context (ticket, folder) | **`medium` for summaries** |
| Summary language | One due date left as "17 tareekh" | Prompt rule: dates and all other text in English |
| 429 body | Could not provoke one (5 parallel requests all 200). Google documents only `429 RESOURCE_EXHAUSTED` and that **RPD quotas reset at midnight Pacific** | Classify daily quota if any `QuotaFailure` violation's `quotaId`/`quotaMetric` contains `PerDay`/`per_day`, or `retryDelay` > 10 min; otherwise per-minute. If 429s outlast the per-minute retries, the menu says "Gemini's usage limit was reached" and jobs retry on schedule. Fixture uses Google's standard `google.rpc` error shape |

### 11.2 Build progress (2026-11-15, branch `transcripts-gemini`, not committed)

- **Phase 1 done**: `Sources/EkoCore/Notes/` (settings, Keychain, audio prep, client, engines, transcript text,
  summary, pipeline, queue, output files); 40 tests pass (`swift test`), network stubbed.
- **Phase 2 done**: `eko notes` (`Sources/eko/NotesCommand.swift`). Acceptance on copies of the two 13 Nov calls
  (outside the iCloud folder): 39-min call 74–89 s, You 2,295 / Others 3,259 words; 19-min call 44 s,
  You 2,568 / Others 314 (both within 1 % of the earlier runs); Roman script; summaries 9/9 and 9/9 timestamps.
  Chunking on real audio (15-min pieces): 6 parts, no gaps at seams, 35 s.
- **Bug found and fixed in acceptance**: one answer used `[MM:SS:hundredths]` stamps, read as hours, so 261 lines
  were dropped as "past the end". Parser now picks the reading that fits the audio; a part with > 20 % of lines
  past the end is retried. Covered by tests.
- **Free tier is 20 requests a day per model** (real 429 captured: `GenerateRequestsPerDayPerProjectPerModel-FreeTier`,
  `quotaValue 20`, `retryDelay` to midnight Pacific). A call costs one request per piece + one for the summary, so
  ~6 calls a day with 40-min pieces. Default chunk stays 40 min (20 min was faster but costs more requests). The
  reset time now comes from Google's `retryDelay`. Fixture updated to the real body.
- **Phase 3 code done** (`NotesModel.swift`, Transcripts menu, key dialog, `.stopped` hook); builds. Not yet
  tried in the installed app: needs a local install and a key pasted into the dialog by the user.
- Log check: no key and no transcript text in `~/Library/Logs/Eko.log`.

Total about 5½–6½ working days. Phases 1 and 2 give a working CLI on real calls in about 3 days; the menu-bar
experience follows. Ship sequence as for 0.1.2: branch → tests → local install + real call → PR → merge →
release → reinstall from the published release.

## 12. Later (not in 0.2.0)

- **Private mode**: Hex or whisper.cpp + llama.cpp as `SpeechEngine` / `SummaryEngine` (`PLAN-CALL-NOTES.md`),
  chosen in the menu; same file formats, so outputs stay comparable.
- Mixed mode: local transcript (audio never leaves the Mac), Gemini summary from text only.
- Speaker names on the Others side (Gemini can be asked to separate voices; untested and unreliable on one
  channel).
- "Discuss in Claude Code" / MCP connector over the transcripts (`PLAN-SUMMARY.md` §5–6).

## 13. Risks

| Risk | Mitigation |
|---|---|
| Gemini model ids change fast (3.5 Transcribe was unavailable for minutes; previews retire) | Model id is a setting; 404 → clear fix; `eko notes --check` |
| Prices double on 2027-01-01 | Model id is a setting, so a cheaper model can be swapped in without a release |
| Free-tier daily limit runs out on busy days | Detected (`quotaExhausted`); clear menu message; jobs resume after the reset |
| Timestamp format drift (seen: `[MM:SS]`) | Tolerant parser, range checks, retry on unparseable output |
| Long-audio drift or truncation | 40-min chunks; `MAX_TOKENS` handling |
| Devanagari or other scripts slip in | Script check + retry + header flag |
| Hallucinated lines in silence | "Skip silence" prompt, range drop, repeat collapse, silent-side skip |
| Rate limits / outages | In-call backoff, persistent queue with job retries |
| Others' consent / legal exposure | Setup text, README; user's responsibility |
| Summary misses or invents items | "Check it" label, timestamp check, editable prompt, `--summary-only` |

## 14. Decisions

| # | Decision | Recommendation |
|---|---|---|
| G1 | Trigger | **Decided 2026-11-15: automatic after every call ≥ 30 s**, on by default once a key is set; menu toggle to turn off |
| G2 | Model | **Decided 2026-11-15: gemini-3.6-flash for both steps** |
| G3 | Key tier | **Decided 2026-11-15: no tier talk in the app.** Guide the user to get and paste a key (§7.1); detect the free-tier daily-quota error and show a clear message (§5.3, §9) |
| G4 | Summary format | Keep `PLAN-CALL-NOTES.md` Appendix A (plain text, English, timestamps) with the two additions in Appendix B |
| G5 | Speaker labels | **You / Others**, with optional `me: <name>` in names.txt for the summary |
| Carried over | D4 English summary · D5 new recordings automatic, old ones on request · D6 files appear, no notification | unchanged |

---

## Appendix A. Transcription prompt (built in)

```
Transcribe this audio verbatim. It is one side of a business call; speech mixes Hindi and English.
Write EVERYTHING in Roman (Latin) script: English words in normal English spelling, Hindi words in common
everyday Hinglish romanisation (e.g. nahi, yaar, accha, theek hai). Never use Devanagari or any other script.
Do not translate, summarise, clean up or skip anything. Skip silence.
Output one line per utterance in the form [HH:MM:SS] text, where the timestamp is the start time from the
beginning of the audio. Output only the transcript.
{{#names}}Names and terms that may occur; spell them exactly like this: {{names}}{{/names}}
```

(The first part is the prompt used in the 2026-11-13 tests, unchanged; the names line is new.)

## Appendix B. Default summary prompt

`PLAN-CALL-NOTES.md` Appendix A, with these rule lines added:

```
- Write in English, including dates (e.g. "the 17th", not "17 tareekh"). Where you quote Hindi words or terms,
  write them in Roman script, never Devanagari.
- Spell names and terms as in this list: {{names}}
```

and `{{speakers}}` as in §5.7.
