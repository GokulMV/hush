import AppKit
import SwiftUI

/// A floating card that drops down under the menu-bar icon: the welcome message on first
/// launch, and a short "Hush is running" toast on later launches.
@MainActor
final class Banner {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func showWelcome(below anchor: NSStatusBarButton?, openSettings: @escaping () -> Void) {
        show(below: anchor, dismissAfter: 30) { close in
            BannerView(
                title: "Hush is installed and running",
                message: "Look for its icon in your menu bar, up here. Hush mutes your mic, turns your meeting camera off and pauses videos when you step away or put your phone to your ear, and turns everything back on when you return.",
                shortcuts: [
                    ("⌃⌥⌘G", "Turn Hush on / off"),
                    ("⌃⌥⌘M", "Mute / unmute mic"),
                    ("⌃⌥⌘P", "Panic mode"),
                ],
                primary: ("Open Settings", { close(); openSettings() }),
                secondary: ("Got it", close)
            )
        }
    }

    func showRunningToast(below anchor: NSStatusBarButton?) {
        show(below: anchor, dismissAfter: 3) { close in
            BannerView(title: "Hush is running", message: "It's in your menu bar.", shortcuts: [],
                       primary: nil, secondary: nil)
        }
    }

    private func show<Content: View>(below anchor: NSStatusBarButton?, dismissAfter seconds: Double,
                                     content: (@escaping () -> Void) -> Content) {
        close()
        let hosting = NSHostingView(rootView: content { [weak self] in self?.close() })
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.setFrameOrigin(origin(for: size, below: anchor))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            panel.orderOut(nil)
        }
    }

    /// Centred under the status item, kept on screen; top-right corner if the icon can't be located.
    private func origin(for size: NSSize, below anchor: NSStatusBarButton?) -> NSPoint {
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = visible.maxX - size.width - 12
        if let iconFrame = anchor?.window?.frame {
            x = iconFrame.midX - size.width / 2
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: visible.maxY - size.height - 6)
    }
}

private struct BannerView: View {
    let title: String
    let message: String
    let shortcuts: [(String, String)]
    let primary: (String, () -> Void)?
    let secondary: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shortcuts, id: \.0) { pair in
                        HStack {
                            Text(pair.0).font(.system(.callout, design: .monospaced)).frame(width: 64, alignment: .leading)
                            Text(pair.1).font(.callout)
                        }
                    }
                }
                .padding(.leading, 52)
            }
            if primary != nil || secondary != nil {
                HStack {
                    Spacer()
                    if let secondary { Button(secondary.0, action: secondary.1) }
                    if let primary { Button(primary.0, action: primary.1).keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
