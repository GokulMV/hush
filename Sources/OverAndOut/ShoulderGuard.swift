import AppKit
import SwiftUI

/// Shoulder-surfer guard: when the camera sees a second face (someone behind you or next to you)
/// for a moment, hide the apps you chose, or cover every screen with a blurred privacy screen.
/// Everything comes back once only you are in view again. Off by default (Settings → Presence).
@MainActor
final class ShoulderGuard {
    enum Action: String { case hideApps, blurScreen }

    static let enabledKey = "shoulderGuard"
    static let actionKey = "shoulderGuardAction"
    static let appsKey = "shoulderGuardApps"

    /// A second face must stay this long before acting (a glance past the camera doesn't count),
    /// and be gone this long before undoing.
    static let showAfter: TimeInterval = 1.5
    static let restoreAfter: TimeInterval = 2.0

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var action: Action {
        Action(rawValue: UserDefaults.standard.string(forKey: actionKey) ?? "") ?? .hideApps
    }

    static var apps: [IgnoredApps.App] {
        guard let data = UserDefaults.standard.data(forKey: appsKey),
              let apps = try? JSONDecoder().decode([IgnoredApps.App].self, from: data) else { return [] }
        return apps
    }

    static func saveApps(_ apps: [IgnoredApps.App]) {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: appsKey) }
    }

    private(set) var isActive = false
    private var crowdSince: Date?
    private var aloneSince: Date?
    /// Apps this guard hid (only these are shown again; ones you had hidden stay hidden).
    private var hiddenByUs: [NSRunningApplication] = []
    private var overlays: [NSWindow] = []
    /// "Show anyway" was clicked: don't cover again until the other person has left.
    private var dismissedUntilAlone = false
    var onChange: (() -> Void)?

    /// Called for every analysed camera frame.
    func update(faceCount: Int, enabled: Bool) {
        guard enabled, Self.isEnabled else {
            if isActive { restore() }
            crowdSince = nil
            dismissedUntilAlone = false
            return
        }
        let now = Date()
        if faceCount >= 2 {
            aloneSince = nil
            let since = crowdSince ?? now
            crowdSince = since
            if !isActive, !dismissedUntilAlone, now.timeIntervalSince(since) >= Self.showAfter { protect() }
        } else {
            crowdSince = nil
            let since = aloneSince ?? now
            aloneSince = since
            if now.timeIntervalSince(since) >= Self.restoreAfter {
                dismissedUntilAlone = false
                if isActive { restore() }
            }
        }
    }

    private func protect() {
        isActive = true
        Stats.shoulderGuarded()
        switch Self.action {
        case .hideApps:
            let wanted = Set(Self.apps.map(\.bundleID))
            hiddenByUs = NSWorkspace.shared.runningApplications.filter { app in
                guard let id = app.bundleIdentifier, wanted.contains(id), !app.isHidden else { return false }
                return app.hide()
            }
            if !hiddenByUs.isEmpty {
                Notifier.post("Someone's looking at your screen", "Over&Out hid \(hiddenByUs.compactMap(\.localizedName).joined(separator: ", ")). They come back when you're alone again.")
            }
        case .blurScreen:
            overlays = NSScreen.screens.map(makeOverlay)
            overlays.forEach { $0.orderFrontRegardless() }
        }
        onChange?()
    }

    func restore() {
        isActive = false
        for app in hiddenByUs where !app.isTerminated { app.unhide() }
        hiddenByUs = []
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        onChange?()
    }

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        let content = PrivacyScreenView { [weak self] in
            // Your call: show the screen, and don't cover it again until the other person leaves.
            self?.dismissedUntilAlone = true
            self?.restore()
        }
        let blur = NSVisualEffectView(frame: screen.frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let hosting = NSHostingView(rootView: content)
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        window.contentView = blur
        return window
    }
}

private struct PrivacyScreenView: View {
    var showAnyway: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash.fill").font(.system(size: 54))
            Text("Someone else is looking at your screen").font(.title.bold())
            Text("Over&Out covered it. It uncovers by itself when only you are in view.")
                .foregroundStyle(.secondary)
            Button("Show My Screen") { showAnyway() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings → Presence → Shoulder-surfer guard.
struct ShoulderGuardSection: View {
    @AppStorage(ShoulderGuard.enabledKey) private var enabled = false
    @AppStorage(ShoulderGuard.actionKey) private var action = ShoulderGuard.Action.hideApps.rawValue
    @State private var apps = ShoulderGuard.apps

    var body: some View {
        Section {
            Toggle("Protect my screen when someone else is looking", isOn: $enabled)
            if enabled {
                Picker("When a second face appears", selection: $action) {
                    Text("Hide the apps below").tag(ShoulderGuard.Action.hideApps.rawValue)
                    Text("Blur the whole screen").tag(ShoulderGuard.Action.blurScreen.rawValue)
                }
                if action == ShoulderGuard.Action.hideApps.rawValue {
                    ForEach(apps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button(role: .destructive) {
                                apps.removeAll { $0 == app }
                                ShoulderGuard.saveApps(apps)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add App to Hide…") {
                        guard let app = IgnoredApps.chooseApp(title: "Choose an app to hide from onlookers"),
                              !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
                        apps.append(app)
                        ShoulderGuard.saveApps(apps)
                    }
                }
            }
        } header: {
            Text("Shoulder-surfer guard")
        } footer: {
            Text("Uses the camera like presence detection (on this Mac only, nothing saved). A second face has to stay in view for a moment; everything comes back 2 seconds after it's gone. While this is on, the camera stays on (green light). A photo or poster with a face behind you counts as a person: use Camera Preview to check.")
        }
    }
}
