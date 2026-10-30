import AppKit
import SwiftUI

/// Small floating panel below the menu bar, shown over any app (including full-screen ones).
@MainActor
final class NudgePanel {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(title: String, message: String, primary: String, secondary: String = "Not now", timeout: TimeInterval = 30, action: @escaping () -> Void) {
        dismiss()
        let view = NudgeView(title: title, message: message, primary: primary, secondary: secondary,
                             onPrimary: { [weak self] in self?.dismiss(); action() },
                             onSecondary: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 92)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - hosting.frame.width - 12, y: frame.maxY - hosting.frame.height - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NSSound(named: "Submarine")?.play()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct NudgeView: View {
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                Button(action: onPrimary) { Text(primary) }
                    .buttonStyle(NudgeButtonStyle(fill: .red, text: .white))
                    .keyboardShortcut(.defaultAction)
                Button(action: onSecondary) { Text(secondary) }
                    .buttonStyle(NudgeButtonStyle(fill: Color.primary.opacity(0.14), text: .primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 400, height: 92)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// Equal-sized, bold buttons that look the same whether or not the panel is the key window.
private struct NudgeButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(text)
            .frame(width: 140, height: 30)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
