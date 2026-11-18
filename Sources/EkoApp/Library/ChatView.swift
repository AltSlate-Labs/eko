import EkoCore
import SwiftUI

/// Questions about one call, answered from its transcript only (PLAN-LIBRARY.md §6). History is kept in
/// `<name>-chat.json` next to the recording.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    /// The question being answered, or the last one that failed (shown with the error and Retry).
    @Published private(set) var pending: String?
    @Published private(set) var isAsking = false
    @Published private(set) var error: String?
    @Published private(set) var needsKey = false
    @Published private(set) var transcriptChanged = false

    let item: RecordingItem
    private var segments: [Segment] = []
    private var system = ""
    private var log: ChatLog

    init(item: RecordingItem) {
        self.item = item
        let modified = (try? item.transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        log = CallChat.load(for: item.url) ?? ChatLog(model: NotesSettings.load().chatModel, transcriptModified: modified)
        messages = log.messages
        if let then = log.transcriptModified, let modified, modified.timeIntervalSince(then) > 1, !messages.isEmpty {
            transcriptChanged = true
        }
    }

    private func prepare() -> Bool {
        guard system.isEmpty else { return true }
        guard let text = try? String(contentsOf: item.transcriptURL, encoding: .utf8) else { return false }
        segments = TranscriptText.parseFile(text)
        let info = RecordingInfo.read(item.url)
        system = CallChat.systemInstruction(title: item.name, date: info.dateText, duration: item.duration ?? segments.last?.start ?? 0,
                                            names: NamesList.load(), segments: segments,
                                            participants: Participants.load(for: item.url))
        return !segments.isEmpty
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        pending = q
        error = nil
        needsKey = false
        guard let key = NotesModel.current?.apiKey() else {
            needsKey = true
            error = NotesModel.current?.keychainRefused == true
                ? "Eko couldn't read the Gemini key from the Keychain. Click Retry in Settings and choose Always Allow."
                : "Set a Gemini key in Settings to ask questions."
            return
        }
        guard prepare() else {
            error = "The transcript could not be read."
            return
        }
        isAsking = true
        let model = NotesSettings.load().chatModel
        Task {
            defer { isAsking = false }
            do {
                let answer = try await CallChat.ask(q, history: messages, system: system, segments: segments,
                                                    client: GeminiClient(key: key), model: model)
                messages += [ChatMessage(role: .user, text: q), answer]
                pending = nil
                save(model: model)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func retry() { if let pending { ask(pending) } }

    func clear() {
        messages = []
        pending = nil
        error = nil
        transcriptChanged = false
        try? FileManager.default.trashItem(at: OutputFile.chatURL(for: item.url), resultingItemURL: nil)
        log = ChatLog(model: NotesSettings.load().chatModel,
                      transcriptModified: (try? item.transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }

    private func save(model: String) {
        log.messages = messages
        log.model = model
        do { try CallChat.save(log, for: item.url) } catch {
            RecordingSession.dlog("chat: could not save history: \(error.localizedDescription)")
        }
    }
}

struct ChatView: View {
    @StateObject private var chat: ChatSession
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(item: RecordingItem) {
        _chat = StateObject(wrappedValue: ChatSession(item: item))
    }

    static let starters = ["What did we decide?", "What do I need to do, and by when?",
                           "What did the others ask for?", "What is still open?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chat.transcriptChanged {
                            Label("The transcript changed after this chat, so older answers may cite old times.", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        if chat.messages.isEmpty && chat.pending == nil { starters }
                        ForEach(chat.messages) { message in
                            Bubble(message: message).id(message.id)
                        }
                        if let pending = chat.pending {
                            Bubble(message: ChatMessage(role: .user, text: pending))
                            if chat.isAsking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Reading the transcript…").foregroundStyle(Theme.secondary)
                                }
                            } else if let error = chat.error {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    Text(error).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                    if chat.needsKey {
                                        Button("Open Settings") { library.section = .settings }.controlSize(.small)
                                    } else {
                                        Button("Retry") { chat.retry() }.controlSize(.small)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.count) { withAnimation { proxy.scrollTo("end") } }
                .onChange(of: chat.pending) { withAnimation { proxy.scrollTo("end") } }
            }
            .seekLinks(player)
            input
        }
        .onAppear { UICheck.chat = chat }
        .toolbar {
            if !chat.messages.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button { chat.clear() } label: { Label("Clear Chat", systemImage: "trash") }
                        .help("Clear this chat (the history file goes to the Trash)")
                }
            }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about this call")
                .font(.title3.weight(.semibold))
            Text("Answers come only from this call's transcript, with times you can click to listen.")
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.starters, id: \.self) { q in
                    Button { chat.ask(q) } label: {
                        Text(q)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(.primary)
                            .background(Capsule().strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 12)
    }

    private var input: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this call…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.system(size: 14))
                    .frame(minHeight: 26, alignment: .center)   // one line sits mid-height, level with the send button
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .frame(height: 26)
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            Text("Sends this call's transcript text and your question to Gemini. No audio is sent.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }

    private var canSend: Bool { !chat.isAsking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        chat.ask(draft)
        draft = ""
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.13)))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(timeLinked(message.text))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                if let cited = message.cited, let matched = message.matched, matched < cited {
                    Label("\(cited - matched) of \(cited) cited times match no transcript line", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.trailing, 60)
        }
    }
}
