import Foundation

/// Who was on a call. Gemini suggests names said in the call (the summary's PARTICIPANTS section); the user can
/// correct the list on the call's page, saved next to the recording as "<name>-participants.txt" (one person per
/// line, "Name (role)"). The user's list, when there is one, wins and is given to later summaries and chats.
public struct Participant: Equatable, Hashable {
    public var name: String
    public var role: String?
    /// Where the name is said in the call (suggestions only).
    public var time: TimeInterval?

    public init(name: String, role: String? = nil, time: TimeInterval? = nil) {
        self.name = name
        self.role = role
        self.time = time
    }

    /// "Rahul (Devsur) [00:04:10]", "Rahul — Devsur", "Rahul" → a participant; nil for an empty or "None stated" line.
    public init?(line: String) {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("• ") { text = String(text.dropFirst(2)) }
        let stamps = Timestamp.find(in: text)
        time = stamps.first?.seconds
        for m in stamps.reversed() { text = (text as NSString).replacingCharacters(in: m.range, with: "") }
        text = text.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            role = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            text = String(text[..<open])
        } else if let dash = text.range(of: " — ") ?? text.range(of: " - ") {
            role = String(text[dash.upperBound...])
            text = String(text[..<dash.lowerBound])
        }
        name = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        role = role?.trimmingCharacters(in: .whitespaces)
        if role?.isEmpty == true || role?.lowercased() == "not stated" { role = nil }
        let lower = name.lowercased()
        guard !name.isEmpty, name.count <= 80, lower != "none stated", lower != "you", lower != "others" else { return nil }
    }

    /// "Rahul (Devsur)", as written to the file and shown in prompts.
    public var line: String { role.map { "\(name) (\($0))" } ?? name }
}

public enum Participants {
    public static func url(for recording: URL) -> URL { OutputFile.sibling(of: recording, suffix: "-participants.txt") }

    /// The user's list for this call; nil when they have not edited it.
    public static func load(for recording: URL) -> [Participant]? {
        guard let text = try? String(contentsOf: url(for: recording), encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> [Participant] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap(Participant.init(line:)).filter {
            seen.insert($0.name.lowercased()).inserted
        }
    }

    /// Saves the user's list (owner-only, atomic). An empty list removes the file, so Gemini's suggestions show again.
    public static func save(_ people: [Participant], for recording: URL) throws {
        let file = url(for: recording)
        guard !people.isEmpty else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try OutputFile.write(people.map(\.line).joined(separator: "\n") + "\n", to: file, overwrite: true)
    }

    /// For the summary and chat prompts: "People on the call, as given by the user: A (role), B."
    public static func promptLine(_ people: [Participant]?) -> String {
        guard let people, !people.isEmpty else { return "" }
        return " People on the call, as given by the user: " + people.map(\.line).joined(separator: ", ") + "."
    }
}
