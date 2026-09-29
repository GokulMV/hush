import Combine
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case general, presence, calls, permissions, updates, about

    var title: String {
        switch self {
        case .general: return "General"
        case .presence: return "Presence"
        case .calls: return "Calls & Media"
        case .permissions: return "Permissions"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .presence: return "person.crop.circle"
        case .calls: return "phone"
        case .permissions: return "lock.shield"
        case .updates: return "arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

/// One page of the Settings window (the window's toolbar switches pages). Every toggle writes straight to UserDefaults; the engine
/// reads them on its next tick (twice a second), so changes apply immediately.
/// Which Settings page is showing; the window's toolbar sets it.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    private var page: SettingsTab { navigation.page }
    var showWelcome: @MainActor () -> Void = {}
    var showSetup: @MainActor () -> Void = {}
    var setupNeeded: @MainActor () -> Bool = { false }
    var showWhatsNew: @MainActor () -> Void = {}
    @ObservedObject var updates: UpdateModel

    @AppStorage(SettingsKey.enabled) private var enabled = true
    @AppStorage(SettingsKey.presenceEnabled) private var presenceEnabled = true
    @AppStorage(SettingsKey.alwaysWatch) private var alwaysWatch = false
    @AppStorage(SettingsKey.cameraPausedUntil) private var cameraPausedUntil = 0.0
    @AppStorage(SettingsKey.awayDelay) private var awayDelay = 2.0
    @AppStorage(SettingsKey.phoneDetection) private var phoneDetection = true
    @AppStorage(SettingsKey.awayMuteMic) private var awayMuteMic = true
    @AppStorage(SettingsKey.awayZoomVideoOff) private var awayZoomVideoOff = true
    @AppStorage(SettingsKey.awayPauseMedia) private var awayPauseMedia = true
    @AppStorage(SettingsKey.autoResumeMedia) private var autoResumeMedia = true
    @AppStorage(SettingsKey.callPauseMedia) private var callPauseMedia = true
    @AppStorage(SettingsKey.callMuteOnJoin) private var callMuteOnJoin = false
    @AppStorage(SettingsKey.ringProtect) private var ringProtect = true
    @AppStorage(SettingsKey.duckLevel) private var duckLevel = 0.3
    @AppStorage(SettingsKey.showNotifications) private var showNotifications = true
    @AppStorage(SettingsKey.browserScripting) private var browserScripting = false

    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var permissions: [Permissions.Row] = []
    @State private var automationRows: [Permissions.Row]?
    @State private var checkingAutomation = false
    @State private var now = Date()
    @State private var needsSetup = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch page {
            case .general: generalTab
            case .presence: presenceTab
            case .calls: callsTab
            case .permissions: permissionsTab
            case .updates: UpdatesView(model: updates)
            case .about: AboutView(showWhatsNew: showWhatsNew)
            }
        }
        .frame(width: 640, height: 640)
        .onAppear {
            needsSetup = setupNeeded()
            if page == .permissions { loadPermissions() }
        }
        .onChange(of: navigation.page) { newPage in
            if newPage == .permissions { loadPermissions() }
        }
        .onReceive(refresh) { _ in
            if page == .permissions { loadPermissions() }
            now = Date()
            needsSetup = setupNeeded()
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Tabs

    private var generalTab: some View {
        Form {
            header

            if needsSetup {
                Section {
                    HStack {
                        Text("⚠️")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finish setting up Over&Out").font(.headline)
                            Text("Some permissions are missing, so parts of Over&Out won't work yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Setup") { showSetup() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }

            Section("General") {
                Toggle("Show notifications", isOn: $showNotifications)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { wanted in setOpenAtLogin(wanted) }
            }

            Section("Keyboard shortcuts") {
                shortcut("⌃⌥⌘H", "Open Over&Out's menu (even if its icon is hidden)")
                shortcut("⌃⌥⌘G", "Turn Over&Out on / off")
                shortcut("⌃⌥⌘C", "Over&Out camera on / off")
                shortcut("⌃⌥⌘M", "Mute / unmute microphone")
                shortcut("⌃⌥⌘P", "Panic: mute, video off, pause, lower volume")
            }

            Section {
                HStack {
                    Button("Run Setup Assistant") { showSetup() }
                    Button("What's New") { showWhatsNew() }
                    Button("Welcome Banner") { showWelcome() }
                    Spacer()
                    Button("Quit Over&Out") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var presenceTab: some View {
        Form {
            Section {
                Toggle("Let Over&Out use the camera to see if I'm here", isOn: $presenceEnabled)
                    .onChange(of: presenceEnabled) { _ in cameraPausedUntil = 0 }
                if presenceEnabled {
                    cameraPauseRow
                }
                Toggle("Keep watching even with no call or video playing", isOn: $alwaysWatch)
                    .disabled(!presenceEnabled)
                Picker("Count me away after", selection: $awayDelay) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .disabled(!presenceEnabled)
                Toggle("Detect when I pick up my phone", isOn: $phoneDetection)
                    .disabled(!presenceEnabled)
            } header: {
                Text("Presence")
            } footer: {
                Text("The camera is analysed on this Mac and nothing is saved. Its green light is on while Over&Out is watching.")
            }

            Section("When I step away or pick up my phone") {
                Toggle("Mute my microphone (system-wide, and the meeting's mute button)", isOn: $awayMuteMic)
                Toggle("Turn off my camera in the meeting (Meet, Zoom, Teams, Webex, Slack, Discord…)", isOn: $awayZoomVideoOff)
                Toggle("Pause videos and music", isOn: $awayPauseMedia)
                Toggle("Resume them when I'm back", isOn: $autoResumeMedia)
            }
            .disabled(!presenceEnabled)
        }
        .formStyle(.grouped)
    }

    private var callsTab: some View {
        Form {
            Section("Calls") {
                Toggle("Pause videos and music when a call starts", isOn: $callPauseMedia)
                Toggle("Start every call muted", isOn: $callMuteOnJoin)
                Toggle("Lower the volume while my iPhone rings", isOn: $ringProtect)
                HStack {
                    Text("Ringing volume")
                    Slider(value: $duckLevel, in: 0.05...0.8)
                    Text("\(Int(duckLevel * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(!ringProtect)
            }

            Section {
                Toggle("Control meetings and videos inside browser tabs", isOn: $browserScripting)
            } header: {
                Text("Browsers")
            } footer: {
                Text("Lets Over&Out press Google Meet's camera and mute buttons and pause every playing tab, on every desktop. Needs “Allow JavaScript from Apple Events” in each browser; the Setup Assistant can switch it on for you.")
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        Form {
            Section {
                ForEach(permissions, id: \.name) { row in
                    HStack {
                        Text(row.status.badge)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text("Used to \(row.purpose)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.status.label).foregroundStyle(.secondary)
                        Button("Open") { Permissions.open(row.settingsURL) }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("✅ allowed   ❌ denied   ⚪️ not asked yet   ➖ not applicable")
            }
            Section {
                if needsSetup {
                    HStack {
                        Label("Something Over&Out needs is still off.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Run Setup Assistant") { showSetup() }
                    }
                } else {
                    HStack {
                        Label("All set: Over&Out has everything it needs.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Run Setup Again") { showSetup() }.buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Over&Out").font(.title2.bold())
                Text("Mutes, hides and pauses things when you step away, pick up your phone, or a call starts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(enabled ? "Over&Out is on" : "Over&Out is off")
        }
        .padding(.vertical, 4)
    }

    /// "Paused until 3:45 PM · Resume now", or quick buttons to pause for a while.
    @ViewBuilder
    private var cameraPauseRow: some View {
        if cameraPausedUntil > now.timeIntervalSince1970 {
            HStack {
                Text("Camera paused until \(Date(timeIntervalSince1970: cameraPausedUntil).formatted(date: .omitted, time: .shortened))")
                Spacer()
                Button("Resume now") { cameraPausedUntil = 0 }
            }
        } else {
            HStack {
                Text("Pause the camera for")
                Spacer()
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h") {
                        cameraPausedUntil = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
                        now = Date()
                    }
                }
            }
        }
    }

    /// Reading permissions asks macOS about other apps (Automation for Spotify, Music, browsers),
    /// which can take seconds when one of them is busy. Never on the main thread; only while the
    /// Permissions tab is showing.
    /// Quick rows at once; the Automation rows (slow, one question to macOS per app) fill in when
    /// ready. At most one slow check runs at a time, however often the page refreshes.
    private func loadPermissions() {
        permissions = Permissions.rows(automation: automationRows ?? Permissions.automationPlaceholders())
        guard !checkingAutomation else { return }
        checkingAutomation = true
        Task.detached(priority: .utility) {
            let automation = Permissions.automationRows()
            await MainActor.run {
                automationRows = automation
                checkingAutomation = false
                permissions = Permissions.rows(automation: automation)
            }
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func setOpenAtLogin(_ wanted: Bool) {
        let isOn = SMAppService.mainApp.status == .enabled
        guard wanted != isOn else { return }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openAtLogin = isOn
            Notifier.post("Couldn't change Open at Login", error.localizedDescription)
        }
    }
}
