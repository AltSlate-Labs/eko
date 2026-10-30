import AppKit
import EkoCore
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement

@MainActor
final class RecorderModel: ObservableObject {
    /// The single model instance owned by the App scene.
    static weak var current: RecorderModel?
    @Published private(set) var isRecording = false
    /// True once audio is actually flowing (the HAL takes a few seconds to spin up).
    @Published private(set) var isCapturing = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels = RecordingLevels()
    @Published private(set) var statusLine = "Ready"
    @Published private(set) var warning: String?
    @Published private(set) var lastRecording: URL?
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }
    /// Show a floating prompt when a call app opens the microphone.
    @Published var nudgeOnCall: Bool = UserDefaults.standard.object(forKey: "nudgeOnCall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nudgeOnCall, forKey: "nudgeOnCall") }
    }
    /// Start recording automatically instead of asking.
    @Published var autoStartOnCall: Bool = UserDefaults.standard.bool(forKey: "autoStartOnCall") {
        didSet { UserDefaults.standard.set(autoStartOnCall, forKey: "autoStartOnCall") }
    }
    /// Stop recording automatically when the call app releases the microphone.
    @Published var autoStopOnCallEnd: Bool = UserDefaults.standard.bool(forKey: "autoStopOnCallEnd") {
        didSet { UserDefaults.standard.set(autoStopOnCallEnd, forKey: "autoStopOnCallEnd") }
    }
    @Published private(set) var detectedCall: String?

    @Published private(set) var outputDirectory: URL
    private var session: RecordingSession
    private var ticker: Timer?
    private var hotKey: GlobalHotKey?
    private var quitAfterStop = false
    private let detector = CallDetector()
    private let nudge = NudgePanel()

    init() {
        let saved = UserDefaults.standard.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let folder = saved ?? RecordingOptions.defaultDirectory
        outputDirectory = folder
        session = RecordingSession(options: RecordingOptions(outputDirectory: folder))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Self.current = self
        wireSession()
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.toggle()
        }
        detector.onCallStarted = { [weak self] app in Task { @MainActor in self?.callStarted(app) } }
        detector.onCallEnded = { [weak self] app in Task { @MainActor in self?.callEnded(app) } }
        detector.start()
    }

    private func callStarted(_ app: String) {
        detectedCall = app
        guard !isRecording, !isBusy else { return }
        if autoStartOnCall {
            start()
            NSSound(named: "Submarine")?.play()
        } else if nudgeOnCall {
            let what = ["Chrome", "Safari", "Arc", "Brave", "Edge", "Firefox"].contains(app) ? "\(app) is using the microphone (Google Meet?)" : "\(app) call in progress"
            nudge.show(title: "Record this call?", message: what, primary: "Start recording", timeout: 20) { [weak self] in self?.start() }
        }
    }

    private func callEnded(_ app: String) {
        detectedCall = nil
        guard isRecording, !isBusy else { return }
        if autoStopOnCallEnd {
            stop()
        } else if nudgeOnCall {
            nudge.show(title: "Call ended", message: "\(app) released the microphone. Stop recording?", primary: "Stop recording", secondary: "Keep going", timeout: 20) { [weak self] in self?.stop() }
        }
    }

    /// Debug helper (eko://nudge): shows the start prompt without a real call.
    func previewNudge() {
        nudge.show(title: "Record this call?", message: "Zoom call in progress", primary: "Start recording", timeout: 20) { [weak self] in self?.start() }
    }

    private func wireSession() {
        session.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
    }

    var isDefaultFolder: Bool { outputDirectory.standardizedFileURL == RecordingOptions.defaultDirectory.standardizedFileURL }

    /// Opens a folder picker; takes effect for the next recording.
    func chooseFolder() {
        guard !isRecording, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "Use this folder"
        panel.message = "Choose where recordings are saved"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func resetFolder() {
        guard !isRecording, !isBusy else { return }
        setFolder(RecordingOptions.defaultDirectory)
    }

    private func setFolder(_ url: URL) {
        outputDirectory = url
        if url.standardizedFileURL == RecordingOptions.defaultDirectory.standardizedFileURL {
            UserDefaults.standard.removeObject(forKey: "outputDirectory")
        } else {
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        }
        session = RecordingSession(options: RecordingOptions(outputDirectory: url))
        wireSession()
        statusLine = "Saving to \(url.lastPathComponent)"
    }

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func toggle() {
        guard !isBusy else { return }
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        warning = nil
        statusLine = "Starting…"
        session.start()
    }

    func stop() {
        guard isRecording, !isBusy else { return }
        isBusy = true
        statusLine = "Saving…"
        session.stop()
    }

    /// Stops a running recording and quits when it is saved; quits immediately otherwise.
    func quit() {
        if isRecording {
            quitAfterStop = true
            stop()
        } else {
            NSApp.terminate(nil)
        }
    }

    func revealLastRecording() {
        guard let lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func openSystemAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case .started:
            nudge.dismiss()
            isBusy = false
            isRecording = true
            isCapturing = false
            statusLine = "Starting audio capture…"
        case .capturing:
            isCapturing = true
            statusLine = "Recording"
            NSSound(named: "Pop")?.play()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.elapsed = self.session.elapsed
                    self.levels = self.session.currentLevels
                }
            }
        case let .warning(message):
            warning = message
        case let .info(message):
            statusLine = message
        case let .devicesChanged(summary):
            statusLine = "Recording (devices changed: \(summary))"
        case let .stopped(url, duration):
            ticker?.invalidate()
            ticker = nil
            isBusy = false
            isRecording = false
            isCapturing = false
            elapsed = 0
            lastRecording = url
            statusLine = String(format: "Saved %@ (%@)", url.lastPathComponent, Self.format(duration: duration))
            NSSound(named: "Glass")?.play()
            if quitAfterStop { NSApp.terminate(nil) }
        case let .failed(error):
            ticker?.invalidate()
            ticker = nil
            isBusy = false
            isRecording = false
            isCapturing = false
            statusLine = "Failed to start"
            warning = "\(error)"
            NSSound(named: "Basso")?.play()
            if quitAfterStop { NSApp.terminate(nil) }
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            warning = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    private static func format(duration: TimeInterval) -> String {
        let s = Int(duration)
        return s >= 3600 ? String(format: "%dh %02dm", s / 3600, s / 60 % 60) : String(format: "%dm %02ds", s / 60, s % 60)
    }
}
