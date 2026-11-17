import Foundation

/// Runs one job: recording → `-transcript.txt` → `-summary.txt`. Engine-neutral; see PLAN-GEMINI.md §4.
public final class NotesPipeline {
    public struct Options {
        /// Replace existing output files (manual runs only).
        public var overwrite = false
        /// Re-summarise from the existing transcript; no audio is sent.
        public var summaryOnly = false
        /// Producer named in the transcript header, e.g. "Eko 0.2.0".
        public var producer = "Eko"
        public init(overwrite: Bool = false, summaryOnly: Bool = false, producer: String = "Eko") {
            self.overwrite = overwrite
            self.summaryOnly = summaryOnly
            self.producer = producer
        }
    }

    public enum Progress: Equatable {
        case preparing
        case transcribing(done: Int, total: Int)
        case summarising
    }

    public struct Outcome {
        public var transcript: URL?
        public var summary: URL?
        /// The transcript was written (or already there) but the summary failed.
        public var summaryError: Error?
        public var usage = Usage()
        public var transcribed = false
    }

    public enum JobError: LocalizedError {
        case alreadyDone(String), noTranscript(String), emptyTranscript
        public var errorDescription: String? {
            switch self {
            case let .alreadyDone(name): return "\(name) already has a transcript and a summary."
            case let .noTranscript(name): return "\(name) has no transcript to summarise."
            case .emptyTranscript: return "No speech was found in the recording."
            }
        }
    }

    public let speech: SpeechEngine
    public let summary: SummaryEngine
    public var settings: NotesSettings
    public var names: NamesList
    public var template: (template: String, source: String)
    var log: (String) -> Void = { RecordingSession.dlog("notes: \($0)") }
    static let maxParallel = 3

    public init(speech: SpeechEngine, summary: SummaryEngine, settings: NotesSettings = .load(),
                names: NamesList = .load(), template: (template: String, source: String) = SummaryPrompt.loadTemplate()) {
        self.speech = speech
        self.summary = summary
        self.settings = settings
        self.names = names
        self.template = template
    }

    public func run(_ recording: URL, options: Options = Options(), progress: @escaping (Progress) -> Void = { _ in }) async throws -> Outcome {
        let started = Date()
        let info = RecordingInfo.read(recording)
        let transcriptURL = OutputFile.transcriptURL(for: recording)
        let summaryURL = OutputFile.summaryURL(for: recording)
        let fm = FileManager.default
        var outcome = Outcome()
        let segments: [Segment]
        var duration: TimeInterval = 0

        let haveTranscript = fm.fileExists(atPath: transcriptURL.path)
        if options.summaryOnly || (haveTranscript && !options.overwrite) {
            guard haveTranscript else { throw JobError.noTranscript(recording.lastPathComponent) }
            if !options.overwrite, fm.fileExists(atPath: summaryURL.path) { throw JobError.alreadyDone(recording.lastPathComponent) }
            segments = TranscriptText.parseFile(try String(contentsOf: transcriptURL, encoding: .utf8))
            duration = segments.last?.start ?? 0
            log("\(recording.lastPathComponent): summarising the existing transcript (\(segments.count) lines)")
        } else {
            progress(.preparing)
            let made = try await transcribe(recording, info: info, producer: options.producer, progress: progress)
            segments = made.segments
            duration = made.duration
            outcome.usage = made.usage
            try OutputFile.write(made.text, to: transcriptURL, overwrite: options.overwrite)
            outcome.transcribed = true
            log(String(format: "%@: transcript written, %d lines, %.0f s so far", recording.lastPathComponent, segments.count, Date().timeIntervalSince(started)))
        }
        outcome.transcript = transcriptURL
        guard !segments.isEmpty else { throw JobError.emptyTranscript }

        progress(.summarising)
        do {
            let values = SummaryPrompt.Values(title: recording.deletingPathExtension().lastPathComponent, date: info.dateText,
                                              duration: duration, labelled: segments.contains { $0.speaker != .unlabelled },
                                              names: names, transcript: TranscriptText.linesForPrompt(segments))
            let answer = try await summary.summarise(prompt: SummaryPrompt.render(template: template.template, values))
            outcome.usage = outcome.usage + answer.usage
            let check = SummaryPrompt.checkTimestamps(answer.text, against: segments)
            let text = SummaryPrompt.renderFile(recording: recording.lastPathComponent, engine: summary.info.label,
                                                promptSource: template.source, body: answer.text, check: check)
            try OutputFile.write(text, to: summaryURL, overwrite: options.overwrite)
            outcome.summary = summaryURL
        } catch {
            if error is CancellationError { throw error }
            outcome.summaryError = error
            log("\(recording.lastPathComponent): summary failed: \(error.localizedDescription)")
        }
        log(String(format: "%@: done in %.0f s; %@", recording.lastPathComponent, Date().timeIntervalSince(started), outcome.usage.summary))
        return outcome
    }

    // MARK: Transcription

    struct Made {
        var text: String
        var segments: [Segment]
        var duration: TimeInterval
        var usage: Usage
    }

    func transcribe(_ recording: URL, info: RecordingInfo, producer: String, progress: @escaping (Progress) -> Void) async throws -> Made {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eko-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let channels = try AudioPrep.channelCount(of: recording)
        let sides = AudioPrep.sides(for: info, channelCount: channels)
        let prepared = try await Task.detached(priority: .utility) {
            try AudioPrep.prepare(recording, sides: sides, chunkSeconds: self.settings.chunkMinutes * 60, into: dir)
        }.value
        let parts = prepared.parts
        log("\(recording.lastPathComponent): \(parts.count) part(s), \(Int(prepared.duration)) s; silent: \(prepared.silent.map { $0 == .unlabelled ? "mix" : $0.rawValue })")

        var results = [SpeechResult?](repeating: nil, count: parts.count)
        var done = 0
        progress(.transcribing(done: 0, total: parts.count))
        try await withThrowingTaskGroup(of: (Int, SpeechResult).self) { group in
            var next = 0
            func launch() {
                guard next < parts.count else { return }
                let i = next
                next += 1
                group.addTask { (i, try await self.transcribePart(parts[i], dir: dir)) }
            }
            for _ in 0..<min(Self.maxParallel, parts.count) { launch() }
            while let (i, result) = try await group.next() {
                results[i] = result
                done += 1
                progress(.transcribing(done: done, total: parts.count))
                launch()
            }
        }

        var usage = Usage()
        var outOfRange = 0, repeats = 0
        var worstNonLatin = 0.0
        var lists: [[Segment]] = [[], []]
        for (part, result) in zip(parts, results.map { $0! }) {
            usage = usage + result.usage
            worstNonLatin = max(worstNonLatin, result.nonLatin)
            let cleaned = TranscriptText.clean(result.segments, duration: part.duration)
            outOfRange += cleaned.outOfRange
            repeats += cleaned.repeatsCollapsed
            lists[part.speaker == .others ? 1 : 0] += TranscriptText.offset(cleaned.segments, by: part.offset)
        }
        var merged = TranscriptText.merge(lists)
        var echoes = 0
        if sides.count == 2 { (merged, echoes) = TranscriptText.removeBleed(merged) }

        var checks = [worstNonLatin <= 0.01 ? "script OK" : String(format: "⚠︎ %.1f%% of letters not in Roman script", worstNonLatin * 100)]
        if outOfRange > 0 { checks.append("\(outOfRange) lines past the end removed") }
        if repeats > 0 { checks.append("\(repeats) repeated lines collapsed") }
        if echoes > 0 { checks.append("\(echoes) echo lines removed") }
        for s in prepared.silent where s != .unlabelled { checks.append("\(s.rawValue) side silent, not sent") }
        let header = TranscriptText.Header(
            recording: recording.lastPathComponent, date: info.dateText, duration: prepared.duration, apps: info.apps,
            engine: "\(speech.info.label) (\(speech.info.location)) · \(producer)",
            labelled: sides.count == 2, checks: checks)
        return Made(text: TranscriptText.render(header: header, segments: merged), segments: merged,
                    duration: prepared.duration, usage: usage)
    }

    /// One part; if the answer was cut off (too long), split the part at a quiet moment and try the halves once.
    func transcribePart(_ part: AudioPart, dir: URL) async throws -> SpeechResult {
        do {
            return try await speech.transcribe(part, names: names)
        } catch GeminiError.maxTokens where part.duration > 120 {
            log("\(part.file.lastPathComponent): answer cut off; splitting into halves")
            let halves = try AudioPrep.prepare(part.file, sides: [.channel(0, part.speaker)], chunkSeconds: part.duration,
                                               into: dir, prefix: part.file.deletingPathExtension().lastPathComponent + "-half", halve: true)
            var combined = SpeechResult(segments: [], usage: Usage(), nonLatin: 0)
            for half in halves.parts {
                let r = try await speech.transcribe(half, names: names)
                combined.segments += TranscriptText.offset(TranscriptText.clean(r.segments, duration: half.duration).segments, by: half.offset)
                combined.usage = combined.usage + r.usage
                combined.nonLatin = max(combined.nonLatin, r.nonLatin)
            }
            return combined
        }
    }
}
