import AppKit
import EkoCore
import SwiftUI

/// The transcript as one read-only, selectable text (PLAN-LIBRARY.md §5.4). An NSTextView gives selection across
/// lines, copy, the standard Find bar and link clicks for free. Each line: time (a link that plays from there),
/// speaker (only when it changes), text; wrapped lines stay aligned with the text column.
struct TranscriptTextView: NSViewRepresentable {
    let segments: [Segment]
    let fontSize: CGFloat
    /// Playback position; the line being played is highlighted (nil before playback starts).
    let current: TimeInterval?
    let follow: Bool
    /// Bumped by the Find button to show the find bar.
    let findRequest: Int
    let onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)   // TextKit 1: temporary attributes for the highlight
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 30, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.linkTextAttributes = [.foregroundColor: Theme.nsSecondary, .cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Transcript")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.findBarPosition = .aboveContent
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSeek = onSeek
        guard let textView = c.textView else { return }
        if c.segments != segments || c.fontSize != fontSize {
            c.segments = segments
            c.fontSize = fontSize
            let (text, ranges) = Self.render(segments, fontSize: fontSize)
            textView.textStorage?.setAttributedString(text)
            c.ranges = ranges
            c.highlighted = nil
        }
        c.highlight(at: current, follow: follow)
        if c.findRequest != findRequest {
            c.findRequest = findRequest
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
    }

    static func render(_ segments: [Segment], fontSize: CGFloat) -> (NSAttributedString, [NSRange]) {
        let labelled = segments.contains { $0.speaker != .unlabelled }
        let timeColumn = (fontSize * 5.4).rounded()
        let textColumn = labelled ? timeColumn + (fontSize * 5).rounded() : timeColumn
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: timeColumn), NSTextTab(textAlignment: .left, location: textColumn)]
        paragraph.headIndent = textColumn
        paragraph.lineHeightMultiple = 1.25
        paragraph.paragraphSpacing = fontSize * 0.7

        let body = NSFont.systemFont(ofSize: fontSize)
        let time = NSFont.monospacedDigitSystemFont(ofSize: fontSize - 2, weight: .regular)
        let speaker = NSFont.systemFont(ofSize: fontSize - 1, weight: .semibold)
        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (i, seg) in segments.enumerated() {
            let start = out.length
            out.append(NSAttributedString(string: TranscriptText.clock(seg.start), attributes: [
                .font: time, .link: URL(string: "eko-seek:\(seg.start)")!, .toolTip: "Play from here",
            ]))
            out.append(NSAttributedString(string: "\t", attributes: [.font: body]))
            if labelled {
                let changed = i == 0 || segments[i - 1].speaker != seg.speaker
                let name = changed ? seg.speaker.rawValue : ""
                out.append(NSAttributedString(string: name + "\t", attributes: [.font: speaker, .foregroundColor: Self.color(seg.speaker)]))
            }
            out.append(NSAttributedString(string: seg.text + "\n", attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.paragraphStyle, value: paragraph, range: range)
            ranges.append(range)
        }
        return (out, ranges)
    }

    static func color(_ speaker: Speaker) -> NSColor {
        switch speaker {
        case .you: return Theme.nsAccent
        case .others: return Theme.nsSecondary
        case .unlabelled: return Theme.nsSecondary
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var segments: [Segment] = []
        var fontSize: CGFloat = 0
        var ranges: [NSRange] = []
        var highlighted: Int?
        var findRequest = 0
        var onSeek: (TimeInterval) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "eko-seek", let t = Double(url.absoluteString.dropFirst("eko-seek:".count)) else {
                return true   // only Eko's own time links are followed
            }
            onSeek(t)
            return true
        }

        /// The line whose time is the latest at or before `time`.
        func highlight(at time: TimeInterval?, follow: Bool) {
            guard let textView, let layout = textView.layoutManager else { return }
            var index: Int?
            if let time, !segments.isEmpty {
                var lo = 0, hi = segments.count - 1, found = -1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    if segments[mid].start <= time + 0.2 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
                }
                index = found >= 0 ? found : nil
            }
            guard index != highlighted else { return }
            if let old = highlighted, old < ranges.count {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: ranges[old])
            }
            highlighted = index
            guard let index, index < ranges.count else { return }
            layout.addTemporaryAttribute(.backgroundColor, value: Theme.nsAccent.withAlphaComponent(0.14),
                                         forCharacterRange: ranges[index])
            guard follow, let container = textView.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: ranges[index], actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            let visible = textView.visibleRect
            if !visible.insetBy(dx: 0, dy: 40).contains(rect) {
                textView.scroll(NSPoint(x: 0, y: max(0, rect.midY - visible.height / 3)))
            }
        }
    }
}
