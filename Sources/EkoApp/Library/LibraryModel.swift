import AppKit
import Combine
import EkoCore
import Foundation

/// State of the Library window: the recordings in the folder (re-read when files change), filters, and what is open.
@MainActor
final class LibraryModel: ObservableObject {
    enum Section: Hashable { case recordings, settings }
    enum Tab: String, CaseIterable { case transcript = "Transcript", summary = "Summary", chat = "Chat" }

    @Published var section: Section = .recordings
    @Published private(set) var items: [RecordingItem] = []
    @Published var filter = LibraryFilter.saved() {
        didSet {
            filter.save()
            if filter.text != oldValue.text { loadTranscriptsIfSearching() }
        }
    }
    enum Sort: String, CaseIterable {
        case newest = "Newest first", oldest = "Oldest first", longest = "Longest first", largest = "Largest first"
    }
    @Published var sort = Sort(rawValue: UserDefaults.standard.string(forKey: "library.sort") ?? "") ?? .newest {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "library.sort") }
    }
    @Published var selection = Set<RecordingItem.ID>()
    /// The recording shown in the detail view (by path), nil for the grid.
    @Published var openedID: String?
    @Published var tab: Tab = .summary
    /// One player shared by every row in the list, so starting one call stops the other.
    let listPlayer = Player()
    /// Transcript text by recording id, loaded only while a search is typed.
    private var transcripts: [String: String] = [:]
    private var durations: [String: TimeInterval] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var reloadScheduled = false
    private var observers: Set<AnyCancellable> = []
    private(set) var isActive = false

    var recorder: RecorderModel? { RecorderModel.current }
    var folder: URL { recorder?.outputDirectory ?? RecordingOptions.defaultDirectory }
    var opened: RecordingItem? { openedID.flatMap { id in items.first { $0.id == id } } }

    /// Called when the window opens: read the folder and keep watching it.
    func start() {
        guard !isActive else { reload(); return }
        isActive = true
        recorder?.$outputDirectory.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.openedID = nil; self?.selection = []; self?.reload() }
        }.store(in: &observers)
        recorder?.$isRecording.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &observers)
        reload()
    }

    /// Called when the window closes.
    func stop() {
        isActive = false
        observers = []
        watcher?.cancel()
        watcher = nil
        watchedFolder = nil
        openedID = nil
        transcripts = [:]
        listPlayer.stop()
    }

    func reload() {
        guard isActive else { return }
        let folder = folder
        if watchedFolder != folder { watch(folder) }
        let hideUnfinished = recorder?.isRecording ?? false
        Task {
            var scanned = await Task.detached(priority: .userInitiated) { Library.scan(folder, hideUnfinished: hideUnfinished) }.value
            for i in scanned.indices where scanned[i].duration == nil {
                scanned[i].duration = durations[scanned[i].id]
            }
            items = scanned
            selection = selection.filter { id in scanned.contains { $0.id == id } }
            if let openedID, !scanned.contains(where: { $0.id == openedID }) { self.openedID = nil }   // gone (moved or deleted)
            loadMissingDurations()
            loadTranscriptsIfSearching()
        }
    }

    func visible(jobs: [String: JobStatus]) -> [RecordingItem] {
        let rows = filter.apply(items, jobs: jobs, transcripts: transcripts, minimumSeconds: NotesSettings.load().minimumSeconds)
        switch sort {
        case .newest: return rows.sorted { $0.date > $1.date }
        case .oldest: return rows.sorted { $0.date < $1.date }
        case .longest: return rows.sorted { $0.length > $1.length }
        case .largest: return rows.sorted { $0.size > $1.size }
        }
    }

    var apps: [String] { Array(Set(items.flatMap(\.apps))).sorted() }

    func open(_ id: RecordingItem.ID) {
        tab = items.first { $0.id == id }?.hasSummary == true ? .summary : .transcript   // summary first when there is one
        openedID = id
        section = .recordings
    }

    // MARK: Actions

    func transcribe(_ ids: Set<RecordingItem.ID>) {
        NotesModel.current?.transcribe(urls(ids))
    }

    func moveToTrash(_ ids: Set<RecordingItem.ID>) {
        let targets = urls(ids)
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        if targets.count == 1 {
            alert.messageText = "Move “\(targets[0].deletingPathExtension().lastPathComponent)” to the Trash?"
            alert.informativeText = "Its transcript, summary and chat go too. You can put them back from the Trash."
        } else {
            alert.messageText = "Move \(targets.count) recordings to the Trash?"
            alert.informativeText = "Their transcripts, summaries and chats go too. You can put them back from the Trash."
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let playing = listPlayer.loaded, targets.contains(playing) { listPlayer.stop() }
        var failures: [String] = []
        for url in targets {
            NotesModel.current?.cancel(url)
            do {
                try Library.moveToTrash(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        RecordingSession.dlog("library: moved \(targets.count - failures.count) recording(s) to the Trash")
        if let openedID, ids.contains(openedID) { self.openedID = nil }
        selection.subtract(ids)
        reload()
        if !failures.isEmpty {
            let error = NSAlert()
            error.messageText = "Some files could not be moved to the Trash"
            error.informativeText = failures.joined(separator: "\n")
            error.runModal()
        }
    }

    func reveal(_ ids: Set<RecordingItem.ID>) {
        NSWorkspace.shared.activateFileViewerSelecting(urls(ids))
    }

    private func urls(_ ids: Set<RecordingItem.ID>) -> [URL] {
        items.filter { ids.contains($0.id) }.sorted { $0.date > $1.date }.map(\.url)
    }

    // MARK: Background work

    private func watch(_ folder: URL) {
        watcher?.cancel()
        watcher = nil
        watchedFolder = folder
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }   // folder missing: shown as empty; re-checked on the next reload
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Files appear in bursts (temp file, rename, sidecar): wait a moment, then read the folder once.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private func loadMissingDurations() {
        let missing = items.filter { $0.duration == nil }.map(\.url)
        guard !missing.isEmpty else { return }
        Task {
            for url in missing {
                guard let d = await Library.loadDuration(url) else { continue }
                durations[url.path] = d
                if let i = items.firstIndex(where: { $0.id == url.path }) { items[i].duration = d }
            }
        }
    }

    private func loadTranscriptsIfSearching() {
        guard !filter.text.trimmingCharacters(in: .whitespaces).isEmpty else { transcripts = [:]; return }
        let wanted = items.filter(\.hasTranscript).map { ($0.id, $0.transcriptURL) }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                var texts: [String: String] = [:]
                for (id, url) in wanted { texts[id] = try? String(contentsOf: url, encoding: .utf8) }
                return texts
            }.value
            transcripts = loaded
            objectWillChange.send()
        }
    }
}

extension LibraryFilter {
    /// Filters are remembered between openings; the search text is not.
    static func saved() -> LibraryFilter {
        guard let data = UserDefaults.standard.data(forKey: "library.filter"),
              var f = try? JSONDecoder().decode(LibraryFilter.self, from: data) else { return LibraryFilter() }
        f.text = ""
        return f
    }

    func save() {
        var copy = self
        copy.text = ""
        if let data = try? JSONEncoder().encode(copy) { UserDefaults.standard.set(data, forKey: "library.filter") }
    }
}
