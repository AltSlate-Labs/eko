import Foundation

/// A summary file split into its sections for display (PLAN-LIBRARY.md §5.5). Reads what `SummaryPrompt.renderFile`
/// writes; a summary made with a custom prompt that has other headings still shows, as one plain section.
public struct SummaryDocument: Equatable {
    public struct Section: Equatable {
        public var title: String
        /// Bullets without their "- ", or paragraph lines for a section that has no bullets.
        public var items: [String]
        public var isList: Bool
    }

    public struct ActionItem: Equatable {
        public var task: String
        public var owner: String?
        public var due: String?
    }

    /// A short title for the call, from the summary's `TITLE:` line (nil for older summaries and custom formats).
    public var title: String?
    /// "Gemini gemini-3.6-flash", from the first header line.
    public var producer: String?
    public var sections: [Section] = []
    /// The checks footer, e.g. "9 of 9 cited timestamps match a transcript line."
    public var check: String?
    /// The summary text without Eko's header and footer.
    public var body = ""

    public static let knownHeadings: Set<String> = ["PARTICIPANTS", "SUMMARY", "DECISIONS", "ACTION ITEMS", "OPEN QUESTIONS", "FOLLOW-UPS"]

    public static func parse(_ text: String) -> SummaryDocument {
        var doc = SummaryDocument()
        var lines = text.components(separatedBy: "\n")
        // Header: "Eko call summary (made by X; check it…)", "Recording: …", rule. Footer: rule, "Checks: …".
        if let first = lines.first, first.hasPrefix("Eko call summary"),
           let ruleIndex = lines.firstIndex(of: TranscriptText.rule) {
            if let r = first.range(of: "made by "), let end = first[r.upperBound...].firstIndex(of: ";") {
                doc.producer = String(first[r.upperBound..<end])
            }
            lines.removeSubrange(0...ruleIndex)
        }
        if let last = lines.lastIndex(of: TranscriptText.rule) {
            let footer = lines[(last + 1)...].first { $0.hasPrefix("Checks: ") }
            doc.check = footer.map { String($0.dropFirst("Checks: ".count)) }
            lines.removeSubrange(last...)
        }
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let title = Self.titleLine(lines[i].trimmingCharacters(in: .whitespaces)) {
            doc.title = title   // shown as the heading, not as part of the text
            lines.remove(at: i)
        }
        doc.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var current: Section?
        func close() {
            if let s = current, !s.items.isEmpty || !s.title.isEmpty { doc.sections.append(s) }
            current = nil
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: ")).uppercased()
            if knownHeadings.contains(heading) {
                close()
                current = Section(title: heading.capitalized.replacingOccurrences(of: "Follow-Ups", with: "Follow-ups"),
                                  items: [], isList: false)
                continue
            }
            if current == nil { current = Section(title: "", items: [], isList: false) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                current!.items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                current!.isList = true
            } else if current!.isList, !current!.items.isEmpty {
                current!.items[current!.items.count - 1] += " " + line   // wrapped bullet
            } else {
                current!.items.append(line)
            }
        }
        close()
        return doc
    }

    /// Gemini's suggestion of who was on the call (the PARTICIPANTS section).
    public var participants: [Participant] {
        let items = sections.first { $0.title == "Participants" }?.items ?? []
        var seen = Set<String>()
        return items.compactMap(Participant.init(line:)).filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// True when the summary has Eko's sections (otherwise it is shown as plain text).
    public var isStructured: Bool { sections.contains { Self.knownHeadings.contains($0.title.uppercased()) } }

    /// "Review the deck | Owner: You | Due: the 17th [00:12:03]" → task (with its timestamp), owner, due.
    public static func actionItem(_ line: String) -> ActionItem {
        let parts = line.components(separatedBy: " | ")
        var item = ActionItem(task: parts[0].trimmingCharacters(in: .whitespaces))
        var stamp = ""
        for part in parts.dropFirst() {
            var value = part.trimmingCharacters(in: .whitespaces)
            if let m = Timestamp.find(in: value).last, NSMaxRange(m.range) == (value as NSString).length {
                stamp = (value as NSString).substring(with: m.range)
                value = (value as NSString).substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            }
            if value.lowercased().hasPrefix("owner:") { item.owner = clean(value.dropFirst(6)) }
            else if value.lowercased().hasPrefix("due:") { item.due = clean(value.dropFirst(4)) }
        }
        if !stamp.isEmpty, Timestamp.find(in: item.task).isEmpty { item.task += " " + stamp }
        return item
    }

    /// "TITLE: Pricing for the v1 launch" (also "**Title:** …") → the title, tidied and capped; nil otherwise.
    static func titleLine(_ line: String) -> String? {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
        guard bare.uppercased().hasPrefix("TITLE") else { return nil }
        var rest = bare.dropFirst(5).drop { $0 == "*" || $0 == " " }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()
        var t = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”'`. ").union(.whitespaces))
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if t.count > 90 { t = String(t.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" }
        return t.isEmpty || t.lowercased() == "none stated" ? nil : t
    }

    /// A summary file, read for the Library list (title and participants).
    public static func load(_ url: URL) -> SummaryDocument? {
        (try? String(contentsOf: url, encoding: .utf8)).map(parse)
    }

    private static func clean(_ s: Substring) -> String? {
        let v = s.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.lowercased() == "not stated" ? nil : v
    }

    /// For pasting into Slack, Notion or email.
    public var markdown: String {
        let heading = title.map { "**\($0)**\n\n" } ?? ""
        guard isStructured else { return heading + body }
        return heading + sections.filter { $0.title != "Participants" || !participants.isEmpty }.map { s in
            let title = s.title.isEmpty ? "" : "**\(s.title)**\n"
            return title + (s.isList ? s.items.map { "- \($0)" } : s.items).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
