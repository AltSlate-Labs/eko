import AppKit
import EkoCore
import Foundation

/// Transcripts and summaries in the app: runs the persisted queue one job at a time, shows progress and
/// problems in the menu, and owns the Gemini key dialog (PLAN-GEMINI.md §5.1, §7).
@MainActor
final class NotesModel: ObservableObject {
    static weak var current: NotesModel?
    static let keyPage = URL(string: "https://aistudio.google.com/api-keys")!

    /// One line for the menu: what is running, or what went wrong. Nil when all is well (success is silent).
    @Published private(set) var statusLine: String?
    @Published private(set) var isRunning = false
    @Published private(set) var maskedKey: String?
    @Published private(set) var failedCount = 0
    /// Each queued recording's state, by path, for the Library.
    @Published private(set) var jobStates: [String: JobStatus] = [:]
    @Published var auto: Bool {
        didSet { NotesSettings.setAuto(auto) }
    }

    private let queue = NotesQueue()
    private var timer: Timer?
    private var running: (path: String, task: Task<Void, Never>)?
    private var stageText = ""
    /// Set when Google rejects the key: nothing runs until a new key is saved.
    private var keyProblem = false
    private var keyDialogOpen = false
    /// The key, read from the Keychain at most once per launch and only when needed: every read can make macOS
    /// ask for permission (always after an update, since each self-signed build is a new app to the Keychain).
    private var cachedKey: String?
    /// The user refused (or dismissed) the Keychain prompt: don't ask again until they click Retry or save a key.
    @Published private(set) var keychainRefused = false

    init() {
        auto = NotesSettings.load().auto
        let stored = KeyStore.summary()   // attributes only: never prompts
        maskedKey = stored.stored ? (stored.hint ?? "") : nil   // "" = saved by an older version, no hint
        failedCount = queue.failedJobs.count
        Self.current = self
        Self.sweepTemporaryFolders()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.kick() }
        refreshStatus()
    }

    // MARK: Triggers

    /// Called when a recording has been saved (file closed, renamed, sidecar written).
    func recordingSaved(_ url: URL, duration: TimeInterval) {
        guard auto, duration >= NotesSettings.load().minimumSeconds else { return }
        queue.enqueue(url)
        if maskedKey == nil {
            // Ask once; the call stays queued and is transcribed as soon as a key is saved.
            if !NotesSettings.defaults.bool(forKey: "notes.keyPromptShown") {
                NotesSettings.defaults.set(true, forKey: "notes.keyPromptShown")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showKeyDialog() }
            }
            refreshStatus()
            return
        }
        kick()
    }

    /// Transcribes (and then summarises) a recording; asks before replacing an existing transcript.
    func transcribe(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        var overwrite = false
        if FileManager.default.fileExists(atPath: OutputFile.transcriptURL(for: url).path) {
            guard confirm("Transcribe \(name) again?", "Its transcript and summary will be replaced. Any edits you made to them will be lost.",
                          "Replace") else { return }
            overwrite = true
        }
        queue.enqueue(url, overwrite: overwrite)
        afterEnqueue()
    }

    /// Several recordings at once (Library): asks once, then queues them all.
    func transcribe(_ urls: [URL]) {
        guard urls.count > 1 else { if let url = urls.first { transcribe(url) }; return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: OutputFile.transcriptURL(for: $0).path) }
        if !existing.isEmpty {
            guard confirm("Transcribe \(urls.count) recordings?",
                          "\(existing.count) of them already have a transcript, which will be replaced with its summary. Any edits will be lost.",
                          "Transcribe") else { return }
        }
        for url in urls { queue.enqueue(url, overwrite: existing.contains(url)) }
        afterEnqueue()
    }

    /// A new summary from the existing transcript (no audio is sent); asks before replacing a summary.
    func summarise(_ url: URL) {
        guard FileManager.default.fileExists(atPath: OutputFile.transcriptURL(for: url).path) else { return }
        if FileManager.default.fileExists(atPath: OutputFile.summaryURL(for: url).path) {
            guard confirm("Summarise \(url.deletingPathExtension().lastPathComponent) again?",
                          "The summary will be replaced. Any edits you made to it will be lost.", "Replace") else { return }
        }
        queue.enqueue(url, overwrite: true, summaryOnly: true)
        afterEnqueue()
    }

    /// Stops and removes a recording's job (Cancel in the Library, or the recording is moved to the Trash).
    func cancel(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let running, running.path == path { running.task.cancel() }
        queue.complete(path)
        refreshStatus()
    }

    private func afterEnqueue() {
        if maskedKey == nil { showKeyDialog() }
        kick()
        refreshStatus()
    }

    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func retry() {
        keyProblem = false
        keychainRefused = false
        queue.retryAll()
        kick()
    }

    /// The Gemini key for a request (transcripts, chat), or nil if none is set or the Keychain read was refused.
    func apiKey() -> String? {
        if let cachedKey { return cachedKey }
        guard maskedKey != nil, !keychainRefused else { return nil }
        if let key = KeyStore.loadFromKeychain() {
            cachedKey = key
            return key
        }
        keychainRefused = true
        RecordingSession.dlog("notes: the Gemini key could not be read from the Keychain (access refused?)")
        refreshStatus()
        return nil
    }

    // MARK: Running

    private func kick() {
        failedCount = queue.failedJobs.count
        guard !isRunning, !keyProblem, maskedKey != nil else { refreshStatus(); return }
        if let recorder = RecorderModel.current, recorder.isRecording, recorder.elapsed < 10 { return }   // let capture settle
        guard let job = queue.nextDue() else { refreshStatus(); return }
        guard let key = apiKey() else { refreshStatus(); return }   // only now: there is work to do
        run(job, key: key)
    }

    private func run(_ job: NotesJob, key: String) {
        isRunning = true
        let summaryOnly = job.summaryOnly ?? false
        statusLine = (summaryOnly ? "Summarising" : "Transcribing") + " \(job.name)…"
        stageText = summaryOnly ? "Summarising…" : "Transcribing…"
        let settings = NotesSettings.load()
        let client = GeminiClient(key: key)
        let pipeline = NotesPipeline(
            speech: GeminiSpeech(client: client, model: settings.transcribeModel, thinkingLevel: settings.thinkingLevel),
            summary: GeminiSummary(client: client, model: settings.summaryModel, thinkingLevel: settings.summaryThinkingLevel),
            settings: settings)
        let options = NotesPipeline.Options(overwrite: job.overwrite ?? false, summaryOnly: summaryOnly,
                                            producer: "Eko \(Updater.currentVersion)")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Transcribing a call")
        let task = Task { @MainActor in
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                running = nil
                isRunning = false
                kick()
            }
            do {
                let outcome = try await pipeline.run(job.url, options: options) { [weak self] stage in
                    Task { @MainActor in self?.show(stage, job) }
                }
                if let error = outcome.summaryError {
                    // The transcript is kept; the retry only makes the summary. After a "transcribe again" it must
                    // also replace the old summary, so that it matches the new transcript.
                    if job.overwrite == true { queue.redoSummaryOnly(job.path) }
                    handle(error, job)
                } else {
                    queue.complete(job.path)
                }
            } catch is CancellationError {
                RecordingSession.dlog("notes: \(job.url.lastPathComponent): cancelled")
                queue.complete(job.path)
            } catch {
                handle(error, job)
            }
        }
        running = (job.path, task)
        refreshJobStates()
    }

    private func show(_ stage: NotesPipeline.Progress, _ job: NotesJob) {
        guard isRunning else { return }
        switch stage {
        case .preparing:
            statusLine = "Transcribing \(job.name)… (preparing audio)"
            stageText = "Preparing audio…"
        case let .transcribing(done, total):
            statusLine = "Transcribing \(job.name)… (\(done) of \(total) parts)"
            stageText = total > 1 ? "Transcribing… \(done) of \(total) parts" : "Transcribing…"
        case .summarising:
            statusLine = "Summarising \(job.name)…"
            stageText = "Summarising…"
        }
        refreshJobStates()
    }

    private func refreshJobStates() {
        var states: [String: JobStatus] = [:]
        for job in queue.jobs {
            states[job.path] = job.failed ? .failed(job.lastError ?? "Unknown error") : .waiting(job.lastError)
        }
        if let running { states[running.path] = .running(stageText) }
        if states != jobStates { jobStates = states }
    }

    private func handle(_ error: Error, _ job: NotesJob) {
        let text = error.localizedDescription
        RecordingSession.dlog("notes: \(job.url.lastPathComponent): \(text)")
        switch error {
        case let GeminiError.quotaExhausted(resetAt):
            queue.pause(until: resetAt, error: text)
        case GeminiError.keyRejected:
            keyProblem = true
            queue.retryLater(job.path, error: text)
        case let e as GeminiError where e.isTransient:
            queue.retryLater(job.path, error: text)
        case NotesPipeline.JobError.alreadyDone, OutputFile.WriteError.exists:
            queue.complete(job.path)   // nothing to do; existing files are never replaced automatically
        default:
            queue.fail(job.path, error: text)
        }
        failedCount = queue.failedJobs.count
    }

    private func refreshStatus() {
        refreshJobStates()
        guard !isRunning else { return }
        if keyProblem {
            statusLine = "Google did not accept the Gemini key. Replace it in Settings."
        } else if keychainRefused {
            statusLine = "Eko couldn't read the Gemini key from the Keychain. Click Retry and choose Always Allow."
        } else if let until = queue.pausedUntil, until > Date() {
            statusLine = GeminiError.quotaExhausted(resetAt: until).localizedDescription
        } else if let failed = queue.failedJobs.last {
            statusLine = "Transcript failed for \(failed.name): \(failed.lastError ?? "unknown error")"
        } else if maskedKey == nil, !queue.pending.isEmpty {
            statusLine = "\(queue.pending.count) call(s) waiting for a Gemini key (Transcripts › Set Gemini Key…)"
        } else if let waiting = queue.pending.first(where: { $0.lastError != nil }) {
            statusLine = "Transcript of \(waiting.name) will be retried: \(waiting.lastError!)"
        } else {
            statusLine = nil
        }
    }

    /// Leftover audio pieces from a run interrupted by a quit or crash.
    private static func sweepTemporaryFolders() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("eko-notes-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    // MARK: Key

    func showKeyDialog(message: String? = nil, prefill: String = "") {
        guard !keyDialogOpen else { return }
        keyDialogOpen = true
        defer { keyDialogOpen = false }
        let alert = NSAlert()
        alert.messageText = "Get transcripts and summaries of your calls"
        alert.informativeText = (message.map { "\($0)\n\n" } ?? "") + """
        Optional: recording works without this. Eko uses Google Gemini with your own free API key:
        1. Click Get a Key (opens aistudio.google.com) and sign in with a Google account.
        2. Click Create API key, then copy the key.
        3. Paste it below and click Save. If macOS asks for Keychain access, click Always Allow.
        Each call's audio is sent to Gemini. Free keys allow about 3 hour-long calls a day.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste your Gemini API key"
        field.stringValue = prefill
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Get a Key")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        var response = alert.runModal()
        while response == .alertSecondButtonReturn {   // Get a Key: open the page, keep the dialog
            NSWorkspace.shared.open(Self.keyPage)
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        let key = KeyStore.clean(field.stringValue)
        guard !key.isEmpty else { return }
        Task { @MainActor in await self.validateAndSave(key) }
    }

    enum KeyResult: Equatable {
        case saved, savedUnchecked, rejected, failed(String)
        var message: String {
            switch self {
            case .saved: return "Key saved and working."
            case .savedUnchecked: return "Key saved. Couldn't reach Google to check it; it will be checked on the next call."
            case .rejected: return "Google did not accept this key. Copy it again from AI Studio."
            case let .failed(detail): return "The key was not saved: \(detail)"
            }
        }
    }

    /// Checks a key with Google (no tokens used) and saves it to the Keychain if it works or can't be checked.
    func checkAndSave(_ key: String) async -> KeyResult {
        let key = KeyStore.clean(key)
        guard !key.isEmpty else { return .failed("the key is empty") }
        do {
            try await GeminiClient(key: key).checkKey(model: NotesSettings.load().transcribeModel)
            try save(key)
            return .saved
        } catch GeminiError.network {
            do { try save(key); return .savedUnchecked } catch { return .failed(error.localizedDescription) }
        } catch GeminiError.keyRejected {
            return .rejected
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func validateAndSave(_ key: String) async {
        statusLine = "Checking the Gemini key…"
        let result = await checkAndSave(key)
        refreshStatus()
        switch result {
        case .saved:
            info("Key saved", auto ? "New calls will be transcribed automatically." : "Use Transcripts › Transcribe Last Recording.")
        case .savedUnchecked: info("Key saved", result.message)
        case .rejected: showKeyDialog(message: result.message, prefill: key)
        case .failed: info("The key was not saved", result.message)
        }
    }

    private func save(_ key: String) throws {
        try KeyStore.save(key)
        maskedKey = KeyStore.masked(key)
        cachedKey = key
        keychainRefused = false
        keyProblem = false
        if queue.pausedUntil == nil { queue.retryAll() }
        kick()
    }

    func removeKey() {
        KeyStore.remove()
        maskedKey = nil
        cachedKey = nil
        refreshStatus()
    }

    func openKeyPage() { NSWorkspace.shared.open(Self.keyPage) }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
