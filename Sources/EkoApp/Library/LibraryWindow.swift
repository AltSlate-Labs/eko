import AppKit
import EkoCore
import SwiftUI

/// The Library window (PLAN-LIBRARY.md §3): an AppKit window hosting SwiftUI, so it can be opened from the menu,
/// a URL or code, and comes to the front reliably in this menu-bar app. While it is open Eko is a regular app
/// (Dock icon, ⌘-Tab, Edit/Find menus); when it closes Eko goes back to the menu bar only.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = LibraryWindowController()
    let library = LibraryModel()
    private(set) var window: NSWindow?

    func show(_ section: LibraryModel.Section? = nil) {
        if let section { library.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        library.start()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        guard let recorder = RecorderModel.current, let notes = NotesModel.current else {
            fatalError("Library opened before the app finished launching")
        }
        let root = LibraryRootView()
            .environmentObject(library)
            .environmentObject(recorder)
            .environmentObject(notes)
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]   // SwiftUI .toolbar / .navigationTitle drive the window's toolbar
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Eko"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 700, height: 480)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("EkoLibrary")
        window.backgroundColor = Theme.nsCanvas
        window.titlebarAppearsTransparent = true   // the dark canvas runs under the toolbar instead of a graphite strip
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        library.stop()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Sidebar row drawn in the theme's accent (the system list selection would use the system accent colour).
private struct SidebarItem: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.13) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LibraryRootView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var notes: NotesModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarItem(title: "Recordings", symbol: "waveform", count: library.items.count,
                            selected: library.section == .recordings) { library.section = .recordings }
                SidebarItem(title: "Settings", symbol: "gearshape", count: nil,
                            selected: library.section == .settings) { library.section = .settings }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.sidebar.ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
            RecordingNowBar()   // on every page while a call is being recorded
            switch library.section {
            case .recordings:
                if let item = library.opened {
                    RecordingDetailView(item: item).id(item.id)
                } else {
                    RecordingsView()
                }
            case .settings:
                SettingsView()
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbarBackground(Theme.canvas, for: .windowToolbar)
        }
        .tint(Theme.accent)
    }
}
