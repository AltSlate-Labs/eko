import EkoCore
import SwiftUI

/// All recordings, grouped by day, with status chips, search, filters and multi-select (PLAN-LIBRARY.md §4).
struct RecordingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var notes: NotesModel
    @State private var width: CGFloat = 1000

    var body: some View {
        let rows = library.visible(jobs: notes.jobStates)
        VStack(spacing: 0) {
            RecordingNowBar()
            chips
            if rows.isEmpty {
                empty.frame(maxHeight: .infinity)
            } else {
                list(rows)
            }
        }
        .overlay(alignment: .bottom) { selectionBar }
        .environmentObject(library.listPlayer)
        .onDisappear { library.listPlayer.stop() }   // opening a call, Settings, or closing the window
        .navigationTitle("Recordings")
        .navigationSubtitle(summary(rows))
        .searchable(text: $library.filter.text, placement: .toolbar, prompt: "Search calls and transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sortMenu
                moreFilters
            }
        }
    }

    // MARK: List

    private func list(_ rows: [RecordingItem]) -> some View {
        List(selection: $library.selection) {
            ForEach(groups(rows), id: \.title) { group in
                Section {
                    ForEach(group.items) { item in
                        RecordingRow(item: item, job: notes.jobStates[item.id], short: isShort(item), width: width)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(group.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                }
            }
            Color.clear.frame(height: library.selection.count > 1 ? 56 : 8).listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { library.open(id) }
        }
        .onDeleteCommand { library.moveToTrash(library.selection) }
    }

    private struct Group { var title: String; var detail: String; var items: [RecordingItem] }

    /// By day when sorted by date; one plain group otherwise.
    private func groups(_ rows: [RecordingItem]) -> [Group] {
        guard library.sort == .newest || library.sort == .oldest else {
            return [Group(title: library.sort.rawValue, detail: "", items: rows)]
        }
        var out: [Group] = []
        let cal = Calendar.current
        for item in rows {
            let title = Self.dayTitle(item.date, cal)
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append(Group(title: title, detail: "", items: [item])) }
        }
        for i in out.indices {
            let n = out[i].items.count
            out[i].detail = "\(n) call\(n == 1 ? "" : "s") · \(Self.hours(out[i].items.compactMap(\.duration).reduce(0, +)))"
        }
        return out
    }

    static func dayTitle(_ date: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func isShort(_ item: RecordingItem) -> Bool {
        (item.duration ?? 60) < NotesSettings.load().minimumSeconds
    }

    // MARK: Chips and menus

    private var chips: some View {
        HStack(spacing: 6) {
            chip("All", .any)
            chip("To transcribe", .notTranscribed)
            chip("Transcribed", .transcribed)
            chip("Summarised", .summarised)
            if notes.jobStates.values.contains(where: { if case .failed = $0 { return true }; return false }) {
                chip("Failed", .failed)
            }
            Spacer()
            if library.filter.period != .all || !library.filter.app.isEmpty || library.filter.hideShort {
                Button("Clear filters") {
                    let text = library.filter.text
                    library.filter = LibraryFilter()
                    library.filter.text = text
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func chip(_ title: String, _ status: LibraryFilter.Status) -> some View {
        let on = library.filter.status == status
        return Button { library.filter.status = status } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(on ? Color.primary : Theme.secondary)
                .background(Capsule().fill(on ? Color.primary.opacity(0.1) : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $library.sort) {
                ForEach(LibraryModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort")
    }

    private var moreFilters: some View {
        let active = library.filter.period != .all || !library.filter.app.isEmpty || library.filter.hideShort
        return Menu {
            Section("Date") {
                Picker("Date", selection: $library.filter.period) {
                    ForEach(LibraryFilter.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Section("App") {
                Picker("App", selection: $library.filter.app) {
                    Text("Any app").tag("")
                    ForEach(library.apps, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Divider()
            Toggle("Hide Calls Under \(Int(NotesSettings.load().minimumSeconds)) Seconds", isOn: $library.filter.hideShort)
        } label: {
            Label("Filter", systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter by date and app")
    }

    @ViewBuilder
    private func menu(_ ids: Set<RecordingItem.ID>) -> some View {
        let chosen = library.items.filter { ids.contains($0.id) }
        if chosen.count == 1, let item = chosen.first {
            Button("Open") { library.open(item.id) }
            Divider()
            Button(item.hasTranscript ? "Transcribe Again…" : "Transcribe") { notes.transcribe(item.url) }
            Button("Summarise Again…") { notes.summarise(item.url) }.disabled(!item.hasTranscript)
        } else if !chosen.isEmpty {
            Button("Transcribe \(chosen.count) Recordings") { library.transcribe(ids) }
        }
        if !chosen.isEmpty {
            Divider()
            Button("Show in Finder") { library.reveal(ids) }
            Divider()
            Button("Move to Trash…", role: .destructive) { library.moveToTrash(ids) }
        }
    }

    // MARK: Bits

    @ViewBuilder
    private var selectionBar: some View {
        if library.selection.count > 1 {
            HStack(spacing: 14) {
                Text("\(library.selection.count) selected").font(.system(size: 12, weight: .medium))
                Divider().frame(height: 14)
                Button("Transcribe") { library.transcribe(library.selection) }
                Button("Show in Finder") { library.reveal(library.selection) }
                Button("Move to Trash…") { library.moveToTrash(library.selection) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var empty: some View {
        if library.items.isEmpty {
            ContentUnavailableView("No recordings yet", systemImage: "waveform",
                                   description: Text("Calls you record appear here, with their transcripts and summaries."))
        } else {
            ContentUnavailableView {
                Label("Nothing matches", systemImage: "magnifyingglass")
            } description: {
                Text("Try other words or filters.")
            } actions: {
                Button("Show all recordings") { library.filter = LibraryFilter() }
            }
        }
    }

    private func summary(_ rows: [RecordingItem]) -> String {
        let total = rows.compactMap(\.duration).reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: rows.reduce(Int64(0)) { $0 + $1.size }, countStyle: .file)
        let count = rows.count == library.items.count ? "\(rows.count) calls" : "\(rows.count) of \(library.items.count) calls"
        return "\(count) · \(Self.hours(total)) · \(size)"
    }

    static func hours(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// One call: glyph, title and time, file name, player, length, size, transcript and summary marks.
/// As the window narrows the name column shrinks, then the size goes, then the waveform (the play button stays).
struct RecordingRow: View {
    let item: RecordingItem
    let job: JobStatus?
    let short: Bool
    var width: CGFloat = 1000

    var body: some View {
        HStack(spacing: 12) {
            AppGlyph(symbol: item.glyph)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold))
                    Text(item.date, format: .dateTime.hour().minute())
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                Text(item.fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: width >= 900 ? 230 : 175, alignment: .leading)
            RowPlayer(item: item, waveform: width >= 600)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
            Text(item.duration.map(Timestamp.short) ?? "—")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            if width >= 740 {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
            HStack(spacing: 6) {
                StatusChip(label: "Transcript", done: item.hasTranscript, job: job, symbol: "quote.opening")
                StatusChip(label: "Summary", done: item.hasSummary, job: item.hasTranscript ? job : nil, symbol: "text.alignleft")
            }
            .padding(.leading, 4)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .opacity(short ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A one-line player in the row: play/pause and the call's outline. The list shares one Player, so starting
/// a call pauses the one that was playing. Clicking the outline of another call starts it from there.
struct RowPlayer: View {
    let item: RecordingItem
    var waveform = true
    @EnvironmentObject private var player: Player
    @State private var scrub: Double?

    var body: some View {
        let active = player.loaded == item.url
        HStack(spacing: 10) {
            Button { Task { await player.toggle(item) } } label: {
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(active ? Color.white : Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(active ? Theme.accent : Theme.accent.opacity(0.13)))
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(active && player.isPlaying ? "Pause" : "Play")
            WaveformScrubber(levels: active ? player.levels : [], progress: active ? progress : 0) { fraction, done in
                if !active {
                    if done { Task { await player.toggle(item, at: fraction) } }
                } else if done {
                    player.seek(to: fraction * player.duration, play: true)
                    scrub = nil
                } else {
                    scrub = fraction * player.duration
                }
            }
            .frame(height: 22)
            .opacity(waveform ? 1 : 0)
            .frame(maxWidth: waveform ? .infinity : 0)
            if active {
                Text(Timestamp.short(scrub ?? player.time))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(scrub == nil ? Theme.secondary : Theme.accent)
                    .frame(width: 48, alignment: .leading)
            }
        }
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, (scrub ?? player.time) / player.duration)
    }
}

/// A slim bar while a call is being recorded (that file is listed once it is saved).
struct RecordingNowBar: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        if recorder.isRecording {
            HStack(spacing: 10) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                Text("Recording").font(.system(size: 12, weight: .semibold))
                Text(recorder.elapsedText).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Stop") { recorder.stop() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Theme.accent.opacity(0.08))
        }
    }
}
