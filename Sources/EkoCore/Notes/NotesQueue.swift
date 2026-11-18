import Foundation

public struct NotesJob: Codable, Equatable {
    public var path: String
    public var addedAt: Date
    public var attempts = 0
    public var nextTryAt: Date
    public var lastError: String?
    /// Gave up after the retry schedule, or hit an error retrying cannot fix; waits for the user's Retry.
    public var failed = false
    /// Manual "transcribe again": replace existing transcript and summary.
    public var overwrite: Bool?
    /// "Summarise again": only the summary is made, from the existing transcript (no audio sent).
    public var summaryOnly: Bool?

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Recordings waiting for a transcript, persisted in notes-queue.json so a quit or crash loses nothing.
/// Not thread-safe: the app uses it from the main actor only.
public final class NotesQueue {
    public private(set) var jobs: [NotesJob] = []
    /// Set when the daily quota is used up: nothing runs before this time.
    public private(set) var pausedUntil: Date?
    /// After a failed run: 15 min, 30 min, then wait for the next quota reset (nil) and try twice more, then stop
    /// until the user's Retry. At most three runs a day, so an outage cannot use up the daily quota.
    public static let retryDelays: [TimeInterval?] = [900, 1800, nil, 900, 1800]
    private let url: URL

    private struct Stored: Codable {
        var jobs: [NotesJob]
        var pausedUntil: Date?
    }

    public init(url: URL = NotesSettings.queueFile) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let stored = try? decoder.decode(Stored.self, from: data) {
                jobs = stored.jobs
                pausedUntil = stored.pausedUntil
            }
        }
    }

    public var pending: [NotesJob] { jobs.filter { !$0.failed } }
    public var failedJobs: [NotesJob] { jobs.filter(\.failed) }

    public func enqueue(_ recording: URL, overwrite: Bool = false, summaryOnly: Bool = false, now: Date = Date()) {
        let path = recording.standardizedFileURL.path
        if let i = jobs.firstIndex(where: { $0.path == path }) {
            jobs[i].failed = false
            jobs[i].attempts = 0
            jobs[i].nextTryAt = now
            if summaryOnly {
                // A queued "transcribe again" makes a new summary anyway; otherwise this becomes a summary job.
                if jobs[i].overwrite != true || jobs[i].summaryOnly == true {
                    jobs[i].summaryOnly = true
                    if overwrite { jobs[i].overwrite = true }
                }
            } else {
                jobs[i].summaryOnly = nil
                if overwrite { jobs[i].overwrite = true }
            }
        } else {
            jobs.append(NotesJob(path: path, addedAt: now, nextTryAt: now, overwrite: overwrite ? true : nil,
                                 summaryOnly: summaryOnly ? true : nil))
        }
        save()
    }

    /// The transcript was (re)made but the summary failed: the retry must make only the summary, and must replace
    /// an old one (left from before a "transcribe again"), so it matches the new transcript.
    public func redoSummaryOnly(_ path: String) {
        guard let i = jobs.firstIndex(where: { $0.path == path }) else { return }
        jobs[i].summaryOnly = true
        jobs[i].overwrite = true
        save()
    }

    /// The next job that may run now. Jobs whose recording no longer exists are dropped.
    public func nextDue(now: Date = Date()) -> NotesJob? {
        if let pausedUntil {
            if pausedUntil > now { return nil }
            self.pausedUntil = nil
            save()
        }
        let missing = jobs.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            for job in missing { RecordingSession.dlog("notes: dropping job, recording is gone: \(job.url.lastPathComponent)") }
            jobs.removeAll { missing.contains($0) }
            save()
        }
        return jobs.filter { !$0.failed && $0.nextTryAt <= now }.min { $0.nextTryAt < $1.nextTryAt }
    }

    /// When the next waiting job becomes due (for a timer), if any.
    public func nextWake(now: Date = Date()) -> Date? {
        let next = pending.map(\.nextTryAt).min()
        guard let next else { return nil }
        if let pausedUntil, pausedUntil > now { return max(pausedUntil, next) }
        return next
    }

    /// After a run that replaced files, later retries of the same job must not replace them again.
    public func clearOverwrite(_ path: String) {
        guard let i = jobs.firstIndex(where: { $0.path == path }), jobs[i].overwrite != nil else { return }
        jobs[i].overwrite = nil
        save()
    }

    public func complete(_ path: String) {
        jobs.removeAll { $0.path == path }
        save()
    }

    /// Schedules another try after a transient error. Returns false when the schedule is used up (job failed).
    @discardableResult
    public func retryLater(_ path: String, error: String, now: Date = Date()) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.path == path }) else { return false }
        jobs[i].lastError = error
        if jobs[i].attempts < Self.retryDelays.count {
            jobs[i].nextTryAt = Self.retryDelays[jobs[i].attempts].map { now.addingTimeInterval($0) }
                ?? GeminiClient.nextQuotaReset(after: now).addingTimeInterval(120)
            jobs[i].attempts += 1
            save()
            return true
        }
        jobs[i].failed = true
        save()
        return false
    }

    /// An error retrying cannot fix by itself (bad key, unreadable file…): wait for the user.
    public func fail(_ path: String, error: String) {
        guard let i = jobs.firstIndex(where: { $0.path == path }) else { return }
        jobs[i].lastError = error
        jobs[i].failed = true
        save()
    }

    /// Daily quota used up: hold every job until the reset; the attempt does not count against the job.
    public func pause(until date: Date, error: String) {
        pausedUntil = date
        for i in jobs.indices where !jobs[i].failed { jobs[i].lastError = error }
        save()
    }

    public func resume() {
        pausedUntil = nil
        save()
    }

    /// The user's Retry: failed jobs (and any pause) start over.
    public func retryAll(now: Date = Date()) {
        pausedUntil = nil
        for i in jobs.indices {
            jobs[i].failed = false
            jobs[i].attempts = 0
            jobs[i].nextTryAt = now
        }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(jobs: jobs, pausedUntil: pausedUntil)),
              let text = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? OutputFile.write(text, to: url, overwrite: true)
    }
}
