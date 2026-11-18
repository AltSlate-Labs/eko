import AVFoundation
import Foundation

/// One recording as the Library shows it. Everything is read from the files in the recordings folder:
/// the folder is the database (PLAN-LIBRARY.md §2).
public struct RecordingItem: Identifiable, Hashable {
    public var url: URL
    public var name: String
    public var date: Date
    /// From the sidecar; nil until known for recordings without one.
    public var duration: TimeInterval?
    public var size: Int64
    public var apps: [String]
    /// You on the left channel, Others on the right (Eko 0.1.2 and later).
    public var split: Bool
    public var hasTranscript: Bool
    public var hasSummary: Bool
    public var hasChat: Bool
    /// The call's title from its summary, when the summary has one.
    public var summaryTitle: String? = nil
    /// Who was on the call: the user's list, else the names Gemini heard (from the summary).
    public var participants: [String] = []

    public var id: String { url.path }
    public var length: TimeInterval { duration ?? -1 }   // sort key: unknown lengths first in ascending order
    public var transcriptURL: URL { OutputFile.transcriptURL(for: url) }
    public var summaryURL: URL { OutputFile.summaryURL(for: url) }
}

/// A recording's transcript job, as shown in the Library.
public enum JobStatus: Equatable {
    case waiting(String?)    // queued, or waiting to retry after this error
    case running(String)     // e.g. "Transcribing… 1 of 2 parts"
    case failed(String)
}

public enum Library {
    public static let audioExtensions: Set<String> = ["m4a", "wav"]

    /// Lists the recordings in `folder`. With `hideUnfinished`, a file still being recorded is left out
    /// (it has the temporary name "<date> Recording" and no sidecar until it is saved).
    public static func scan(_ folder: URL, hideUnfinished: Bool = false) -> [RecordingItem] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                     options: [.skipsHiddenFiles]) else { return [] }
        let names = Set(urls.map(\.lastPathComponent))
        return urls.compactMap { url -> RecordingItem? in
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile ?? true else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            let info = RecordingInfo.read(url)
            let hasSummary = names.contains(base + "-summary.txt")
            let summary = hasSummary ? SummaryDocument.load(OutputFile.summaryURL(for: url)) : nil
            let people = names.contains(base + "-participants.txt") ? Participants.load(for: url) : nil
            if hideUnfinished, !info.hasSidecar, isUnfinishedName(base) { return nil }
            return RecordingItem(
                url: url, name: base,
                date: info.start ?? dateFromName(base) ?? values?.creationDate ?? .distantPast,
                duration: info.duration, size: Int64(values?.fileSize ?? 0), apps: info.apps, split: info.split,
                hasTranscript: names.contains(base + "-transcript.txt"),
                hasSummary: hasSummary,
                hasChat: names.contains(base + "-chat.json"),
                summaryTitle: summary?.title,
                participants: (people ?? summary?.participants ?? []).map(\.name))
        }
    }

    static func isUnfinishedName(_ base: String) -> Bool {
        base.range(of: #" Recording( \(\d+\))?$"#, options: .regularExpression) != nil
    }

    /// "2026-11-13 11-23 Chrome" → 13 Nov 2026 11:23 (local time).
    static func dateFromName(_ base: String) -> Date? {
        guard base.count >= 16 else { return nil }
        return RecordingNamer.formatter.date(from: String(base.prefix(16)))
    }

    /// Reads the length from the audio file, for recordings without a sidecar.
    public static func loadDuration(_ url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    // MARK: Files that belong to a recording

    /// The recording and the files Eko keeps next to it, those that exist; the recording first.
    public static func companions(of recording: URL) -> [URL] {
        [recording, recording.deletingPathExtension().appendingPathExtension("json"),
         OutputFile.transcriptURL(for: recording), OutputFile.summaryURL(for: recording), OutputFile.chatURL(for: recording),
         Participants.url(for: recording)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves a recording and its companions to the Trash. Never deletes: everything can be put back from the
    /// Trash. Stops at the first failure (the recording goes first, so a failure never strands its text files).
    @discardableResult
    public static func moveToTrash(_ recording: URL,
                                   using trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    throws -> [URL] {
        var moved: [URL] = []
        for url in companions(of: recording) {
            try trash(url)
            moved.append(url)
        }
        return moved
    }
}

// MARK: Filtering

public struct LibraryFilter: Equatable, Codable {
    public enum Period: String, CaseIterable, Codable {
        case all = "Any date", today = "Today", week = "Last 7 days", month = "Last 30 days"
    }

    public enum Status: String, CaseIterable, Codable {
        case any = "Any status"
        case notTranscribed = "Not transcribed", transcribed = "Transcribed"
        case notSummarised = "Not summarised", summarised = "Summarised"
        case inProgress = "In progress", failed = "Failed"
    }

    public var text = ""
    public var period = Period.all
    public var status = Status.any
    /// "" = all apps.
    public var app = ""
    public var hideShort = false

    public init() {}

    public var isActive: Bool { self != LibraryFilter() }

    /// `transcripts`: transcript text by item id, used for search when available.
    public func apply(_ items: [RecordingItem], jobs: [String: JobStatus] = [:], transcripts: [String: String] = [:],
                      minimumSeconds: Double = 30, now: Date = Date(), calendar: Calendar = .current) -> [RecordingItem] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let today = calendar.startOfDay(for: now)
        let since: Date? = switch period {
        case .all: nil
        case .today: today
        case .week: calendar.date(byAdding: .day, value: -6, to: today)
        case .month: calendar.date(byAdding: .day, value: -29, to: today)
        }
        return items.filter { item in
            if let since, item.date < since { return false }
            if !app.isEmpty, !item.apps.contains(app) { return false }
            if hideShort, let d = item.duration, d < minimumSeconds { return false }
            if !matches(status, item, jobs[item.id]) { return false }
            if !words.isEmpty {
                let haystack = ([item.name, item.summaryTitle ?? ""] + item.apps + item.participants).joined(separator: " ") + " " + (transcripts[item.id] ?? "")
                for w in words where haystack.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    return false
                }
            }
            return true
        }
    }

    private func matches(_ status: Status, _ item: RecordingItem, _ job: JobStatus?) -> Bool {
        switch status {
        case .any: return true
        case .transcribed: return item.hasTranscript
        case .notTranscribed: return !item.hasTranscript
        case .summarised: return item.hasSummary
        case .notSummarised: return !item.hasSummary
        case .inProgress:
            if case .failed = job { return false }
            return job != nil
        case .failed:
            if case .failed = job { return true }
            return false
        }
    }
}

// MARK: Timestamps in text

public enum Timestamp {
    /// `[hh:mm:ss]` or `[mm:ss]`, as Eko writes them in transcripts, summaries and chat answers.
    private static let pattern = try! NSRegularExpression(pattern: #"\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]"#)

    public struct Match: Equatable {
        public var range: NSRange
        public var seconds: TimeInterval
    }

    public static func find(in text: String) -> [Match] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let h = m.range(at: 1).location == NSNotFound ? 0 : Double(ns.substring(with: m.range(at: 1))) ?? 0
            let mm = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let s = Double(ns.substring(with: m.range(at: 3))) ?? 0
            return Match(range: m.range, seconds: h * 3600 + mm * 60 + s)
        }
    }

    /// "38:51" or "1:02:05", for lengths in the grid and player.
    public static func short(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
