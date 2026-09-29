import AppKit
import SwiftUI

/// A panel that drops down from the menu-bar icon, like other menu-bar apps' windows: no title bar
/// or window buttons, always just below the menu bar, sized to fit the screen, and closed by
/// clicking anywhere else. (An NSPopover flips above the icon, off screen, when it doesn't fit below.)
@MainActor
final class DropDownPanel: NSPanel {
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8
    private let preferredHeight: CGFloat
    private var outsideClicks: Any?
    private var shownAt = Date.distantPast

    init<Content: View>(width: CGFloat, preferredHeight: CGFloat, content: Content) {
        self.preferredHeight = preferredHeight
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: preferredHeight),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false // panels vanish when their app loses focus unless told otherwise
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating // above windows, below menus (so its own pop-up menus show on top)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true } // text fields and pickers need keyboard focus

    /// Shows the panel under `anchor` (the menu-bar icon), kept inside that screen's usable area.
    func show(below anchor: NSStatusBarButton) {
        guard let anchorWindow = anchor.window,
              let screen = anchorWindow.screen ?? NSScreen.main else { return }
        let icon = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let usable = screen.visibleFrame // excludes the menu bar and the Dock
        let width = frame.width
        let height = min(preferredHeight, usable.height - Self.gap - Self.margin)
        var x = icon.midX - width / 2
        x = max(usable.minX + Self.margin, min(x, usable.maxX - Self.margin - width))
        let top = min(icon.minY, usable.maxY) - Self.gap
        setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)

        NSApp.activate(ignoringOtherApps: true)
        shownAt = Date()
        makeKeyAndOrderFront(nil)
        watchOutsideClicks()
    }

    /// Only a real click outside closes it: clicking another app, the desktop or another app's menu
    /// bar item (a global monitor sees only clicks that go to other apps). Losing focus by itself
    /// doesn't close it, since a background app or a notification can take focus without you
    /// touching anything.
    private func watchOutsideClicks() {
        if outsideClicks != nil { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                // Ignore the tail of the click that opened it.
                guard let self, Date().timeIntervalSince(self.shownAt) > 0.4 else { return }
                self.close()
            }
        }
    }

    override func close() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        super.close()
    }

    override func cancelOperation(_ sender: Any?) { close() } // Esc
}
