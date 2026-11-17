# Eko — call transcription and LLM summary: options and plan

Status: analysis only, no code. Written 2026-11-02 from the discussion on 2026-10-30 to 2026-11-02.
Companion to `PLAN.md` (recorder) and `README.md`. Decisions still open are listed at the end.
Update 2026-11-09: the local route to build is in `PLAN-CALL-NOTES.md` (Hex + llama.cpp first, switchable to whisper.cpp).

## 1. Goal

After a recording stops, produce a written summary of the call (TL;DR, decisions, action items with
owners, open questions, follow-ups) next to the `.m4a`, with options that respect what the end user
prefers: privacy, cost, quality, setup effort, and how automatic it should be.

## 2. The pipeline has two independent stages

```
audio (.m4a)  ->  transcript (speech-to-text)  ->  summary (LLM)
```

Claude models accept text, images and PDFs, not audio. The Claude API, Claude Code and the Claude
desktop app cannot hear a recording. Transcription is therefore always a separate step; the LLM
stage only ever sees text. When the Claude desktop app "summarised a recording", it improvised:
it ran Whisper (an open model) inside its cloud sandbox to make a transcript first (see 6.4).

Eko's structural advantage: it captures the microphone and the system audio as separate streams
while recording. Transcribing them separately and merging by timestamp gives "You" / "Others"
labels on every line with no speaker-diarisation model. This is the single biggest quality lever and
it is free. (Note: the stored file is a single mixed stereo .m4a; labelling must happen at recording
time or from a split-track file, see PLAN.md section 6.)

## 3. Stage 1 — transcription options

| Option | Privacy | Cost | Quality | Setup | Deps added | Intel | macOS |
|---|---|---|---|---|---|---|---|
| Apple Speech on-device (`SFSpeechRecognizer`, `requiresOnDeviceRecognition`) | Local | Free | Fair on clear English; weak on accents, crosstalk; one language per session | One permission prompt | None | Yes | 14+ |
| Apple SpeechAnalyzer | Local | Free | Good, built for long-form | None | None | Yes | 26+ only |
| whisper.cpp vendored as a C target in the SwiftPM package | Local | Free | Good to near-best depending on model; multilingual incl. code-switching (e.g. Hindi/English) | Model download on first use (150–570 MB) | One MIT C library, pinned | Yes, CPU only, slow | 14+ |
| sherpa-onnx (what Claude used in its sandbox) | Local | Free | Same models as above | Prebuilt onnxruntime (~30 MB+), CMake | Heavy | Yes | 14+ |
| WhisperKit (Swift package, Core ML) | Local | Free | Very good | Model download | Several Swift packages | No | 14+ |
| User-installed `whisper-cli` (Homebrew) | Local | Free | Same as whisper.cpp | User installs it | None in Eko | Yes | any |
| Cloud STT (Deepgram, AssemblyAI, OpenAI) | Audio leaves the Mac | ~$0.15–0.40 / hour | Best; true multi-speaker diarisation | API key | None (raw HTTPS) | Yes | any |

### 3.1 Whisper via whisper.cpp (recommended quality engine)

Why this and not what Claude ran: same models, but a C library that compiles with the command-line
tools alone, Metal GPU and optional Core ML encoder on Apple Silicon, no Python, no onnxruntime.
whisper.cpp uses 30-second windows that slide along timestamps, so it does not cut words the way the
fixed 25-second chunks in Claude's sandbox did.

Model choice (download on first use, hosted on Eko's own GitHub release with sha256, because the
originals live on Hugging Face which some networks block):

| Model | Download | Quality | 1-hour call on Apple Silicon with Metal (rough) |
|---|---|---|---|
| base.en | ~150 MB | Fair | 1–2 min |
| small | ~490 MB | Good | 2–4 min |
| large-v3-turbo, 5-bit quantised | ~570 MB | Near best | 5–10 min |

Intel Macs: base or small on the CPU, a sizable fraction of the call length.

What changes in Eko:
- `Transcriber` protocol with two built-ins: Apple Speech (zero-setup default) and Whisper (opt-in,
  triggers the model download). Summary layer sits on top unchanged.
- Run after stop, never during capture; background QoS; progress line in the menu; cancellable.
- Dual-stream "You"/"Others" labels merged by timestamp.
- Output: Markdown transcript with timestamps next to the recording + JSON sidecar for re-summarising.
- Build plumbing: embed whisper.cpp's Metal shaders as a resource; compile the library for both
  architectures in the universal build. About a day.

Rule being relaxed: "no third-party code" becomes "one vendored MIT C library, pinned, updated
deliberately". Binary grows a few MB; DMG stays small because models are downloaded on demand.

Risks: minutes of CPU/GPU time and heat (make it visible and interruptible); Whisper hallucinates on
long silences (skip silent stretches by energy level first); a 500 MB first-run download needs resume
and a clear prompt; timestamp merging across two streams needs care.

## 4. Stage 2 — summarisation options

| Option | Privacy | Cost per 1-hour meeting | Quality | Setup |
|---|---|---|---|---|
| Claude API, bring your own key (raw HTTPS from Swift, key in Keychain, streaming, structured output) | Transcript leaves the Mac; API data is not used for training | Opus 5.5 ~$0.09, Sonnet 5.5 ~$0.05, Haiku 5.5 < $0.01 | Best | Paste key once |
| Claude Code, user's subscription (headless `claude -p`) | Transcript leaves the Mac; consumer terms (may be used for training unless opted out) | $0 marginal; shares the 5-hour usage window | Best | Claude Code installed and logged in |
| Claude desktop app via MCP connector (see 6.2) | Same as above | $0 marginal | Best, interactive | One-time connector entry |
| Ollama, local models | Local | Free | Fair to good; needs 16 GB RAM and a good chip | Install Ollama, pull a model |
| Apple Foundation Models | Local | Free | Basic; small context so long calls need chunking | None | (macOS 26+ only) |
| No LLM, transcript only | Local | Free | A searchable transcript is already useful | None |

API defaults if built: model `claude-opus-5-5`, adaptive thinking, streaming, structured output
rendered to Markdown. Swift has no official SDK, so use plain URLSession against the Messages API.

## 5. Options for users with a Claude Code subscription

Claude Code cannot hear audio; Eko still produces the transcript. Once a transcript exists:

1. **Interactive, not headless (cheapest, arguably most useful).** Menu item "Discuss Last Call in
   Claude Code" opens Terminal in the recordings folder with the transcript preloaded; the user asks
   follow-ups ("what did I promise", "draft the follow-up email").
2. **A skill shipped with Eko.** A `call-notes` skill folder in the repo (installable into
   `~/.claude/skills`) with `/summarize`, `/action-items`, `/followup-email`. Prompts live in Markdown
   the user can edit; no Eko release needed to change a template; Eko stays free of LLM code.
3. **Recordings folder as a knowledge base.** A CLAUDE.md in the folder describing the layout; Claude
   Code then answers across all past calls ("what did we agree with that vendor in September",
   "weekly digest"). Grep over local files; nothing uploaded in bulk.
4. **Lightweight CRM in Markdown.** The skill maintains one file per person/company with commitments
   and decisions after each call; "brief me on them" before the next call.
5. **Actions through MCP connectors.** With Gmail, Calendar, Slack, Jira or Linear connected in
   Claude Code: draft the follow-up, create the calendar hold, file a ticket per action item, post the
   summary to a channel. Each action confirmed by the user.
6. **Claude Cowork on the desktop app.** Max subscribers on macOS can give Cowork the recordings
   folder and a recurring task "summarise any transcript without a summary file". No terminal.
7. **Claude Code orchestrating local transcription.** If the user has a local Whisper tool, the skill
   can transcribe old recordings before summarising. Power users only.
8. **Headless shell-out from Eko.** Eko locates the user's `claude` binary (apps launched from Finder
   do not inherit the shell PATH) and runs, with the transcript on stdin:

   ```sh
   claude -p "Summarise this call: TL;DR, decisions, action items with owners, open questions." \
     --model claude-opus-5-5 --output-format json --max-turns 1 --tools "" < transcript.md
   ```

   Parse only the `result` field. A fourth backend behind the Summarizer protocol:
   "Claude Code (uses your subscription)", detected and opt-in, greyed out when missing.

Not an option: the Claude Agent SDK (no Swift SDK; subscription login is not a supported auth path,
it needs an API key, which is just the API route again).

Caveats for all subscription routes:
- Terms of use: Anthropic restricts using a Pro/Max subscription from third-party tools. Launching the
  official binary the user installed and logged into is the most defensible form. Eko must never
  extract the OAuth token and call the API with it.
- Training data: subscription usage falls under consumer terms (content may be used for training
  unless the user turned it off). API usage is not. Say this plainly in the README since the words
  belong to other call participants.
- Rate limits: shares the user's 5-hour window; a 1-hour call is ~10–15k tokens, negligible, but a
  heavy coding session could delay the summary.
- Fragility: CLI flags and JSON output are not a stable contract; keep the invocation minimal.
- Availability: only users with Claude Code benefit; the API key and local paths remain necessary.

First to build among these: options 1 and 2 together (skill in the repo + menu item opening Claude
Code in the recordings folder); about half a day once transcripts exist; options 3 and 4 then come
almost free as extra prompts in the same skill.

## 6. Using the Claude desktop app

### 6.1 Scripting the Claude window from Eko — rejected

Ask: open a new chat, attach the audio, paste a prompt, wait, copy the reply back, save it next to
the audio. Technically possible via macOS accessibility scripting; practically the worst route:
- Needs Accessibility + Automation (System Events) permissions: two more scary prompts.
- Electron accessibility tree must be forced on and changes with every app update; every selector
  (new chat, attach, Open dialog keystrokes, "Copy" under the reply, stop-button polling) breaks silently.
- The Claude window must stay frontmost for minutes; the user cannot use the Mac.
- The run is non-deterministic: Claude improvises a toolkit install, may hit network blocks, may
  refuse audio; there is no contract. Each run burns a large slice of the usage window.
- Audio is uploaded to Anthropic's cloud sandbox: "stays on your Mac" no longer holds; claude.ai
  per-file upload limits bite on long calls.
- Anthropic's consumer terms prohibit automated access to the apps; a third-party app scripting the
  desktop app on a user's subscription risks account flags. Rules it out for anything shared publicly.

### 6.2 MCP connector — the supported way (recommended)

Eko ships a tiny MCP server inside the bundle (Swift, no deps, JSON-RPC over stdio, e.g.
`Eko.app/Contents/MacOS/eko-mcp`) exposing three tools: list recent recordings, get the transcript of
one, save a summary next to its audio. The user types "summarise my last call" in Claude; Claude calls
the tools, writes the summary with the prompt shipped in the tool description, and saves it through
the save tool. No window scripting, no clipboard, no copy-back, follow-ups in a normal chat. One-time
entry in Claude's connector settings (Eko can write it) or a one-click extension bundle. Claude Cowork
can call the same connector on a schedule for fully automatic runs. Requires the local transcript
(text, a few hundred KB) instead of the 30–60 MB recording.

### 6.3 Clipboard hand-off — zero-code stopgap

Menu item "Summarize in Claude": put prompt + transcript on the clipboard and open a new chat. One
paste, one copy of the answer. Most of the benefit, nothing fragile.

### 6.4 What the user observed on 2026-11-01

Attaching an `.m4a` to the Claude desktop app and asking for a summary worked well. Claude installed
sherpa-onnx in its cloud workspace, downloaded Whisper "small" in ONNX form from the k2-fsa GitHub
releases (Hugging Face was blocked), converted the audio to 16 kHz mono, split it into fixed 25-second
pieces and transcribed on CPU, then summarised. No OpenAI API was used, but the audio did leave the
Mac. Quality limits (small model, mid-word cuts) are sandbox artefacts, avoidable with 3.1.

| Route | Reliability | Privacy | Permissions | Terms | Effort |
|---|---|---|---|---|---|
| Script the Claude window | Low | Audio uploaded | Accessibility, Automation | Likely violation | 2–3 days + constant upkeep |
| MCP connector + local transcript | High | Transcript text only | None beyond Eko's own | Supported | 2 days + transcription layer |
| Clipboard hand-off | High, manual | Transcript text only | None | Fine | Half a day |

## 7. User profiles the options combine into

1. **Private and free.** Apple Speech (or Whisper) on-device, "You/Others" labels, Markdown transcript.
   Summary only via Foundation Models on macOS 26 or Ollama. Nothing leaves the Mac.
2. **Best notes, own key (recommended default).** On-device transcript, Claude API for the summary.
   Cents per meeting; transcript text goes to Anthropic, audio never does.
3. **Best notes, subscription.** On-device transcript, Claude Code or the desktop app via MCP.
   $0 marginal; consumer-terms caveat.
4. **Best transcript, cloud all the way.** Cloud STT with diarisation + Claude; names on every speaker;
   audio leaves the machine; per-hour cost.

## 8. Preferences the UI should expose

- Trigger: Off / Ask after each recording / Automatic on stop.
- Transcription engine: Apple on-device / Whisper (model picker, download state).
- Summariser: Transcript only / Claude API / Claude Code / Ollama / Apple on-device, each with its
  own small settings.
- Template: Standard (TL;DR, decisions, action items with owners, open questions, follow-ups) or a
  custom prompt file the user edits.
- Destination: Markdown next to the recording + JSON sidecar; optional clipboard, Apple Notes,
  Obsidian folder.
- Cloud features off by default; the menu states plainly what leaves the Mac. Consent duties toward
  third parties get stronger once their words are sent to a service.

## 9. Recommended build order

1. Transcription: Apple Speech, dual-stream labels, Markdown + JSON output. Valuable alone, no cloud,
   no dependency. ~2 days.
2. Whisper engine via vendored whisper.cpp, model download manager (sha256, resume), opt-in. ~3–5 days
   for the whole transcription layer including 1.
3. Hand-offs that need no LLM code in Eko: clipboard "Summarize in Claude" (half a day); `call-notes`
   skill + "Discuss Last Call in Claude Code" (half a day).
4. Claude API summariser: Keychain key, URLSession streaming, structured output to Markdown. ~1 day.
5. MCP connector for the desktop app. ~2 days.
6. Local options behind the same Summarizer protocol: Ollama, macOS 26 Foundation Models. ~1 day each.
7. Polish: templates, destinations, "Summarize Last Recording" for old files, re-summarise with a
   different template, headless Claude Code backend.

## 10. Open decisions

1. Accept one vendored C library (whisper.cpp), or stay with Apple Speech only.
2. Default Whisper model: large-v3-turbo quantised (~570 MB) or small (~490 MB, faster).
3. Transcribe automatically on every stop, or only on request from the menu.
4. Summariser to build first: Claude API with own key (recommended) or local-only.
5. Trigger default for the summary: ask after each recording (recommended) or fully automatic.
6. Whether macOS 26-only features (SpeechAnalyzer, Foundation Models) are worth building now, given
   the app supports macOS 14.2.
7. Whether to add Claude Code / MCP connector routes as opt-in backends in phase two.
