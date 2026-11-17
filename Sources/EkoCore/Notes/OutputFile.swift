import Darwin
import Foundation

/// Where transcripts and summaries go, and how they are written: next to the recording, owner-only (0600),
/// atomically (temp file + rename, so a half-written file is never visible), and never over an existing file
/// unless asked (a hand-edited transcript or summary must not be lost).
public enum OutputFile {
    public enum WriteError: LocalizedError, Equatable {
        case exists(String), failed(String)
        public var errorDescription: String? {
            switch self {
            case let .exists(name): return "\(name) already exists."
            case let .failed(detail): return "Could not write the file: \(detail)"
            }
        }
    }

    public static func transcriptURL(for recording: URL) -> URL { sibling(of: recording, suffix: "-transcript.txt") }
    public static func summaryURL(for recording: URL) -> URL { sibling(of: recording, suffix: "-summary.txt") }
    public static func chatURL(for recording: URL) -> URL { sibling(of: recording, suffix: "-chat.json") }

    static func sibling(of recording: URL, suffix: String) -> URL {
        let base = recording.deletingPathExtension().lastPathComponent
        return recording.deletingLastPathComponent().appendingPathComponent(base + suffix)
    }

    public static func write(_ text: String, to url: URL, overwrite: Bool) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw WriteError.failed("cannot create a file in \(dir.path)")
        }
        let flags = overwrite ? UInt32(0) : UInt32(RENAME_EXCL)
        if renamex_np(temp.path, url.path, flags) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            if code == EEXIST { throw WriteError.exists(url.lastPathComponent) }
            throw WriteError.failed(String(cString: strerror(code)))
        }
    }
}
