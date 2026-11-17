import EkoCore
import Foundation

/// `eko notes …`: transcripts and summaries from the command line (PLAN-GEMINI.md §7.3).
enum NotesCommand {
    static let help = """
    eko notes — transcript and summary of a recording, with Google Gemini

    usage: eko notes <recording.m4a>...          transcribe + summarise (writes -transcript.txt, -summary.txt)
           eko notes --summary-only <rec>...     re-summarise from the existing transcript (no audio sent)
           eko notes --force <rec>...            overwrite existing transcript/summary
           eko notes --model <id> <rec>...       use another Gemini model for this run
           eko notes --check                     check the key and model (no audio sent)
           eko notes --set-key                   paste a key; it is checked and stored in the Keychain

    Key: GEMINI_API_KEY in the environment, else the Keychain (set with --set-key or from the Eko menu).
    Get a key: https://aistudio.google.com/api-keys → Create API key.
    Exit codes: 0 done, 1 error, 2 usage, 3 Gemini daily limit used up.
    """

    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        var options = NotesPipeline.Options(producer: "eko CLI")
        var model: String?
        var files: [URL] = []
        var check = false, setKey = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--summary-only": options.summaryOnly = true
            case "--force": options.overwrite = true
            case "--model":
                guard !args.isEmpty else { print(help); return 2 }
                model = args.removeFirst()
            case "--check": check = true
            case "--set-key": setKey = true
            case "-h", "--help": print(help); return 0
            default:
                if a.hasPrefix("-") { print(help); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL)
            }
        }
        var settings = NotesSettings.load()
        if let model { settings.transcribeModel = model; settings.summaryModel = model }

        if setKey { return await storeKey(model: settings.transcribeModel) }
        guard let key = KeyStore.load() else {
            err("No Gemini API key. Get one at https://aistudio.google.com/api-keys, then run: eko notes --set-key")
            return 1
        }
        let client = GeminiClient(key: key)
        if check {
            do {
                for m in Set([settings.transcribeModel, settings.summaryModel]).sorted() {
                    try await client.checkKey(model: m)
                    err("ok: key \(KeyStore.masked(key)) can use \(m)")
                }
                return 0
            } catch {
                err("error: \(error.localizedDescription)")
                return 1
            }
        }
        guard !files.isEmpty else { print(help); return 2 }

        let pipeline = NotesPipeline(
            speech: GeminiSpeech(client: client, model: settings.transcribeModel, thinkingLevel: settings.thinkingLevel),
            summary: GeminiSummary(client: client, model: settings.summaryModel, thinkingLevel: settings.summaryThinkingLevel),
            settings: settings)
        var status: Int32 = 0
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { err("not found: \(file.path)"); status = 1; continue }
            let started = Date()
            err("\(file.lastPathComponent):")
            do {
                let outcome = try await pipeline.run(file, options: options) { stage in
                    switch stage {
                    case .preparing: err("  preparing audio…")
                    case let .transcribing(done, total): err("  transcribing \(done)/\(total)")
                    case .summarising: err("  summarising…")
                    }
                }
                if let t = outcome.transcript { print(t.path) }
                if let s = outcome.summary { print(s.path) }
                if let e = outcome.summaryError {
                    err("  summary failed: \(e.localizedDescription)")
                    status = (e as? GeminiError).map { if case .quotaExhausted = $0 { return 3 } else { return 1 } } ?? 1
                }
                err(String(format: "  done in %.0f s · %@", Date().timeIntervalSince(started), outcome.usage.summary))
            } catch let e as GeminiError {
                err("  error: \(e.localizedDescription)")
                if case .quotaExhausted = e { return 3 }
                status = 1
            } catch {
                err("  error: \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }

    /// Reads a key without echo (from the terminal) or from stdin, checks it with Google, stores it.
    static func storeKey(model: String) async -> Int32 {
        let key: String
        if isatty(STDIN_FILENO) != 0 {
            err("Get a key at https://aistudio.google.com/api-keys (Create API key), then paste it here.")
            guard let raw = getpass("Gemini API key: ") else { return 1 }
            key = String(cString: raw)
        } else {
            key = readLine() ?? ""
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { err("No key entered."); return 1 }
        do {
            try await GeminiClient(key: KeyStore.clean(key)).checkKey(model: model)
        } catch GeminiError.network(let detail) {
            err("Couldn't reach Google to check the key (\(detail)); storing it anyway.")
        } catch {
            err("error: \(error.localizedDescription)")
            return 1
        }
        do {
            try KeyStore.save(key)
            err("Key \(KeyStore.masked(KeyStore.clean(key))) stored in the Keychain.")
            return 0
        } catch {
            err("error: \(error.localizedDescription)")
            return 1
        }
    }

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}
