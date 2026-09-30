import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps Over&Out leaves alone completely (Settings → Calls & Media → Leave these apps alone):
/// their microphone use never counts as a call, their music or videos are never paused or turned
/// down, and their camera/mute buttons are never pressed. For example Discord, a DAW or a game.
enum IgnoredApps {
    private static let key = "ignoredApps"

    struct App: Codable, Identifiable, Equatable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    /// Read from any thread (UserDefaults is thread-safe).
    static var all: [App] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let apps = try? JSONDecoder().decode([App].self, from: data) else { return [] }
        return apps
    }

    static func save(_ apps: [App]) {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// `id` is the app or one of its helper processes ("com.hnc.Discord.helper").
    static func contains(_ id: String) -> Bool {
        all.contains { id == $0.bundleID || id.hasPrefix($0.bundleID + ".") }
    }

    /// Lets the user pick an app from /Applications. nil if cancelled.
    @MainActor
    static func chooseApp(title: String) -> App? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return App(bundleID: bundleID, name: name)
    }
}

/// Settings → Calls & Media → Leave these apps alone.
struct IgnoredAppsSection: View {
    @State private var apps = IgnoredApps.all

    var body: some View {
        Section {
            ForEach(apps) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Button(role: .destructive) {
                        apps.removeAll { $0 == app }
                        IgnoredApps.save(apps)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop ignoring \(app.name)")
                }
            }
            Button("Add App…") {
                guard let app = IgnoredApps.chooseApp(title: "Choose an app for Over&Out to leave alone"),
                      !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
                apps.append(app)
                IgnoredApps.save(apps)
            }
        } header: {
            Text("Leave these apps alone")
        } footer: {
            Text("Over&Out never touches these: using their microphone isn't a call, their sound is never paused or turned down, and their buttons are never pressed. Handy for Discord while gaming, a music app you always want playing, or recording software.")
        }
    }
}
