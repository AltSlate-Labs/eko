import CryptoKit
import Foundation

/// Finished pieces of a transcription, kept on disk until the transcript is written, so a retry after a failure
/// (Gemini overloaded, quota used up, Mac asleep, app quit) only sends the pieces still missing. Every request,
/// failed or not, counts against the free daily quota.
///
/// ~/Library/Application Support/Eko/parts/<id>/<piece>.json — folders 0700, files 0600. The files hold
/// transcript text, so they are removed once the transcript is written, and left-overs after 14 days.
struct PartCache {
    let dir: URL
    static let keepFor: TimeInterval = 14 * 24 * 3600

    static var defaultRoot: URL { NotesSettings.supportDirectory.appendingPathComponent("parts", isDirectory: true) }

    /// Pieces belong to one recording file (path, size, modified time), cut with one piece length, sent to one model.
    init?(root: URL, recording: URL, chunkSeconds: Double, model: String) {
        guard let v = try? recording.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let id = [recording.standardizedFileURL.path, "\(v.fileSize ?? 0)",
                  "\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)", "\(chunkSeconds)", model].joined(separator: "|")
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        dir = root.appendingPathComponent(hash, isDirectory: true)
    }

    private func file(for part: AudioPart) -> URL {
        let side = part.speaker == .unlabelled ? "mix" : part.speaker.rawValue.lowercased()
        return dir.appendingPathComponent(String(format: "%@-%.0f-%.0f.json", side, part.offset * 1000, part.duration * 1000))
    }

    func load(_ part: AudioPart) -> SpeechResult? {
        guard let data = try? Data(contentsOf: file(for: part)) else { return nil }
        return try? JSONDecoder().decode(SpeechResult.self, from: data)
    }

    /// Best effort: a piece that cannot be saved is just sent again next time.
    func save(_ result: SpeechResult, for part: AudioPart) {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              let data = try? JSONEncoder().encode(result) else { return }
        let url = file(for: part)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        try? data.write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    /// Drops pieces of recordings that never finished (deleted, or failed for good).
    static func removeStale(root: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for d in dirs {
            let changed = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(changed) > keepFor { try? fm.removeItem(at: d) }
        }
    }
}
