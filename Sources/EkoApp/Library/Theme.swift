import AppKit
import EkoCore
import SwiftUI

/// One theme for the Library: graphite neutrals and a single accent, the coral of Eko's recording dot.
/// Everything else is primary / secondary / tertiary text and quiet fills, so the accent always means
/// "Eko did this" (done, playing, you).
enum Theme {
    static let nsAccent = NSColor(name: "EkoAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.45, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.89, green: 0.32, blue: 0.25, alpha: 1)
    }
    static let accent = Color(nsColor: nsAccent)
    /// Supporting text. Stronger than the system's secondary/tertiary label colours, which fade into the
    /// graphite background in dark mode.
    static let nsSecondary = NSColor(name: "EkoSecondaryText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.86) : NSColor(white: 0, alpha: 0.70)
    }
    static let nsTertiary = NSColor(name: "EkoTertiaryText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.66) : NSColor(white: 0, alpha: 0.54)
    }
    /// Backgrounds: near-black in dark mode (the system's graphite greys cut text contrast), white in light.
    static let nsCanvas = NSColor(name: "EkoCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1) : .white
    }
    static let nsSidebar = NSColor(name: "EkoSidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }
    static let canvas = Color(nsColor: nsCanvas)
    static let sidebar = Color(nsColor: nsSidebar)
    static let secondary = Color(nsColor: nsSecondary)
    static let tertiary = Color(nsColor: nsTertiary)
    static let card = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.12)
    static let radius: CGFloat = 12
}

extension RecordingItem {
    /// "Chrome call", "Zoom call", or the file name for files Eko didn't name.
    var title: String {
        if let app = apps.first { return "\(app) call" }
        let parts = name.split(separator: " ", maxSplits: 2)
        if parts.count == 3, name.hasPrefix("20") { return parts[2] == "Call" ? "Call" : "\(parts[2]) call" }
        return name
    }

    var fileName: String { url.lastPathComponent }

    /// A monochrome glyph for the app the call was in.
    var glyph: String {
        switch (apps.first ?? name).lowercased() {
        case let a where a.contains("zoom") || a.contains("facetime"): return "video"
        case let a where a.contains("slack"): return "number"
        case let a where a.contains("teams"): return "person.2"
        case let a where ["chrome", "safari", "arc", "brave", "edge", "firefox"].contains { a.contains($0) }: return "globe"
        default: return "phone"
        }
    }
}

/// The app glyph in a soft rounded square.
struct AppGlyph: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// "Transcript" / "Summary": accent when done, quiet outline when not, live state while Eko works.
struct StatusChip: View {
    let label: String
    let done: Bool
    let job: JobStatus?
    /// The list's narrow form: the tab's symbol in a small circle (the label shows as a tooltip).
    var symbol: String? = nil

    var body: some View {
        if let symbol { compact(symbol) } else { full }
    }

    private func compact(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(done ? Theme.accent.opacity(0.15) : Color.clear)
            Circle().strokeBorder(done ? Color.clear : Theme.hairline)
            switch done ? nil : job {
            case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
            case .waiting: Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
            case .failed: Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
            case nil: Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(done ? Theme.accent : Theme.tertiary.opacity(0.7))
            }
        }
        .frame(width: 24, height: 24)
        .help(help)
        .accessibilityLabel("\(label): \(help)")
    }

    private var full: some View {
        HStack(spacing: 4) {
            icon
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .foregroundStyle(done ? Theme.accent : Theme.secondary)
        .background(Capsule().fill(done ? Theme.accent.opacity(0.13) : Color.clear))
        .overlay(Capsule().strokeBorder(done ? Color.clear : Theme.hairline))
        .help(help)
    }

    @ViewBuilder
    private var icon: some View {
        if done {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
        } else {
            switch job {
            case .running: ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            case .waiting: Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
            case .failed: Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.primary)
            case nil: Circle().strokeBorder(Theme.tertiary, lineWidth: 1).frame(width: 7, height: 7)
            }
        }
    }

    private var help: String {
        if done { return "\(label) ready" }
        switch job {
        case let .running(text): return text
        case let .waiting(error): return error.map { "Will retry: \($0)" } ?? "Waiting"
        case let .failed(error): return error
        case nil: return "No \(label.lowercased()) yet"
        }
    }
}
