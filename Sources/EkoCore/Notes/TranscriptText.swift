import Foundation

public enum Speaker: String, Codable, Equatable {
    case you = "You", others = "Others", unlabelled = ""
}

public struct Segment: Equatable, Codable {
    public var start: TimeInterval
    public var speaker: Speaker
    public var text: String
    public init(start: TimeInterval, speaker: Speaker, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// Parsing, checking and merging of model transcript text, and the transcript file format.
public enum TranscriptText {
    // MARK: Model output

    public struct Parsed: Equatable {
        public var segments: [Segment]
        /// Non-empty lines that had no timestamp and no previous segment to join.
        public var unparsedLines: Int
        public var totalLines: Int
        public var unparsedFraction: Double { totalLines == 0 ? 0 : Double(unparsedLines) / Double(totalLines) }
    }

    /// `[HH:MM:SS]`, `[H:MM:SS]` or `[MM:SS]` at the start of a line. The model was asked for HH:MM:SS but
    /// returned MM:SS on shorter audio in tests, and sometimes MM:SS:hundredths (see `parseModelOutput`).
    private static let stamp = try! NSRegularExpression(pattern: #"^\s*\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:\.\d+)?\]\s*(.*)$"#)

    /// Parses model lines. With `duration` (the audio's length), three-part stamps are read as
    /// minutes:seconds:hundredths instead of hours:minutes:seconds when only that reading fits the audio
    /// (seen on a 39-minute side: `[05:23:40]` meaning 5 min 23.4 s).
    public static func parseModelOutput(_ text: String, speaker: Speaker, duration: TimeInterval? = nil) -> Parsed {
        parse(text, speaker: speaker, stripLabels: true, duration: duration)
    }

    private struct Stamp {
        var first: Double?   // the optional leading field
        var second: Double
        var third: Double
        var hms: TimeInterval { (first ?? 0) * 3600 + second * 60 + third }
        /// minutes:seconds:hundredths; nil when that reading is impossible.
        var msc: TimeInterval? {
            guard let first, second < 60 else { return nil }
            return first * 60 + second + third / 100
        }
    }

    /// A time inside a line, with or without brackets: `[04:26]`, `[00:04:26]`, `00:04:26`, `04:26.5`.
    private static let anyStamp = try! NSRegularExpression(pattern: #"(?<![\d:.])\[?((?:\d{1,2}:)?\d{1,3}:\d{2}(?:\.\d+)?)\]?(?![\d:])"#)

    /// The model sometimes returns a stretch of speech as one paragraph with the times inside it, bracketed or
    /// bare (seen on a 54-minute call). Each such time then starts a new line, as `[time] text`. A bare time
    /// only counts when the line has at least three, so a time someone says ("at 10:30") stays text.
    static func splitInlineStamps(_ text: String) -> String {
        var out: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let ns = line as NSString
            let matches = anyStamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            let bare = matches.filter { ns.substring(with: $0.range).first != "[" }
            let cuts = matches.filter { m in
                m.range.location > 0 && (ns.substring(with: m.range).first == "[" || bare.count >= 3)
            }
            guard !cuts.isEmpty else { out.append(line); continue }
            var start = 0
            var pieces: [String] = []
            for m in cuts {
                pieces.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                start = m.range.location
            }
            pieces.append(ns.substring(from: start))
            for piece in pieces {
                let p = piece.trimmingCharacters(in: .whitespaces)
                if p.isEmpty { continue }
                let pn = p as NSString
                if let m = anyStamp.firstMatch(in: p, range: NSRange(location: 0, length: pn.length)), m.range.location == 0,
                   pn.substring(with: m.range).first != "[" {
                    out.append("[" + pn.substring(with: m.range(at: 1)) + "] " + pn.substring(from: m.range.length))
                } else {
                    out.append(p)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    static func parse(_ text: String, speaker: Speaker, stripLabels: Bool, duration: TimeInterval? = nil) -> Parsed {
        var lines: [(stamp: Stamp, text: String)] = []
        var unparsed = 0
        var total = 0
        // Only model replies: a saved transcript is already one line per utterance, and times inside one of its
        // lines are relative to an audio part, not the call.
        let text = stripLabels ? splitInlineStamps(text) : text
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "```" || line.hasPrefix("```") { continue }
            total += 1
            line = line.replacingOccurrences(of: "**", with: "")
            let ns = line as NSString
            if let m = stamp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let first = m.range(at: 1).location == NSNotFound ? nil : Double(ns.substring(with: m.range(at: 1)))
                let st = Stamp(first: first, second: Double(ns.substring(with: m.range(at: 2))) ?? 0,
                               third: Double(ns.substring(with: m.range(at: 3))) ?? 0)
                var body = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
                if stripLabels { body = stripSpeakerPrefix(body) }
                if body.isEmpty { continue }
                lines.append((st, body))
            } else if !lines.isEmpty {
                lines[lines.count - 1].text += " " + line
            } else {
                unparsed += 1
            }
        }
        var useMSC = false
        if let duration {
            let limit = duration + 5
            let threePart = lines.filter { $0.stamp.first != nil }
            let pastEndHMS = threePart.filter { $0.stamp.hms > limit }.count
            let alternatives = threePart.compactMap(\.stamp.msc)
            useMSC = pastEndHMS > 0 && alternatives.count == threePart.count && alternatives.filter { $0 > limit }.count < pastEndHMS
        }
        let segments = lines.map { l in
            Segment(start: useMSC ? (l.stamp.msc ?? l.stamp.hms) : l.stamp.hms, speaker: speaker, text: l.text)
        }
        return Parsed(segments: segments, unparsedLines: unparsed, totalLines: total)
    }

    /// Share of the text (0…1) in lines longer than `maxChars`: the model put a stretch of speech in one
    /// paragraph without times instead of one line per utterance.
    public static func paragraphFraction(_ segments: [Segment], maxChars: Int = 600) -> Double {
        let total = segments.reduce(0) { $0 + $1.text.count }
        guard total > 0 else { return 0 }
        return Double(segments.filter { $0.text.count > maxChars }.reduce(0) { $0 + $1.text.count }) / Double(total)
    }

    /// Last resort for such a paragraph: split it into sentences of up to about 240 characters, with start times
    /// spread between its own start and the next line's start (or `end`) in proportion to the text before them.
    public static func splitParagraphs(_ segments: [Segment], end: TimeInterval, maxChars: Int = 600) -> ([Segment], Int) {
        var out: [Segment] = []
        var split = 0
        for (i, seg) in segments.enumerated() {
            guard seg.text.count > maxChars else { out.append(seg); continue }
            split += 1
            let next = i + 1 < segments.count ? segments[i + 1].start : end
            let span = max(0, next - seg.start)
            var pieces: [String] = []
            for sentence in seg.text.split(whereSeparator: \.isNewline).flatMap({ sentences($0) }) {
                if let last = pieces.last, last.count + sentence.count < 240 { pieces[pieces.count - 1] = last + " " + sentence }
                else { pieces.append(sentence) }
            }
            let total = Double(pieces.reduce(0) { $0 + $1.count })
            var before = 0.0
            for piece in pieces {
                out.append(Segment(start: (seg.start + span * before / max(total, 1)).rounded(), speaker: seg.speaker, text: piece))
                before += Double(piece.count)
            }
        }
        return (out, split)
    }

    private static func sentences(_ text: Substring) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { result.append(t) }
        return result
    }

    /// Some outputs label lines ("Speaker 1: …"); the side is already known, so drop such a label.
    private static func stripSpeakerPrefix(_ text: String) -> String {
        for prefix in ["Speaker 1:", "Speaker:", "You:", "Others:"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: Checks

    public struct Cleaned: Equatable {
        public var segments: [Segment]
        public var outOfRange = 0
        public var repeatsCollapsed = 0
    }

    /// Drops lines starting after the audio ended (hallucinated tail), orders by time (stable), and collapses
    /// runs of more than three identical lines (a known failure on noise).
    public static func clean(_ input: [Segment], duration: TimeInterval) -> Cleaned {
        var out = Cleaned(segments: [])
        var kept = input.filter { seg in
            if seg.start > duration + 5 { out.outOfRange += 1; return false }
            return true
        }
        kept = kept.enumerated().sorted { a, b in
            a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start
        }.map(\.element)
        var run = 0
        for seg in kept {
            if let last = out.segments.last, normalise(last.text) == normalise(seg.text) {
                run += 1
                if run >= 3 { out.repeatsCollapsed += 1; continue }
            } else {
                run = 0
            }
            out.segments.append(seg)
        }
        return out
    }

    /// Share of letters that are not Latin script (Devanagari, CJK, …). Transcripts must be Roman script only.
    public static func nonLatinFraction(_ text: String) -> Double {
        var letters = 0, foreign = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if !isLatin(scalar) { foreign += 1 }
        }
        return letters == 0 ? 0 : Double(foreign) / Double(letters)
    }

    static func isLatin(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0000...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF: return true
        default: return false
        }
    }

    public static func offset(_ segments: [Segment], by seconds: TimeInterval) -> [Segment] {
        segments.map { Segment(start: $0.start + seconds, speaker: $0.speaker, text: $0.text) }
    }

    /// Interleaves both sides by start time; on a tie "You" comes first.
    public static func merge(_ lists: [[Segment]]) -> [Segment] {
        let all = lists.flatMap { $0 }
        return all.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.speaker != b.element.speaker { return a.element.speaker == .you }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Mic bleed: on speakers the microphone also hears the other side, so the same words appear as "You".
    /// Drops a You line that starts within 3 s of an Others line, has at least 4 words and shares at least
    /// 60 % of its words with it. Returns the cleaned list and how many lines were removed.
    public static func removeBleed(_ segments: [Segment]) -> ([Segment], Int) {
        let others = segments.filter { $0.speaker == .others }
        var removed = 0
        let kept = segments.filter { seg in
            guard seg.speaker == .you else { return true }
            let words = wordList(seg.text)
            guard words.count >= 4 else { return true }
            for o in others where abs(o.start - seg.start) <= 3 {
                let theirList = wordList(o.text)
                // An echo is about as long as what it echoes; a much longer You line has the user's own words too.
                guard words.count <= theirList.count * 3 / 2 + 3 else { continue }
                let theirs = Set(theirList)
                let shared = words.filter { theirs.contains($0) }.count
                if Double(shared) / Double(words.count) >= 0.6 { removed += 1; return false }
            }
            return true
        }
        return (kept, removed)
    }

    static func wordList(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func normalise(_ text: String) -> String { wordList(text).joined(separator: " ") }

    // MARK: Transcript file

    public struct Header {
        public var recording: String
        public var date: String
        public var duration: TimeInterval
        public var apps: [String]
        public var engine: String
        public var labelled: Bool
        public var checks: [String]
        public init(recording: String, date: String, duration: TimeInterval, apps: [String], engine: String, labelled: Bool, checks: [String]) {
            self.recording = recording
            self.date = date
            self.duration = duration
            self.apps = apps
            self.engine = engine
            self.labelled = labelled
            self.checks = checks
        }
    }

    public static let rule = String(repeating: "-", count: 60)

    public static func render(header h: Header, segments: [Segment]) -> String {
        var lines = ["Eko call transcript", "Recording: \(h.recording)"]
        var meta = "Date: \(h.date) · Duration: \(clock(h.duration))"
        if !h.apps.isEmpty { meta += " · Apps: \(h.apps.joined(separator: ", "))" }
        lines.append(meta)
        lines.append("Speech-to-text: \(h.engine)")
        lines.append(h.labelled
            ? "Speakers: You = this Mac's microphone · Others = call audio (other people are not told apart)"
            : "Speakers: not labelled (recording made before Eko 0.1.2 kept the sides apart)")
        if !h.checks.isEmpty { lines.append("Checks: " + h.checks.joined(separator: " · ")) }
        lines.append(rule)
        for s in segments {
            lines.append(s.speaker == .unlabelled ? "[\(clock(s.start))] \(s.text)" : "[\(clock(s.start))] \(s.speaker.rawValue): \(s.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the segment lines of a transcript file (also a hand-edited one) back, for re-summarising.
    public static func parseFile(_ text: String) -> [Segment] {
        var body = Substring(text)
        if let r = text.range(of: "\n" + rule + "\n") { body = text[r.upperBound...] }
        var out: [Segment] = []
        for seg in parse(String(body), speaker: .unlabelled, stripLabels: false).segments {
            var s = seg
            for sp in [Speaker.you, .others] where s.text.hasPrefix(sp.rawValue + ":") {
                s.speaker = sp
                s.text = String(s.text.dropFirst(sp.rawValue.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            out.append(s)
        }
        return out
    }

    /// The transcript lines as sent to the summary model (no header).
    public static func linesForPrompt(_ segments: [Segment]) -> String {
        segments.map { s in
            s.speaker == .unlabelled ? "[\(clock(s.start))] \(s.text)" : "[\(clock(s.start))] \(s.speaker.rawValue): \(s.text)"
        }.joined(separator: "\n")
    }

    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
