import AVFoundation
import Combine
import SwiftUI

/// Live state for the Setup Assistant checklist.
@MainActor
final class SetupModel: ObservableObject {
    struct BrowserRow: Identifiable {
        let id: String
        let name: String
        var state: BrowserSetup.State
        var busy = false
        /// Why "Turn It On for Me" didn't work, with the manual steps.
        var hint: String?
    }

    @Published var camera: Permissions.Status = Permissions.cameraStatus
    @Published var accessibility = Permissions.accessibilityGranted
    @Published var notifications: Permissions.Status = Permissions.notificationsStatus
    @Published var browsers: [BrowserRow] = BrowserSetup.installed.map {
        BrowserRow(id: $0.id, name: $0.name, state: BrowserSetup.isRunning($0.id) ? .unknown : .notRunning)
    }

    var anyBrowserReady: Bool { browsers.contains { $0.state == .ready } }

    /// Cheap checks, run every second while the window is open. Browsers are only re-checked
    /// when their button is pressed (each check can show a prompt).
    func refresh() {
        camera = Permissions.cameraStatus
        accessibility = Permissions.accessibilityGranted
        notifications = Permissions.notificationsStatus
        for index in browsers.indices {
            let running = BrowserSetup.isRunning(browsers[index].id)
            if !running { browsers[index].state = .notRunning }
            else if browsers[index].state == .notRunning { browsers[index].state = .unknown }
        }
    }

    func allowCamera() {
        if case .notAsked = camera {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        } else {
            Permissions.openPrivacySettings("Privacy_Camera")
        }
    }

    func allowAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openPrivacySettings("Privacy_Accessibility")
    }

    func allowNotifications() {
        if case .notAsked = notifications {
            Notifier.requestPermission()
        } else {
            Permissions.open("x-apple.systempreferences:com.apple.preference.notifications")
        }
    }

    func openBrowser(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func check(_ id: String) {
        setBusy(id, true)
        Task.detached {
            let (state, reply) = BrowserSetup.checkDetailed(id)
            let ticked = state == .ready ? nil : BrowserSetup.javaScriptMenuItemTicked(id)
            await MainActor.run {
                self.finish(id, state)
                self.setHint(id, state == .ready ? nil : Self.explain(reply: reply, ticked: ticked))
            }
        }
    }

    /// What Hush saw, in plain words: the menu tick and the browser's own reply.
    nonisolated static func explain(reply: String, ticked: Bool?) -> String {
        var parts: [String] = []
        switch ticked {
        case true?: parts.append("The menu item is ticked ✓.")
        case false?: parts.append("The menu item is not ticked.")
        case nil: break
        }
        if !reply.isEmpty { parts.append("The browser replied: “\(reply)”") }
        return parts.joined(separator: " ")
    }

    /// Brings the browser forward (its menu only acts while it's the active app), ticks
    /// "Allow JavaScript from Apple Events", checks again and comes back to this window.
    func turnOn(_ id: String) {
        setBusy(id, true)
        if let browser = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            if #available(macOS 14, *) {
                browser.activate()
            } else {
                browser.activate(options: [.activateIgnoringOtherApps])
            }
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: 700_000_000) // let it become the active app
            // Never click a ticked item (it's a toggle: that would switch it off again).
            let result: BrowserSetup.ToggleResult = BrowserSetup.javaScriptMenuItemTicked(id) == true
                ? .alreadyOn : BrowserSetup.enableJavaScriptMenuItem(id)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let (state, reply) = BrowserSetup.checkDetailed(id)
            if state == .needsJavaScript {
                // Couldn't do it for you: open the right menu and let you finish the click.
                let menus = BrowserSetup.openMenuForUser(id)
                let hint: String
                if let menus, let first = menus.first {
                    hint = "Hush opened \(BrowserMedia.name(id))'s \(first) menu at the top of the screen. Click "
                        + (menus.dropFirst().map { "\($0) → " }.joined()) + "“Allow JavaScript from Apple Events”, then press Check Again."
                } else {
                    hint = BrowserMedia.howToAllow(id) + " Then press Check Again."
                }
                await MainActor.run {
                    self.finish(id, state)
                    self.setHint(id, hint)
                }
                return
            }
            let ticked = state == .ready ? nil : BrowserSetup.javaScriptMenuItemTicked(id)
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                self.finish(id, state)
                self.setHint(id, state == .ready ? nil
                             : result.hint(id) + " " + Self.explain(reply: reply, ticked: ticked))
            }
        }
    }

    private func setHint(_ id: String, _ hint: String?) {
        guard let index = browsers.firstIndex(where: { $0.id == id }) else { return }
        browsers[index].hint = hint
    }

    private func setBusy(_ id: String, _ busy: Bool) {
        guard let index = browsers.firstIndex(where: { $0.id == id }) else { return }
        browsers[index].busy = busy
    }

    private func finish(_ id: String, _ state: BrowserSetup.State) {
        guard let index = browsers.firstIndex(where: { $0.id == id }) else { return }
        browsers[index].state = state
        browsers[index].busy = false
    }
}

/// First-launch checklist: everything Hush needs, each with a live status and a one-click fix.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    var finish: @MainActor (_ browsersReady: Bool) -> Void
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Hush").font(.title2.bold())
                    Text("A few permissions so Hush can mute you, turn off your camera and pause videos when you step away.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(spacing: 12) {
                    step("Camera", "See whether you're at your desk or holding your phone to your ear.",
                         done: isGranted(model.camera), action: ("Allow", model.allowCamera))
                    Divider()
                    step("Accessibility", "Press mute and camera buttons in Zoom, Teams and other apps, and the ⏯ key. If Hush is already listed, switch it on.",
                         done: model.accessibility, action: ("Allow", model.allowAccessibility))
                    Divider()
                    step("Notifications", "Tell you when Hush mutes you or needs something.",
                         done: isGranted(model.notifications), action: ("Allow", model.allowNotifications))
                }
                .padding(6)
            }

            if !model.browsers.isEmpty || !BrowserSetup.installedUnsupported.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Browsers").font(.headline)
                        Text("For Google Meet and other meetings in a browser: lets Hush press the meeting's camera and mute buttons, and pause a video playing in the same browser. Hush turns on the browser's “Allow JavaScript from Apple Events” setting for you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.browsers) { browser in
                            Divider()
                            browserRow(browser)
                        }
                        ForEach(BrowserSetup.installedUnsupported, id: \.self) { name in
                            Divider()
                            HStack(alignment: .top, spacing: 10) {
                                Text("➖")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(.headline)
                                    Text("\(name) doesn't let other apps run JavaScript in its pages, so Hush can't press meeting buttons there. Videos still pause with ⏯ and your mic is still muted system-wide.")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }

            }
            .padding(.trailing, 4)
            }

            HStack {
                Button("Skip for Now") { finish(false) }
                Spacer()
                Button("Finish") { finish(model.anyBrowserReady) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        .frame(minHeight: 420, idealHeight: 660, maxHeight: .infinity)
        .onReceive(tick) { _ in model.refresh() }
    }

    private func isGranted(_ status: Permissions.Status) -> Bool {
        if case .granted = status { return true }
        return false
    }

    private func step(_ title: String, _ detail: String, done: Bool, action: (String, @MainActor () -> Void)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(done ? "✅" : "⚪️")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { Button(action.0) { action.1() } }
        }
    }

    @ViewBuilder
    private func browserRow(_ browser: SetupModel.BrowserRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(browser.state == .ready ? "✅" : browser.state == .needsJavaScript || browser.state == .needsAutomation ? "❌" : "⚪️")
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name).font(.headline)
                Text(description(browser.state, name: browser.name))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = browser.hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if browser.busy {
                ProgressView().controlSize(.small)
            } else {
                switch browser.state {
                case .notRunning:
                    Button("Open \(browser.name)") { model.openBrowser(browser.id) }
                case .needsJavaScript:
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Turn It On for Me") { model.turnOn(browser.id) }
                            .disabled(!model.accessibility)
                            .help(model.accessibility ? "" : "Allow Accessibility first")
                        Button("Check Again") { model.check(browser.id) }
                            .buttonStyle(.link)
                    }
                case .needsAutomation:
                    Button("Open Settings") { Permissions.openPrivacySettings("Privacy_Automation") }
                case .ready:
                    EmptyView()
                case .noWindow, .unknown:
                    Button("Check") { model.check(browser.id) }
                }
            }
        }
    }

    private func description(_ state: BrowserSetup.State, name: String) -> String {
        switch state {
        case .notRunning: return "Open \(name) to set it up."
        case .unknown: return "Press Check. If macOS asks whether Hush may control \(name), choose Allow."
        case .ready: return "Ready."
        case .needsJavaScript: return "“Allow JavaScript from Apple Events” is off. Hush can switch it on for you."
        case .needsAutomation: return "Hush isn't allowed to control \(name). Turn it on under Privacy & Security → Automation → Hush."
        case .noWindow: return "Open a window in \(name), then press Check."
        }
    }
}
