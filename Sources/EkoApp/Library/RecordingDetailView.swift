import AppKit
import EkoCore
import SwiftUI

/// One recording: player on top, then Transcript · Summary · Chat (PLAN-LIBRARY.md §5).
struct RecordingDetailView: View {
    let item: RecordingItem
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var notes: NotesModel
    @EnvironmentObject private var recorder: RecorderModel
    @StateObject private var player = Player()
    @StateObject private var files = RecordingFiles()
    @AppStorage("library.fontSize") private var fontSize = 14.0
    @AppStorage("library.follow") private var follow = true
    @State private var findRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            PlayerBar()
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            DetailTabBar(tab: $library.tab)
            Group {
                switch library.tab {
                case .transcript: transcriptTab
                case .summary: summaryTab
                case .chat: chatTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // keeps the player at the top for short content
        }
        .navigationTitle("")
        .toolbar { toolbar }
        .environmentObject(player)
        .task(id: item.url) { await player.load(item) }
        .onAppear {
            files.load(item)
            UICheck.player = player
        }
        .onChange(of: item) { files.load(item) }   // the folder changed (a transcript or summary was written)
        .onDisappear { player.stop() }
        .background { tabShortcuts }
    }

    private var subtitle: String {
        var parts = item.summaryTitle == nil ? [] : [item.title]   // the heading is the summary's title: say which app
        parts += [item.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()),
                     item.date.formatted(.dateTime.hour().minute())]
        if let d = item.duration { parts.append(Timestamp.short(d)) }
        parts.append(RecordingItem.megabytes(item.size))
        return parts.joined(separator: "  ·  ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppGlyph(symbol: item.glyph, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.heading).font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text(item.fileName).font(.system(size: 11)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                ParticipantsRow(item: item, files: files).padding(.top, 4)
            }
            Spacer()
            if case let .running(text) = job {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("Cancel") { notes.cancel(item.url) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    StatusChip(label: "Transcript", done: item.hasTranscript, job: job)
                    StatusChip(label: "Summary", done: item.hasSummary, job: item.hasTranscript ? job : nil)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var job: JobStatus? { notes.jobStates[item.id] }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { library.openedID = nil } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("All Recordings").font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Theme.accent)
                .background(Capsule().fill(Theme.accent.opacity(0.13)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Back to all recordings (⌘[)")
                .keyboardShortcut("[", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(item.hasTranscript ? "Transcribe Again…" : "Transcribe") { notes.transcribe(item.url) }
                Button("Summarise Again…") { notes.summarise(item.url) }.disabled(!item.hasTranscript)
                Divider()
                Button("Copy Transcript") { copy(files.transcriptText) }.disabled(files.transcriptText == nil)
                Button("Copy Summary") { copy(files.summary?.body) }.disabled(files.summary == nil)
                Button("Copy Summary as Markdown") { copy(files.summary?.markdown) }.disabled(files.summary == nil)
                Divider()
                Button("Show in Finder") { library.reveal([item.id]) }
                Button("Open Transcript in TextEdit") { openInTextEdit(item.transcriptURL) }.disabled(!item.hasTranscript)
                Button("Open Summary in TextEdit") { openInTextEdit(item.summaryURL) }.disabled(!item.hasSummary)
                Divider()
                Button("Move to Trash…", role: .destructive) { library.moveToTrash([item.id]) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Transcribe, copy, show in Finder, move to Trash")
        }
    }

    /// ⌘1 ⌘2 ⌘3 switch tabs.
    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(LibraryModel.Tab.allCases.enumerated()), id: \.offset) { i, tab in
                Button("") { library.tab = tab }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Tabs

    @ViewBuilder
    private var transcriptTab: some View {
        if let segments = files.segments, !segments.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text(files.transcriptInfo).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Toggle(isOn: $follow) { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                        .toggleStyle(.button).help("Follow playback")
                    ControlGroup {
                        Button { fontSize = max(11, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text")
                        Button { fontSize = min(24, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.help("Larger text")
                    }
                    .fixedSize()
                    Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass") }.help("Find in transcript (⌘F)")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                TranscriptTextView(segments: segments, fontSize: fontSize, current: player.started ? player.time : nil,
                                   follow: follow && player.isPlaying, findRequest: findRequest) { player.seek(to: $0) }
            }
        } else {
            missing(what: "transcript")
        }
    }

    @ViewBuilder
    private var summaryTab: some View {
        if let summary = files.summary {
            SummaryView(document: summary)
        } else {
            missing(what: "summary")
        }
    }

    @ViewBuilder
    private var chatTab: some View {
        if item.hasTranscript {
            ChatView(item: item).id(item.id)
        } else {
            missing(what: "chat")
        }
    }

    /// No transcript or summary yet: what is happening, or what the user can do.
    @ViewBuilder
    private func missing(what: String) -> some View {
        switch job {
        case let .running(text):
            ContentUnavailableView { Label(text, systemImage: "waveform") } description: {
                Text("This takes about a minute for a 40-minute call.")
            } actions: {
                ProgressView()
            }
        case let .waiting(error):
            ContentUnavailableView {
                Label("Waiting to transcribe", systemImage: "clock")
            } description: {
                Text(error ?? notes.statusLine ?? "It will start shortly.")
            }
        case let .failed(error):
            ContentUnavailableView {
                Label("Transcript failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { notes.retry() }
            }
        case nil:
            if what == "summary", item.hasTranscript {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "text.alignleft")
                } description: {
                    Text("Make one from the transcript. No audio is sent.")
                } actions: {
                    Button("Summarise") { notes.summarise(item.url) }
                }
            } else {
                ContentUnavailableView {
                    Label("Not transcribed yet", systemImage: "quote.opening")
                } description: {
                    Text(what == "chat" ? "Transcribe this call to ask questions about it." : "Get a transcript and a summary from Gemini.")
                } actions: {
                    Button("Transcribe") { notes.transcribe(item.url) }
                }
            }
        }
    }

    // MARK: Helpers

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openInTextEdit(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The transcript and summary files of the open recording, read when it opens and when they change.
@MainActor
final class RecordingFiles: ObservableObject {
    @Published private(set) var segments: [Segment]?
    @Published private(set) var transcriptText: String?
    @Published private(set) var transcriptInfo = ""
    @Published private(set) var summary: SummaryDocument?
    /// The user's list of who was on the call (nil until they edit it; then Gemini's suggestion is not shown).
    @Published private(set) var participants: [Participant]?
    private var stamps: (Date?, Date?, Date?) = (nil, nil, nil)

    func load(_ item: RecordingItem, force: Bool = false) {
        let t = Self.modified(item.transcriptURL), s = Self.modified(item.summaryURL), p = Self.modified(Participants.url(for: item.url))
        guard force || segments == nil && summary == nil || stamps != (t, s, p) else { return }
        stamps = (t, s, p)
        participants = Participants.load(for: item.url)
        transcriptText = try? String(contentsOf: item.transcriptURL, encoding: .utf8)
        segments = transcriptText.map(TranscriptText.parseFile)
        transcriptInfo = transcriptText.map(Self.info) ?? ""
        summary = (try? String(contentsOf: item.summaryURL, encoding: .utf8)).map(SummaryDocument.parse)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// "Gemini gemini-3.6-flash · script OK · 3 echo lines removed", from the transcript header.
    static func info(_ text: String) -> String {
        var engine = "", checks = ""
        for line in text.split(separator: "\n", maxSplits: 12).prefix(10) {
            if line.hasPrefix("Speech-to-text: ") {
                engine = String(line.dropFirst("Speech-to-text: ".count)).components(separatedBy: " (").first ?? ""
            }
            if line.hasPrefix("Checks: ") { checks = String(line.dropFirst("Checks: ".count)) }
            if line.hasPrefix("---") { break }
        }
        return [engine, checks].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Transcript · Summary · Chat as three equal tabs across the page, under the player.
private struct DetailTabBar: View {
    @Binding var tab: LibraryModel.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(LibraryModel.Tab.allCases.enumerated()), id: \.offset) { i, t in
                let on = t == tab
                Button { tab = t } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            Image(systemName: Self.symbol(t)).font(.system(size: 13, weight: .semibold))
                            Text(t.rawValue).font(.system(size: 14, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? Theme.accent : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(on ? Theme.accent.opacity(0.08) : Color.clear)
                        Rectangle().fill(on ? Theme.accent : Color.clear).frame(height: 2.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(t.rawValue) (⌘\(i + 1))")
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: tab)
    }

    static func symbol(_ t: LibraryModel.Tab) -> String {
        switch t {
        case .transcript: return "quote.opening"
        case .summary: return "text.alignleft"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

/// Who was on the call: the user's list if they made one, else the names Gemini heard in the call. "Edit" turns it
/// into a field with one person per line; saving an empty list goes back to the suggestions.
private struct ParticipantsRow: View {
    let item: RecordingItem
    @ObservedObject var files: RecordingFiles
    @EnvironmentObject private var player: Player
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var suggested: [Participant] { files.summary?.participants ?? [] }
    private var people: [Participant] { files.participants ?? suggested }

    var body: some View {
        if editing { editor } else { row }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "person.2").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                .help("Participants")
            if people.isEmpty {
                Text(item.hasSummary ? "No names heard in the call" : "Participants not known yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else {
                ForEach(people.prefix(6), id: \.self) { person in chip(person) }
                if people.count > 6 {
                    Text("+\(people.count - 6) more").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .help(people.dropFirst(6).map(\.line).joined(separator: ", "))
                }
                if files.participants == nil {
                    Text("from the call").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .help("Names Gemini heard in the call. Edit to correct them.")
                }
            }
            Button(people.isEmpty ? "Add" : "Edit") { start() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 4)
        }
        .lineLimit(1)
    }

    private func chip(_ person: Participant) -> some View {
        let label = HStack(spacing: 4) {
            Text(person.name).font(.system(size: 12, weight: .medium))
            if let role = person.role { Text(role).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        return Group {
            if let t = person.time {
                Button { player.seek(to: t, play: true) } label: { label }
                    .buttonStyle(.plain)
                    .help("\(person.name) is named at \(Timestamp.short(t)): click to play from there")
            } else {
                label
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One person per line, with a role in brackets if you like: Rahul (Devsur)")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            TextField("Rahul (Devsur)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...8)
                .focused($focused)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Save") { save() }.keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                if files.participants != nil, !suggested.isEmpty {
                    Button("Use names from the call") { draft = ""; save() }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            Text("Used by the next Summarise Again and by Chat.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private func start() {
        draft = people.map(\.line).joined(separator: "\n")
        error = nil
        editing = true
        focused = true
    }

    private func save() {
        do {
            try Participants.save(Participants.parse(draft), for: item.url)
            files.load(item, force: true)
            editing = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
