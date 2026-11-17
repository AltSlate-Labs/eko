import AppKit
import EkoCore
import SwiftUI

/// Settings (PLAN-LIBRARY.md §8). Every control writes where the menu and the `eko` CLI read: the same
/// UserDefaults keys, the Keychain, and the files in ~/Library/Application Support/Eko.
struct SettingsView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @EnvironmentObject private var notes: NotesModel
    @StateObject private var texts = SettingsTexts()
    @AppStorage("notes.minimumSeconds", store: NotesSettings.defaults) private var minimumSeconds = 30.0
    @AppStorage("notes.transcribeModel", store: NotesSettings.defaults) private var transcribeModel = NotesSettings.defaultModel
    @AppStorage("notes.summaryModel", store: NotesSettings.defaults) private var summaryModel = NotesSettings.defaultModel
    @AppStorage("notes.chatModel", store: NotesSettings.defaults) private var chatModel = NotesSettings.defaultChatModel
    @AppStorage("notes.chunkMinutes", store: NotesSettings.defaults) private var chunkMinutes = 40.0
    @State private var keyDraft = ""
    @State private var replacingKey = false
    @State private var keyMessage: String?
    @State private var checkingKey = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            recordingSection
            transcriptsSection
            personaliseSection
            advancedSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .onDisappear { texts.saveNow() }
    }

    // MARK: Recording

    private var recordingSection: some View {
        Section("Recording") {
            LabeledContent("Recordings folder") {
                HStack {
                    Text(recorder.outputDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.secondary)
                    Button("Change…") { recorder.chooseFolder() }.disabled(recorder.isRecording)
                    if !recorder.isDefaultFolder {
                        Button("Reset") { recorder.resetFolder() }.disabled(recorder.isRecording)
                    }
                }
            }
            if recorder.folderSyncsToICloud {
                Label("This folder syncs to iCloud: recordings, transcripts, summaries and chats in it leave this Mac. Choose a folder outside Desktop and Documents to keep them local.",
                      systemImage: "icloud")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            Toggle("Ask to record when a call starts", isOn: $recorder.nudgeOnCall)
            Toggle("Start recording automatically when a call starts", isOn: $recorder.autoStartOnCall)
            Toggle("Stop automatically when the call ends", isOn: $recorder.autoStopOnCallEnd)
            Toggle("Open Eko at login", isOn: $recorder.launchAtLogin)
            LabeledContent("Start or stop recording", value: "⌃⌥⌘R")
        }
    }

    // MARK: Transcripts

    private var transcriptsSection: some View {
        Section {
            Toggle("Transcribe every call automatically", isOn: $notes.auto)
            Stepper(value: $minimumSeconds, in: 0...600, step: 10) {
                LabeledContent("Skip calls shorter than", value: "\(Int(minimumSeconds)) seconds")
            }
            .disabled(!notes.auto)
            keyRows
            if let line = notes.statusLine {
                HStack {
                    Text(line).font(.callout).foregroundStyle(Theme.secondary)
                    Spacer()
                    if notes.failedCount > 0 || notes.keychainRefused { Button("Retry") { notes.retry() } }
                }
            }
        } header: {
            Text("Transcripts and summaries")
        } footer: {
            Text("Each call's audio is sent to Google Gemini to be transcribed, then the transcript text to be summarised.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private var keyRows: some View {
        if let masked = notes.maskedKey, !replacingKey {
            LabeledContent("Gemini API key") {
                HStack {
                    Text(masked.isEmpty ? "Set" : "Set (\(masked))").foregroundStyle(Theme.secondary)
                    Button("Replace…") { replacingKey = true; keyMessage = nil }
                    Button("Remove") { notes.removeKey(); keyMessage = nil }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gemini API key")
                Text("1. Click Get a Key and sign in with your Google account.  2. Click Create API key and copy it.  3. Paste it here and click Save.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                HStack {
                    SecureField("Paste your Gemini API key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Get a Key") { notes.openKeyPage() }
                    Button("Save", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || checkingKey)
                    if notes.maskedKey != nil { Button("Cancel") { replacingKey = false; keyDraft = "" } }
                }
            }
        }
        if checkingKey {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the key with Google…").foregroundStyle(Theme.secondary) }
        } else if let keyMessage {
            Text(keyMessage).font(.callout).foregroundStyle(Theme.secondary)
        }
    }

    private func saveKey() {
        let key = keyDraft
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty, !checkingKey else { return }
        checkingKey = true
        Task {
            let result = await notes.checkAndSave(key)
            checkingKey = false
            keyMessage = result.message
            if result == .saved || result == .savedUnchecked {
                keyDraft = ""
                replacingKey = false
            }
        }
    }

    // MARK: Personalise

    private var personaliseSection: some View {
        Section {
            TextField("Your name", text: $texts.me, prompt: Text("So action items name you"))
            VStack(alignment: .leading, spacing: 6) {
                Text("Names and terms")
                Text("People, companies, products and jargon from your calls, one per line, spelled the way you want them.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                editor($texts.names, height: 120)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Summary prompt")
                    Spacer()
                    Button("Reset to Built-in") { texts.resetPrompt() }.disabled(!texts.promptIsCustom)
                }
                Text("Placeholders: {{title}} {{date}} {{duration}} {{speakers}} {{names}} {{transcript}}")
                    .font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                editor($texts.prompt, height: 220)
                if !texts.prompt.contains("{{transcript}}") {
                    Label("No {{transcript}} placeholder: Eko adds the transcript at the end.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        } header: {
            Text("Personalise")
        } footer: {
            Text("Saved as you type, in ~/Library/Application Support/Eko. Used for new transcripts and summaries.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                modelField("Transcription model", $transcribeModel, NotesSettings.defaultModel)
                modelField("Summary model", $summaryModel, NotesSettings.defaultModel)
                modelField("Chat model", $chatModel, NotesSettings.defaultChatModel)
                Stepper(value: $chunkMinutes, in: 5...60, step: 5) {
                    LabeledContent("Send long calls in pieces of", value: "\(Int(chunkMinutes)) min")
                }
                HStack {
                    Button("Reset to Defaults") {
                        for key in ["notes.transcribeModel", "notes.summaryModel", "notes.chatModel", "notes.chunkMinutes",
                                    "notes.minimumSeconds"] {
                            NotesSettings.defaults.removeObject(forKey: key)
                        }
                        transcribeModel = NotesSettings.defaultModel
                        summaryModel = NotesSettings.defaultModel
                        chatModel = NotesSettings.defaultChatModel
                        chunkMinutes = 40
                        minimumSeconds = 30
                    }
                    Spacer()
                    Button("Open Log") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Eko.log")) }
                }
            }
        }
    }

    private func modelField(_ title: String, _ value: Binding<String>, _ fallback: String) -> some View {
        TextField(title, text: Binding(get: { value.wrappedValue },
                                       set: { value.wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : $0.trimmingCharacters(in: .whitespaces) }),
                  prompt: Text(fallback))
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Updater.currentVersion)
            if let updater = Updater.current {
                UpdateRows(updater: updater)
            }
        }
    }
}

private struct UpdateRows: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Toggle("Check for updates daily", isOn: $updater.automaticChecks).disabled(!updater.isConfigured)
        HStack {
            if let release = updater.available {
                Text("Eko \(release.version) is available").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Update…") { updater.showAvailable() }.disabled(updater.phase != .idle)
            } else {
                Text(updater.phaseText ?? "").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Check for Updates") { Task { await updater.check(manual: true) } }
                    .disabled(updater.phase != .idle || !updater.isConfigured)
            }
        }
    }
}

/// names.txt (split into "Your name" and the list) and summary-prompt.txt, saved shortly after each change.
@MainActor
final class SettingsTexts: ObservableObject {
    @Published var me = "" { didSet { if loaded { scheduleSave() } } }
    @Published var names = "" { didSet { if loaded { scheduleSave() } } }
    @Published var prompt = "" { didSet { if loaded { scheduleSave() } } }
    @Published private(set) var promptIsCustom = false
    private var loaded = false
    private var pending: Task<Void, Never>?
    private var savedPrompt = ""

    init() {
        let namesText = (try? String(contentsOf: NotesSettings.namesFile, encoding: .utf8)) ?? NotesSettings.namesFileTemplate
        (me, names) = NamesList.splitMe(namesText)
        let template = SummaryPrompt.loadTemplate()
        promptIsCustom = template.source != "built-in default"
        prompt = promptIsCustom ? ((try? String(contentsOf: NotesSettings.summaryPromptFile, encoding: .utf8)) ?? template.template)
                                : SummaryPrompt.defaultTemplate
        savedPrompt = prompt
        loaded = true
    }

    private func scheduleSave() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        pending?.cancel()
        pending = nil
        do {
            try NotesSettings.ensureSupportDirectory()
            let namesText = NamesList.joinMe(me, names)
            let current = (try? String(contentsOf: NotesSettings.namesFile, encoding: .utf8))
            if current != namesText, !(current == nil && namesText == NotesSettings.namesFileTemplate) {
                try OutputFile.write(namesText, to: NotesSettings.namesFile, overwrite: true)
            }
            // The prompt file is written only once the user changes it, so the built-in prompt keeps improving.
            if prompt != savedPrompt {
                try OutputFile.write(prompt, to: NotesSettings.summaryPromptFile, overwrite: true)
                savedPrompt = prompt
                promptIsCustom = true
            }
        } catch {
            RecordingSession.dlog("settings: could not save: \(error.localizedDescription)")
        }
    }

    /// The custom prompt file goes to the Trash (recoverable); the built-in prompt is used again.
    func resetPrompt() {
        pending?.cancel()
        try? FileManager.default.trashItem(at: NotesSettings.summaryPromptFile, resultingItemURL: nil)
        loaded = false
        prompt = SummaryPrompt.defaultTemplate
        savedPrompt = prompt
        promptIsCustom = false
        loaded = true
    }
}
