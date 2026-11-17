import Foundation

/// Settings for transcripts and summaries. Stored in the app's defaults domain (`com.altslate.eko`) so the
/// menu-bar app and the `eko` CLI read the same values. Change hidden ones with, for example:
/// `defaults write com.altslate.eko notes.transcribeModel gemini-3.6-flash`
public struct NotesSettings {
    public static let domain = "com.altslate.eko"
    public static let defaultModel = "gemini-3.6-flash"
    /// Chat uses a smaller model: the free daily limit is counted per model, so questions never use up the
    /// requests transcripts need (verified 2026-11-15: Flash-Lite answered while Flash's limit was used up).
    public static let defaultChatModel = "gemini-3.5-flash-lite"

    /// Transcribe every call automatically after it is saved.
    public var auto = true
    /// Recordings shorter than this are skipped by the automatic trigger.
    public var minimumSeconds: Double = 30
    public var transcribeModel = NotesSettings.defaultModel
    public var summaryModel = NotesSettings.defaultModel
    public var chatModel = NotesSettings.defaultChatModel
    public var thinkingLevel = "low"
    public var summaryThinkingLevel = "medium"
    /// Sides longer than this are sent in pieces, cut at a quiet moment. Each piece is one request, and the
    /// free tier allows 20 requests a day per model, so pieces are as long as tested reliable (39 min).
    public var chunkMinutes: Double = 40

    public init() {}

    /// The shared defaults: `.standard` inside the app (whose bundle id is the domain), a named suite elsewhere.
    public static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    public static func load(from d: UserDefaults = NotesSettings.defaults) -> NotesSettings {
        var s = NotesSettings()
        if d.object(forKey: "notes.auto") != nil { s.auto = d.bool(forKey: "notes.auto") }
        if d.object(forKey: "notes.minimumSeconds") != nil { s.minimumSeconds = d.double(forKey: "notes.minimumSeconds") }
        if let v = d.string(forKey: "notes.transcribeModel"), !v.isEmpty { s.transcribeModel = v }
        if let v = d.string(forKey: "notes.summaryModel"), !v.isEmpty { s.summaryModel = v }
        if let v = d.string(forKey: "notes.chatModel"), !v.isEmpty { s.chatModel = v }
        if let v = d.string(forKey: "notes.thinkingLevel"), !v.isEmpty { s.thinkingLevel = v }
        if let v = d.string(forKey: "notes.summaryThinkingLevel"), !v.isEmpty { s.summaryThinkingLevel = v }
        if d.object(forKey: "notes.chunkMinutes") != nil, d.double(forKey: "notes.chunkMinutes") >= 1 {
            s.chunkMinutes = d.double(forKey: "notes.chunkMinutes")
        }
        return s
    }

    public static func setAuto(_ on: Bool, in d: UserDefaults = NotesSettings.defaults) {
        d.set(on, forKey: "notes.auto")
    }

    // MARK: Files in ~/Library/Application Support/Eko (folder 0700, files 0600)

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Eko", isDirectory: true)
    }
    public static var namesFile: URL { supportDirectory.appendingPathComponent("names.txt") }
    public static var summaryPromptFile: URL { supportDirectory.appendingPathComponent("summary-prompt.txt") }
    public static var queueFile: URL { supportDirectory.appendingPathComponent("notes-queue.json") }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public static let namesFileTemplate = """
    # Names and terms Eko asks Gemini to spell exactly as written here, one per line.
    # Add people, companies, products and jargon that come up in your calls, e.g.
    #   Priya Sharma
    #   Acme Corp
    #   Kubernetes
    # Optional: tell the summary who "You" is, so action items name you:
    #   me: Your Name
    # Lines starting with # are ignored.

    """
}

/// The user's names-and-terms list (names.txt).
public struct NamesList: Equatable {
    public var terms: [String] = []
    /// From a `me: <name>` line: who "You" is.
    public var me: String?

    public init(terms: [String] = [], me: String? = nil) {
        self.terms = terms
        self.me = me
    }

    public init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("me:") {
                let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { me = name }
                continue
            }
            if !terms.contains(line) { terms.append(line) }
        }
        if let me, !terms.contains(me) { terms.insert(me, at: 0) }
    }

    public static func load(from url: URL = NotesSettings.namesFile) -> NamesList {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return NamesList() }
        return NamesList(text: text)
    }

    /// Settings shows "Your name" and the rest of names.txt as two fields: split the file on its `me:` line…
    public static func splitMe(_ text: String) -> (me: String, rest: String) {
        var me = ""
        var rest: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("me:") {
                me = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else {
                rest.append(line)
            }
        }
        return (me, rest.joined(separator: "\n"))
    }

    /// …and put it back together, with the `me:` line first.
    public static func joinMe(_ me: String, _ rest: String) -> String {
        let name = me.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return name.isEmpty ? rest : "me: \(name)\n" + rest
    }
}
