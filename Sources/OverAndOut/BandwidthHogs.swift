import AppKit
import Darwin
import SwiftUI

/// "Pause bandwidth hogs during calls": apps you pick (Dropbox, Google Drive, a torrent client,
/// Steam…) are frozen while a call is on, so their uploads and downloads stop and the call gets the
/// connection, then carry on where they left off when it ends. Freezing = SIGSTOP to the app and
/// every process it started; un-freezing = SIGCONT. macOS gives no way to slow one app's traffic
/// without Apple's paid network-extension entitlement, so this is the dependable alternative.
@MainActor
enum BandwidthHogs {
    private static let appsKey = "bandwidthHogs"
    /// Frozen process IDs, kept on disk so a crash can never leave an app frozen: the next launch
    /// un-freezes them.
    private static let frozenKey = "bandwidthHogsFrozen"
    /// Never keep anything frozen longer than this, even if a "call" doesn't end.
    static let maximumFreeze: TimeInterval = 3 * 60 * 60

    static var apps: [IgnoredApps.App] {
        guard let data = UserDefaults.standard.data(forKey: appsKey),
              let apps = try? JSONDecoder().decode([IgnoredApps.App].self, from: data) else { return [] }
        return apps
    }

    static func saveApps(_ apps: [IgnoredApps.App]) {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: appsKey) }
    }

    /// Apps that must never be frozen whatever the list says.
    private static let protected: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                                                 "com.apple.loginwindow", "com.apple.WindowManager"]

    private(set) static var frozenNames: [String] = []
    private static var frozenSince: Date?

    /// Freezes the chosen apps that are running, except any that host the call (`callApps`).
    /// Returns true if something was frozen.
    static func freeze(except callApps: Set<String>) -> Bool {
        var pids: [pid_t] = []
        var names: [String] = []
        let own = Bundle.main.bundleIdentifier
        for app in apps {
            guard !protected.contains(app.bundleID), app.bundleID != own,
                  !callApps.contains(where: { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }) else { continue }
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                let tree = processTree(running.processIdentifier)
                for pid in tree where kill(pid, SIGSTOP) == 0 { pids.append(pid) }
                if !tree.isEmpty { names.append(app.name) }
            }
        }
        guard !pids.isEmpty else { return false }
        let previous = UserDefaults.standard.array(forKey: frozenKey) as? [Int32] ?? []
        UserDefaults.standard.set(previous + pids, forKey: frozenKey)
        frozenNames = names
        frozenSince = Date()
        return true
    }

    /// Lets everything frozen run again (also used at launch, for anything a crash left frozen).
    static func thaw() {
        let pids = UserDefaults.standard.array(forKey: frozenKey) as? [Int32] ?? []
        for pid in pids { kill(pid, SIGCONT) }
        UserDefaults.standard.removeObject(forKey: frozenKey)
        frozenNames = []
        frozenSince = nil
    }

    /// Safety net, checked every poll: un-freeze after `maximumFreeze`.
    static func thawIfTooLong() -> Bool {
        guard let since = frozenSince, Date().timeIntervalSince(since) > maximumFreeze else { return false }
        thaw()
        return true
    }

    /// The process and everything it started (helpers, workers…), children first.
    private static func processTree(_ root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        while let pid = queue.popLast(), result.count < 500 {
            result.append(pid)
            let count = proc_listchildpids(pid, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) * 2)
            let filled = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            queue.append(contentsOf: children.prefix(Int(max(0, filled))).filter { $0 > 0 })
        }
        return result.reversed()
    }
}

/// Settings → Calls & Media → During calls, pause these apps.
struct BandwidthHogsSection: View {
    @State private var apps = BandwidthHogs.apps

    var body: some View {
        Section {
            ForEach(apps) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Button(role: .destructive) {
                        apps.removeAll { $0 == app }
                        BandwidthHogs.saveApps(apps)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop pausing \(app.name) during calls")
                }
            }
            Button("Add App…") {
                guard let app = IgnoredApps.chooseApp(title: "Choose an app that uses a lot of internet (Dropbox, a torrent client…)"),
                      !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
                apps.append(app)
                BandwidthHogs.saveApps(apps)
            }
            Group {
                Text("Frees your internet for the call: these apps are frozen while a call is on (uploads and downloads stop) and carry on where they left off when it ends. A frozen app doesn't respond if you click it during the call. Never the app you're calling in, and never longer than 3 hours.")
            }
            .footerNote()
        } header: {
            Text("During calls, pause these apps")
        }
    }
}
