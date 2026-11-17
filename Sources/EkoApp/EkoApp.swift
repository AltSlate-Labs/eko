import AppKit
import EkoCore
import SwiftUI

@main
struct EkoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()
    @StateObject private var updater = Updater()
    @StateObject private var notes = NotesModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(notes)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.image(recording: model.isRecording, capturing: model.isCapturing))
                if model.isRecording { Text(model.elapsedText).monospacedDigit().fontWeight(.bold) }
            }
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // StateObject is not created until the body is evaluated; keep a hook for the delegate.
        DispatchQueue.main.async { AppDelegate.model = RecorderModel.current }
    }
}

/// Bold menu-bar glyphs: heavy waveform when idle (template, adapts to light/dark),
/// solid red record dot while recording (hollow until audio is actually flowing).
enum MenuBarIcon {
    static func image(recording: Bool, capturing: Bool) -> NSImage {
        let name = recording ? (capturing ? "record.circle.fill" : "record.circle") : "waveform"
        var config = NSImage.SymbolConfiguration(pointSize: 16, weight: .heavy)
        if recording { config = config.applying(.init(paletteColors: [.systemRed])) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: recording ? "Recording" : "Eko")!
            .withSymbolConfiguration(config)!
        image.isTemplate = !recording
        return image
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var notes: NotesModel

    private var levelsText: String {
        let mic = Int(min(1, model.levels.mic) * 100)
        let system = Int(min(1, model.levels.system) * 100)
        return "mic \(mic)%   system \(system)%"
    }

    var body: some View {
        Text(model.statusLine)
        if model.isRecording {
            Text(levelsText)
        }
        if let line = notes.statusLine {
            Text(line.prefix(160))
        }
        if let warning = model.warning {
            Divider()
            Text(warning.prefix(160))
            if warning.contains("Privacy_AudioCapture") {
                Button("Open System Audio Privacy Settings…") { model.openSystemAudioPrivacySettings() }
            }
        }
        Divider()
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggle() }
            .disabled(model.isBusy)
            .keyboardShortcut("r")
        Button("Open Library…") { LibraryWindowController.shared.show(.recordings) }
            .keyboardShortcut("l")
        Divider()
        Button("Show Last Recording") { model.revealLastRecording() }
            .disabled(model.lastRecording == nil)
        Button("Open Recordings Folder") { model.openFolder() }
        Menu("Transcripts") {
            if let line = notes.statusLine { Text(line.prefix(160)) }
            if notes.failedCount > 0 || notes.keychainRefused {
                Button(notes.failedCount > 0 ? "Retry Failed Transcripts" : "Retry") { notes.retry() }
            }
            if notes.statusLine != nil || notes.failedCount > 0 { Divider() }
            Button("Transcribe Last Recording") { if let url = model.lastRecording { notes.transcribe(url) } }
                .disabled(model.lastRecording == nil)
            Toggle("Transcribe Every Call Automatically", isOn: $notes.auto)
            if notes.maskedKey == nil {
                Divider()
                Button("Set Gemini Key…") { notes.showKeyDialog() }
            }
        }
        if let detected = model.detectedCall { Text("Call detected: \(detected)") }
        Divider()
        Button("Settings…") { LibraryWindowController.shared.show(.settings) }
            .keyboardShortcut(",")
        if let release = updater.available {
            Button { updater.showAvailable() } label: {
                Label("Update Available: Eko \(release.version)", systemImage: "arrow.down.circle.fill")
            }
            .disabled(updater.phase != .idle)
            if let text = updater.phaseText { Text(text) }
        } else {
            Button(updater.phaseText ?? "Check for Updates…") { Task { await updater.check(manual: true) } }
                .disabled(updater.phase != .idle || !updater.isConfigured)
        }
        Divider()
        Button("Quit") { model.quit() }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App so URL commands can reach the model.
    static weak var model: RecorderModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        quitIfRunningFromDiskImage()
    }

    /// Clicking Eko in the Dock (or opening it again from Finder or Launchpad) shows the Library, including
    /// when its window is minimised.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if let window = LibraryWindowController.shared.window, window.isMiniaturized { window.deminiaturize(nil) }
            LibraryWindowController.shared.show()
        }
        return false
    }

    /// ⌘Q in the Library (or a logout) must not cut a recording off unsaved: stop and save it first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model ?? RecorderModel.current, model.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Stop and save it, then quit Eko?"
        alert.addButton(withTitle: "Stop, Save and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.quit() }   // quits once the file is saved
        return .terminateCancel
    }

    /// Launched straight from the downloaded .dmg, or App-Translocated out of Downloads: both are
    /// read-only volumes that vanish on eject, so permissions, Launch at Login and the Spotlight
    /// entry would be tied to a disappearing copy. Ask for a real install instead.
    private func quitIfRunningFromDiskImage() {
        let url = Bundle.main.bundleURL
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values?.volumeIsReadOnly == true else { return }
        RecordingSession.dlog("launched from a read-only volume (\(url.path)); asking for install")
        let alert = NSAlert()
        alert.messageText = "Install Eko first"
        alert.informativeText = "Drag Eko into the Applications folder, then open it from there."
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Control URLs for automation and testing: eko://start, eko://stop, eko://toggle, eko://library, eko://settings
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "start": Self.model?.start()
            case "stop": Self.model?.stop()
            case "toggle": Self.model?.toggle()
            case "nudge": Self.model?.previewNudge()
            case "library": MainActor.assumeIsolated { LibraryWindowController.shared.show(.recordings) }
            case "settings": MainActor.assumeIsolated { LibraryWindowController.shared.show(.settings) }
            case "ui": MainActor.assumeIsolated { UICheck.handle(url) }
            default: break
            }
        }
    }
}
