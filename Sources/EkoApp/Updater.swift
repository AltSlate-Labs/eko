import AppKit
import EkoCore
import Foundation
import Security

/// Self-update from GitHub Releases without third-party code.
///
/// Flow: check (daily in the background, or from the menu) → "Update available" in the menu →
/// confirmation → download the release DMG → mount it → copy the app next to the installed one →
/// verify that the copy satisfies the *running app's own* designated requirement (same bundle
/// identifier, same signing certificate / Team ID; Apple's code-signing machinery does the check)
/// → swap the bundles (the old one goes to the Trash) → relaunch. Anything that fails leaves the
/// installed app untouched. Ad-hoc-signed development builds refuse to self-update by design,
/// because their requirement is a hash of one specific build.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let downloadURL: URL
        let sizeBytes: Int
    }
    enum Phase: Equatable { case idle, checking, downloading(Int), installing(String) }
    enum UpdateError: LocalizedError {
        case notConfigured, badResponse(String), noAsset, untrustedSource(URL), notWritable(URL)
        case recording, mount(String), noAppInImage, signature(String), version(String), tool(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No update repository is configured in this build."
            case let .badResponse(detail): return "Unexpected response from GitHub: \(detail)"
            case .noAsset: return "The latest release has no .dmg attached."
            case let .untrustedSource(url): return "Refusing to download from \(url.host ?? "an unknown host")."
            case let .notWritable(url): return "Eko can't replace itself in \(url.deletingLastPathComponent().path). Download the DMG and install it by hand."
            case .recording: return "Stop the recording first, then update."
            case let .mount(detail): return "The disk image could not be opened: \(detail)"
            case .noAppInImage: return "The disk image does not contain \(Bundle.main.bundleURL.lastPathComponent)."
            case let .signature(detail): return "The downloaded app is not signed by the same publisher as this copy, so it was not installed. \(detail)"
            case let .version(detail): return "Version mismatch: \(detail)"
            case let .tool(detail): return detail
            }
        }
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    /// Daily background check (one HTTPS request to api.github.com). Off = only the menu item checks.
    @Published var automaticChecks: Bool = UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "automaticUpdateChecks") }
    }

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// "owner/name" of the GitHub repository whose Releases carry the DMGs (set by scripts/bundle.sh).
    static let repository: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "EkoUpdateRepository") as? String, !value.isEmpty else { return nil }
        return value
    }()
    /// Development only: EKO_UPDATE_FEED=<url of a releases/latest-shaped JSON> makes the app check
    /// that feed 2 s after launch and install the result without asking. Never set in normal use.
    private static let feedOverride = ProcessInfo.processInfo.environment["EKO_UPDATE_FEED"].flatMap(URL.init(string:))
    private static let checkInterval: TimeInterval = 24 * 3600

    var isConfigured: Bool { Self.repository != nil || Self.feedOverride != nil }
    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "Eko/\(Updater.currentVersion)", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: config)
    }()

    init() {
        let delay: TimeInterval = Self.feedOverride != nil ? 2 : 20
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if Self.feedOverride != nil { Task { await self?.developmentAutoInstall() } } else { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automaticChecks, isConfigured, phase == .idle else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { await check(manual: false) }
    }

    // MARK: Check

    /// Fetches the latest release. Manual checks report results in a dialog; automatic ones only
    /// update the menu (and the log).
    func check(manual: Bool) async {
        guard phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        do {
            let release = try await fetchLatest()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
            if VersionNumber.isNewer(release.version, than: Self.currentVersion) {
                available = release
                RecordingSession.dlog("update available: \(release.version) (running \(Self.currentVersion))")
                if manual { showAvailable() }
            } else {
                available = nil
                RecordingSession.dlog("update check: \(Self.currentVersion) is current (latest \(release.version))")
                if manual { info("Eko \(Self.currentVersion) is up to date.", "The latest release is \(release.version).") }
            }
        } catch {
            RecordingSession.dlog("update check failed: \(error.localizedDescription)")
            if manual { fail("Could not check for updates.", error) }
        }
    }

    private func fetchLatest() async throws -> Release {
        let url: URL
        if let override = Self.feedOverride {
            url = override
        } else if let repo = Self.repository, let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") {
            url = api
        } else { throw UpdateError.notConfigured }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse("no HTTP response") }
        guard http.statusCode == 200 else { throw UpdateError.badResponse("HTTP \(http.statusCode) for \(url.lastPathComponent)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { throw UpdateError.badResponse("missing fields") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.noAsset }
        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: version, notes: notes, pageURL: page, downloadURL: download, sizeBytes: asset["size"] as? Int ?? 0)
    }

    // MARK: Offer

    /// The dialog behind the "Update available" menu item.
    func showAvailable() {
        guard let release = available, phase == .idle else { return }
        let alert = NSAlert()
        alert.messageText = "Eko \(release.version) is available"
        var text = "You have \(Self.currentVersion). The update downloads \(Self.format(bytes: release.sizeBytes)), replaces the app in \(Bundle.main.bundleURL.deletingLastPathComponent().path) and relaunches. Your settings, permissions and recordings are kept."
        if !release.notes.isEmpty { text += "\n\n" + String(release.notes.prefix(700)) }
        alert.informativeText = text
        alert.addButton(withTitle: "Download and Install")
        alert.addButton(withTitle: "View Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await downloadAndInstall() }
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    // MARK: Install

    func downloadAndInstall() async {
        guard let release = available, phase == .idle else { return }
        let destination = Bundle.main.bundleURL.standardizedFileURL
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("eko-update-\(UUID().uuidString)", isDirectory: true)
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).update-\(ProcessInfo.processInfo.processIdentifier)")
        var mounted = false
        defer {
            if mounted { Task.detached { _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) } }
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: staging)
        }
        do {
            if RecorderModel.current?.isRecording == true { throw UpdateError.recording }
            try Self.checkSource(release.downloadURL)
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateError.notWritable(destination) }
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

            phase = .downloading(0)
            RecordingSession.dlog("update: downloading \(release.downloadURL)")
            let dmg = work.appendingPathComponent("update.dmg")
            try await download(release.downloadURL, to: dmg, expectedBytes: release.sizeBytes)

            phase = .installing("Opening disk image…")
            do {
                _ = try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            } catch { throw UpdateError.mount(error.localizedDescription) }
            mounted = true
            let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
            guard let newApp = apps.first(where: { $0.lastPathComponent == destination.lastPathComponent }) else { throw UpdateError.noAppInImage }

            phase = .installing("Verifying signature…")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: newApp, to: staging)   // verify the copy we will install, not the image
            try await Task.detached { try Self.verifySamePublisher(staging) }.value
            let newVersion = Bundle(url: staging)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            guard newVersion == release.version, VersionNumber.isNewer(newVersion, than: Self.currentVersion) else {
                throw UpdateError.version("the image contains \(newVersion), expected \(release.version) newer than \(Self.currentVersion)")
            }

            phase = .installing("Installing…")
            let previous = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).previous-\(ProcessInfo.processInfo.processIdentifier)")
            try FileManager.default.moveItem(at: destination, to: previous)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: previous, to: destination)   // roll back
                throw error
            }
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: previous, resultingItemURL: &trashed)) != nil, let trashed = trashed as URL? {
                let readable = trashed.deletingLastPathComponent().appendingPathComponent("Eko \(Self.currentVersion).app")
                try? FileManager.default.moveItem(at: trashed, to: readable)
            }
            if mounted { _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path]); mounted = false }
            RecordingSession.dlog("update: installed \(newVersion) at \(destination.path); relaunching")
            try Self.relaunch(destination)
            NSApp.terminate(nil)
        } catch {
            phase = .idle
            RecordingSession.dlog("update failed: \(error.localizedDescription)")
            fail("The update was not installed.", error)
        }
    }

    /// Only release assets of the configured repository, over HTTPS.
    private static func checkSource(_ url: URL) throws {
        if feedOverride != nil { return }
        guard url.scheme == "https", url.host == "github.com", let repo = repository,
              url.path.hasPrefix("/\(repo)/releases/download/") else { throw UpdateError.untrustedSource(url) }
    }

    private func download(_ url: URL, to file: URL, expectedBytes: Int) async throws {
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(Int(fraction * 100)) } }
        }
        let (tmp, response) = try await session.download(from: url, delegate: progress)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) while downloading")
        }
        try FileManager.default.moveItem(at: tmp, to: file)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if expectedBytes > 0, size != expectedBytes { throw UpdateError.badResponse("downloaded \(size) bytes, expected \(expectedBytes)") }
    }

    /// The candidate must satisfy the running app's designated requirement: same bundle identifier
    /// and the same certificate chain (Team ID for Developer ID builds).
    nonisolated private static func verifySamePublisher(_ bundle: URL) throws {
        func check(_ status: OSStatus, _ what: String) throws {
            guard status == errSecSuccess else {
                throw UpdateError.signature("\(what): \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")")
            }
        }
        var selfCode: SecCode?
        try check(SecCodeCopySelf([], &selfCode), "own code")
        var selfStatic: SecStaticCode?
        try check(SecCodeCopyStaticCode(selfCode!, [], &selfStatic), "own code")
        var requirement: SecRequirement?
        try check(SecCodeCopyDesignatedRequirement(selfStatic!, [], &requirement), "own requirement")
        var candidate: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(bundle as CFURL, [], &candidate), "candidate")
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidate!, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
            throw UpdateError.signature(detail)
        }
    }

    /// Waits for this process to exit, then opens the new copy. /bin/sh is an Apple-signed binary,
    /// so launching it is allowed under the hardened runtime.
    private static func relaunch(_ app: URL) throws {
        let script = "unset EKO_UPDATE_FEED; while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "eko-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try process.run()
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 { continuation.resume(returning: text) }
                else { continuation.resume(throwing: UpdateError.tool("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text)")) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Dialogs

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fail(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let release = available { alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Open Release Page")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(release.pageURL) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func developmentAutoInstall() async {
        await check(manual: false)
        if available != nil { await downloadAndInstall() }
    }

    static func format(bytes: Int) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : "the new version"
    }

    var phaseText: String? {
        switch phase {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case let .downloading(percent): return "Downloading update… \(percent)%"
        case let .installing(step): return "Updating: \(step)"
        }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
