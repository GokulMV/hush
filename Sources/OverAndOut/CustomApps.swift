import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Call apps you add yourself (Settings → Calls & Media), on top of the built-in list. For each one
/// Over&Out treats its microphone use as a call, and can be taught which of its buttons turn the
/// camera and the microphone off (for apps whose buttons have names it doesn't recognise).
struct CustomApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String
    /// Exact labels of the app's own buttons, picked by you in "Learn Buttons". nil: use the
    /// built-in names ("Turn off camera", "Mute"…).
    var cameraButton: String?
    var muteButton: String?
    /// The button's on/off state (AXValue/AXSelected) when you picked it, i.e. while it was on.
    var cameraOnValue: String?
    var muteOnValue: String?
    var id: String { bundleID }

    func button(for kind: MeetingControl.Kind) -> String? {
        kind == .video ? cameraButton : muteButton
    }

    func onValue(for kind: MeetingControl.Kind) -> String? {
        kind == .video ? cameraOnValue : muteOnValue
    }
}

/// A button seen in Learn Buttons, with its state at that moment.
struct LearnableButton: Equatable, Hashable, Sendable {
    let label: String
    let value: String?

    /// Over&Out can tell on from off for it, so it never overrides what you set yourself.
    var isSafe: Bool { value != nil || MeetingControl.isActionLabel(label) }
}

enum CustomApps {
    private static let key = "customCallApps"

    /// Read from any thread (UserDefaults is thread-safe).
    static var all: [CustomApp] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let apps = try? JSONDecoder().decode([CustomApp].self, from: data) else { return [] }
        return apps
    }

    static func save(_ apps: [CustomApp]) {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The added app `id` belongs to (its helpers' IDs start with the app's: "…WhatsApp.Helper").
    static func app(for id: String) -> CustomApp? {
        all.first { id == $0.bundleID || id.hasPrefix($0.bundleID + ".") }
    }

    static func contains(_ id: String) -> Bool { app(for: id) != nil }
}

/// Settings → Calls & Media → "Other call apps".
@MainActor
final class CustomAppsModel: ObservableObject {
    @Published var apps: [CustomApp] = CustomApps.all
    @Published var learning: CustomApp?
    @Published var learnedButtons: [LearnableButton] = []
    @Published var scanning = false
    @Published var message: String?

    func add() {
        let panel = NSOpenPanel()
        panel.title = "Choose a call app"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !apps.contains(where: { $0.bundleID == bundleID }) else {
            message = "\(name) is already in the list."
            return
        }
        apps.append(CustomApp(bundleID: bundleID, name: name))
        CustomApps.save(apps)
        // What Over&Out needs for it: Accessibility, to see and press its buttons.
        if Permissions.accessibilityGranted {
            message = "Added \(name). During a call in \(name), use Learn Buttons if its camera and mute aren't switched off by themselves."
        } else {
            message = "Added \(name). Over&Out needs Accessibility to press \(name)'s buttons: switch Over&Out on in the window that just opened."
            Permissions.requestAccessibility()
        }
    }

    func remove(_ app: CustomApp) {
        apps.removeAll { $0.bundleID == app.bundleID }
        CustomApps.save(apps)
    }

    /// Lists the buttons the app shows right now (start a call in it first), to pick from.
    func learn(_ app: CustomApp) {
        guard Permissions.accessibilityGranted else {
            message = "Over&Out needs Accessibility first."
            Permissions.requestAccessibility()
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            message = "Open \(app.name) and start a call in it, then press Learn Buttons again."
            return
        }
        scanning = true
        message = nil
        MeetingControl.shared.buttonLabels(in: running.processIdentifier) { buttons in
            Task { @MainActor in
                self.scanning = false
                guard !buttons.isEmpty else {
                    self.message = "No buttons found in \(app.name). Start a call in it so the call buttons are on screen, then try again."
                    return
                }
                self.learnedButtons = buttons
                self.learning = app
            }
        }
    }

    func saveButtons(camera: LearnableButton?, mute: LearnableButton?) {
        guard let learning, let index = apps.firstIndex(where: { $0.bundleID == learning.bundleID }) else { return }
        apps[index].cameraButton = camera?.label
        apps[index].cameraOnValue = camera?.value
        apps[index].muteButton = mute?.label
        apps[index].muteOnValue = mute?.value
        CustomApps.save(apps)
        message = "Saved. Over&Out will press these in \(learning.name) when you step away."
        self.learning = nil
    }
}

struct CustomAppsSection: View {
    @StateObject private var model = CustomAppsModel()

    var body: some View {
        Section {
            ForEach(model.apps) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(summary(app)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Learn Buttons…") { model.learn(app) }
                        .disabled(model.scanning)
                    Button(role: .destructive) { model.remove(app) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.name)")
                }
            }
            HStack {
                Button("Add App…") { model.add() }
                if model.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Text(Permissions.accessibilityGranted ? "✅ Accessibility on" : "❌ Accessibility needed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Other call apps")
        } footer: {
            Text("Zoom, Teams, Meet, FaceTime, Webex, Slack, Discord, Skype and WhatsApp are built in. Add any other app here. If an app's camera or mute isn't switched off when you step away, start a call in it (camera and mic on) and use Learn Buttons to pick its buttons. As everywhere, Over&Out only switches off what's on, and only switches back on what it switched off: if you turned your camera off or muted yourself, it stays that way.")
        }
        .sheet(item: $model.learning) { app in
            LearnButtonsSheet(app: app, buttons: model.learnedButtons) { camera, mute in
                model.saveButtons(camera: camera, mute: mute)
            } cancel: {
                model.learning = nil
            }
        }
    }

    private func summary(_ app: CustomApp) -> String {
        let camera = app.cameraButton.map { "camera: “\($0)”" } ?? "camera: built-in names"
        let mute = app.muteButton.map { "mute: “\($0)”" } ?? "mute: built-in names"
        return "\(camera) · \(mute)"
    }
}

/// Pick the app's camera and mute buttons from the ones it shows right now.
struct LearnButtonsSheet: View {
    let app: CustomApp
    let buttons: [LearnableButton]
    var save: (LearnableButton?, LearnableButton?) -> Void
    var cancel: () -> Void

    @State private var camera: String
    @State private var mute: String
    private static let none = "— use built-in names —"

    init(app: CustomApp, buttons: [LearnableButton], save: @escaping (LearnableButton?, LearnableButton?) -> Void,
         cancel: @escaping () -> Void) {
        self.app = app
        self.buttons = buttons
        self.save = save
        self.cancel = cancel
        _camera = State(initialValue: app.cameraButton ?? Self.none)
        _mute = State(initialValue: app.muteButton ?? Self.none)
    }

    /// Only buttons whose on/off state Over&Out can read: others could be switched on by mistake.
    private var safe: [LearnableButton] { buttons.filter(\.isSafe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Buttons in \(app.name)").font(.title3.bold())
            Text("Your camera and mic should be on right now. Pick the button that switches your camera off, and the one that mutes you. Over&Out presses it only while it's on, and switches it back on only if it's still the way Over&Out left it, so anything you turn off yourself stays off.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Picker("Camera button", selection: $camera) {
                Text(Self.none).tag(Self.none)
                ForEach(safe, id: \.label) { Text($0.label).tag($0.label) }
            }
            Picker("Mute button", selection: $mute) {
                Text(Self.none).tag(Self.none)
                ForEach(safe, id: \.label) { Text($0.label).tag($0.label) }
            }
            if safe.count < buttons.count {
                Text("\(buttons.count - safe.count) other buttons aren't listed: they don't show whether they're on or off, so pressing them could switch your camera or mic on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(safe.first { $0.label == camera }, safe.first { $0.label == mute })
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
