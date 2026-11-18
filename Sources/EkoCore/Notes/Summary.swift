import Foundation

/// The summary prompt (built-in default or the user's summary-prompt.txt), its placeholders, and the checks
/// and file format around the model's answer.
public enum SummaryPrompt {
    public static let defaultTemplate = """
    You are writing notes for a recorded call. Use only what the transcript says. Never guess.

    Call: {{title}}
    Date: {{date}}    Duration: {{duration}}
    Speakers: {{speakers}}

    Write the notes in exactly this format, as plain text without Markdown:

    TITLE: <what the call was about, in at most 8 words; no date, app name or "Call with">

    PARTICIPANTS
    - <name> (<role or team, only if said in the call>) [hh:mm:ss]

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
    - Participants: only people taking part in the call, known from being addressed by name, introducing
      themselves or answering to their name, with the time where that happens. Leave out You and people who
      are only talked about. If the speakers line lists the people on the call, use those names.
    - If a section has nothing, write "None stated."
    - Write in English, including dates (e.g. "the 17th", not "17 tareekh"), even where the call is in Hindi.
      Keep names, and Hindi terms with no good English equivalent, as they were spoken, in Roman script,
      never Devanagari.
    - Spell names and terms as in this list: {{names}}

    TRANSCRIPT
    {{transcript}}
    """

    public struct Values {
        public var title: String
        public var date: String
        public var duration: TimeInterval
        public var labelled: Bool
        public var names: NamesList
        public var transcript: String
        /// The user's list of who was on the call, if they made one.
        public var participants: [Participant]?
        public init(title: String, date: String, duration: TimeInterval, labelled: Bool, names: NamesList, transcript: String,
                    participants: [Participant]? = nil) {
            self.participants = participants
            self.title = title
            self.date = date
            self.duration = duration
            self.labelled = labelled
            self.names = names
            self.transcript = transcript
        }
    }

    public static func speakersLine(labelled: Bool, me: String?, participants: [Participant]? = nil) -> String {
        let people = Participants.promptLine(participants)
        guard labelled else { return "Speakers are not labelled." + people }
        if let me { return "You = \(me), who recorded the call. Others = everyone else (not told apart)." + people }
        return "You = the person who recorded the call. Others = everyone else (not told apart)." + people
    }

    public static func render(template: String, _ v: Values) -> String {
        let names = v.names.terms.isEmpty ? "(none given)" : v.names.terms.joined(separator: ", ")
        // The transcript goes in last, so text inside it that looks like a placeholder is never replaced.
        return template
            .replacingOccurrences(of: "{{title}}", with: v.title)
            .replacingOccurrences(of: "{{date}}", with: v.date)
            .replacingOccurrences(of: "{{duration}}", with: TranscriptText.clock(v.duration))
            .replacingOccurrences(of: "{{speakers}}", with: speakersLine(labelled: v.labelled, me: v.names.me, participants: v.participants))
            .replacingOccurrences(of: "{{names}}", with: names)
            .replacingOccurrences(of: "{{transcript}}", with: v.transcript)
    }

    /// The user's prompt file if present and non-empty, else the built-in default.
    public static func loadTemplate(from url: URL = NotesSettings.summaryPromptFile) -> (template: String, source: String) {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (text.contains("{{transcript}}") ? text : text + "\n\nTRANSCRIPT\n{{transcript}}\n", url.lastPathComponent)
        }
        return (defaultTemplate, "built-in default")
    }

    // MARK: Checks and file

    public struct Check: Equatable {
        public var cited: Int
        public var matched: Int
        public var line: String {
            cited == 0 ? "No timestamps cited." : "\(matched) of \(cited) cited timestamps match a transcript line."
        }
    }

    private static let cite = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2}):(\d{2})\]"#)

    /// Every `[hh:mm:ss]` in the summary must be within `tolerance` of a transcript line's start.
    public static func checkTimestamps(_ summary: String, against segments: [Segment], tolerance: TimeInterval = 10) -> Check {
        let ns = summary as NSString
        let starts = segments.map(\.start)
        var check = Check(cited: 0, matched: 0)
        for m in cite.matches(in: summary, range: NSRange(location: 0, length: ns.length)) {
            let t = (1...3).map { Double(ns.substring(with: m.range(at: $0))) ?? 0 }
            let seconds = t[0] * 3600 + t[1] * 60 + t[2]
            check.cited += 1
            if starts.contains(where: { abs($0 - seconds) <= tolerance }) { check.matched += 1 }
        }
        return check
    }

    public static func renderFile(recording: String, engine: String, promptSource: String, body: String, check: Check) -> String {
        [
            "Eko call summary (made by \(engine); check it against the transcript)",
            "Recording: \(recording) · Prompt: \(promptSource)",
            TranscriptText.rule,
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            TranscriptText.rule,
            "Checks: \(check.line)",
        ].joined(separator: "\n") + "\n"
    }
}
