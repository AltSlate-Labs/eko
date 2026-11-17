import AppKit
import EkoCore

/// Development only: drive the Library and save pictures of its window, so the UI can be checked without
/// clicking or screen-recording permission. Inactive unless Eko is launched with `EKO_UI_CHECK_DIR=<folder>`;
/// otherwise every eko://ui/… URL is ignored. Examples:
///   open "eko://ui/open?name=2026-11-13%2011-23%20Chrome&tab=summary"
///   open "eko://ui/snapshot?file=summary.png"
/// Other commands: back, section?name=settings|recordings, search?text=…, appearance?name=dark|light, seek?t=723,
/// ask?q=… (sends a real chat question)
@MainActor
enum UICheck {
    static let folder = ProcessInfo.processInfo.environment["EKO_UI_CHECK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    /// Set by the open recording's player and chat, so `seek` and `ask` can drive them.
    static weak var player: Player?
    static weak var chat: ChatSession?

    static func handle(_ url: URL) {
        guard let folder else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let controller = LibraryWindowController.shared
        let library = controller.library
        switch url.path {
        case "/open":
            if controller.window?.isVisible != true { controller.show() }
            if let name = value("name") { openWhenListed(name, tries: 10) }
            if let tab = LibraryModel.Tab.allCases.first(where: { $0.rawValue.lowercased() == value("tab") }) { library.tab = tab }
        case "/back": library.openedID = nil
        case "/size":   // window width (and height), clamped to the window's minimum
            if let window = controller.window, let w = value("w").flatMap(Double.init) {
                let h = value("h").flatMap(Double.init) ?? window.frame.height
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: w, height: h)), display: true)
            }
        case "/section": controller.show(value("name") == "settings" ? .settings : .recordings)
        case "/search": library.filter.text = value("text") ?? ""
        case "/seek": if let t = value("t").flatMap(Double.init) { player?.seek(to: t, play: false) }
        case "/ask": if let q = value("q") { chat?.ask(q) }
        case "/appearance":
            switch value("name") {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        case "/snapshot":
            let name = (value("file") ?? "library.png").replacingOccurrences(of: "/", with: "_")
            RecordingSession.dlog("ui-check: \(name): section \(library.section), opened \(library.openedID != nil), tab \(library.tab), " +
                                  "items \(library.items.count), visible \(controller.window?.occlusionState.contains(.visible) ?? false), " +
                                  "key \(controller.window?.isKeyWindow ?? false)")
            snapshot(controller.window, to: folder.appendingPathComponent(name))
        default: break
        }
    }

    /// The list is read in the background when the window opens; wait for it (up to 5 s).
    private static func openWhenListed(_ name: String, tries: Int) {
        let library = LibraryWindowController.shared.library
        if let item = library.items.first(where: { $0.name == name }) {
            library.open(item.id)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openWhenListed(name, tries: tries - 1) }
        } else {
            RecordingSession.dlog("ui-check: no recording named \(name)")
        }
    }

    /// Draws the whole window (title bar and toolbar included) into a PNG.
    static func snapshot(_ window: NSWindow?, to url: URL) {
        guard let window, let view = window.contentView?.superview else { return }
        window.orderFrontRegardless()   // an occluded window may not have redrawn its latest state
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
