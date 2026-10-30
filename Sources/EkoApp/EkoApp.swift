import AppKit
import EkoCore
import SwiftUI

@main
struct EkoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
                .environmentObject(updater)
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
        Divider()
        Button("Show Last Recording") { model.revealLastRecording() }
            .disabled(model.lastRecording == nil)
        Button("Open Recordings Folder") { model.openFolder() }
        Menu("Recordings Folder: \(model.outputDirectory.lastPathComponent)") {
            Text(model.outputDirectory.path)
            Button("Change…") { model.chooseFolder() }.disabled(model.isRecording)
            Button("Reset to Default (~/Documents/CallRecordings)") { model.resetFolder() }.disabled(model.isRecording || model.isDefaultFolder)
        }
        Divider()
        Menu("When a call starts") {
            Toggle("Ask me (floating prompt)", isOn: $model.nudgeOnCall)
            Toggle("Start recording automatically", isOn: $model.autoStartOnCall)
            Toggle("Stop automatically when the call ends", isOn: $model.autoStopOnCallEnd)
            Divider()
            Text("Detected: \(model.detectedCall ?? "no call app using the mic")")
        }
        Toggle("Launch at Login", isOn: $model.launchAtLogin)
        Text("Hotkey: ⌃⌥⌘R")
        Divider()
        if let release = updater.available {
            Button { updater.showAvailable() } label: {
                Label("Update Available: Eko \(release.version)", systemImage: "arrow.down.circle.fill")
            }
            .disabled(updater.phase != .idle)
        } else {
            Button(updater.phaseText ?? "Check for Updates…") { Task { await updater.check(manual: true) } }
                .disabled(updater.phase != .idle || !updater.isConfigured)
        }
        if updater.available != nil, let text = updater.phaseText { Text(text) }
        Toggle("Check for Updates Daily", isOn: $updater.automaticChecks)
            .disabled(!updater.isConfigured)
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

    /// Control URLs for automation and testing: eko://start, eko://stop, eko://toggle
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "start": Self.model?.start()
            case "stop": Self.model?.stop()
            case "toggle": Self.model?.toggle()
            case "nudge": Self.model?.previewNudge()
            default: break
            }
        }
    }
}
