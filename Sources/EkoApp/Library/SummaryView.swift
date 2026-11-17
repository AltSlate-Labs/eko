import AppKit
import EkoCore
import SwiftUI

/// Text with every `[hh:mm:ss]` turned into a link that plays from there (handled by `seekLinks`).
func timeLinked(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    for match in Timestamp.find(in: text) {
        guard let r = Range(match.range, in: text), let ar = Range(r, in: out) else { continue }
        out[ar].link = URL(string: "eko-seek:\(match.seconds)")
        out[ar].foregroundColor = Theme.secondary
        out[ar].font = .body.monospacedDigit()
    }
    return out
}

extension View {
    /// Routes Eko's time links to the player; any other link is ignored (model output is never trusted as a URL).
    func seekLinks(_ player: Player) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if url.scheme == "eko-seek", let t = Double(url.absoluteString.dropFirst("eko-seek:".count)) {
                player.seek(to: t)
            }
            return .handled
        })
    }
}

/// The summary as sections (PLAN-LIBRARY.md §5.5); plain text when a custom prompt produced another format.
struct SummaryView: View {
    let document: SummaryDocument
    @EnvironmentObject private var player: Player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if document.isStructured {
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        SummarySection(section: section)
                    }
                } else {
                    Text(timeLinked(document.body)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                }
                footer
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .seekLinks(player)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            Text("Made by \(document.producer ?? "Gemini"). Check it against the transcript.")
            if let check = document.check { Text(check) }
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
    }
}

private struct SummarySection: View {
    let section: SummaryDocument.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.title.isEmpty {
                Label(section.title.uppercased(), systemImage: icon)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.accent)
            }
            if section.items == ["None stated."] {
                Text("None stated.").font(.system(size: 14)).foregroundStyle(Theme.tertiary)
            } else if section.title == "Summary" {
                let (text, times) = TimeLinks.split(section.items.joined(separator: " "))
                Text(text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                if !times.isEmpty {
                    HStack(spacing: 10) { ForEach(Array(times.enumerated()), id: \.offset) { TimeLink(seconds: $1) } }
                }
            } else if section.title == "Action Items" {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, line in
                    let item = SummaryDocument.actionItem(line)
                    SummaryItem(line: item.task) {
                        if item.owner != nil || item.due != nil {
                            HStack(spacing: 12) {
                                if let owner = item.owner { Label(owner, systemImage: "person") }
                                if let due = item.due { Label(due, systemImage: "calendar") }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .labelStyle(.titleAndIcon)
                        }
                    }
                }
            } else if section.isList {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, line in SummaryItem(line: line) { EmptyView() } }
            } else {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, line in
                    Text(timeLinked(line)).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
            }
        }
    }

    private var icon: String {
        switch section.title {
        case "Summary": return "text.alignleft"
        case "Decisions": return "checkmark.seal"
        case "Action Items": return "checklist"
        case "Open Questions": return "questionmark.bubble"
        case "Follow-ups": return "arrow.turn.down.right"
        default: return "doc.text"
        }
    }
}

/// One point: the same accent bullet in every section, the text, and its times as links at the right.
private struct SummaryItem<Detail: View>: View {
    let line: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        let (text, times) = TimeLinks.split(line)
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 }
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { ForEach(Array(times.enumerated()), id: \.offset) { TimeLink(seconds: $1) } }
        }
    }
}

enum TimeLinks {
    /// The text without its `[hh:mm:ss]` marks (and the commas or brackets left around them), and the times.
    static func split(_ line: String) -> (String, [TimeInterval]) {
        let matches = Timestamp.find(in: line)
        guard !matches.isEmpty else { return (line, []) }
        let ns = NSMutableString(string: line)
        for m in matches.reversed() { ns.replaceCharacters(in: m.range, with: " ") }
        var text = (ns as String).replacingOccurrences(of: #"\(\s*(?:[,;]\s*)*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*[,;]\s*(?=[,;.)\]]|$)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([.,;:!?)])"#, with: "$1", options: .regularExpression)
        return (text.trimmingCharacters(in: .whitespaces), matches.map(\.seconds))
    }
}

/// A time in the call: underlined on hover; a click plays the recording from there.
struct TimeLink: View {
    let seconds: TimeInterval
    @EnvironmentObject private var player: Player
    @State private var hovering = false

    var body: some View {
        Button { player.seek(to: seconds, play: true) } label: {
            Text(Timestamp.short(seconds))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .underline(hovering)
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Play from \(Timestamp.short(seconds))")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
