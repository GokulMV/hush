import AppKit
import Combine
import SwiftUI

/// Version numbers like "1.2.10", compared number by number ("1.2.10" > "1.2.9").
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        description = cleaned
        parts = cleaned.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The GitHub repo that publishes releases ("owner/name"), written into Info.plist by the release script.
    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "GitHubRepo") as? String ?? "GokulMV/hush"
    }

    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/over-and-out", "/usr/local/Caskroom/over-and-out"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Checks GitHub Releases for a newer Over&Out and installs it (through Homebrew when that's how Over&Out
/// was installed, otherwise by opening the download page). Checks once a day by itself.
@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, noReleases, installing
        case available(version: String, notes: String, page: URL)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published private(set) var lastChecked: Date?

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedKey = "notifiedUpdateVersion"

    var availableVersion: String? {
        if case .available(let version, _, _) = state { return version }
        return nil
    }

    init() {
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Daily background checks (when "Check for updates automatically" is on).
    func startAutomaticChecks() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard defaults.bool(forKey: SettingsKey.autoCheckUpdates) else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard state != .checking, state != .installing else { return }
        state = .checking
        Task { await runCheck(userInitiated: userInitiated) }
    }

    private func runCheck(userInitiated: Bool) async {
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OverAndOut/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            if status == 404 {
                state = .noReleases
                return
            }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                state = .failed("GitHub answered with status \(status).")
                return
            }
            let latest = AppVersion(tag)
            guard latest > AppVersion(AppInfo.version) else {
                state = .upToDate
                return
            }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(AppInfo.repo)/releases/latest")!
            state = .available(version: latest.description, notes: json["body"] as? String ?? "", page: page)
            if !userInitiated && defaults.string(forKey: Self.notifiedKey) != latest.description {
                defaults.set(latest.description, forKey: Self.notifiedKey)
                Notifier.post("Over&Out \(latest.description) is available",
                              "Open the Over&Out menu → Check for Updates to see what's new and install it.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Homebrew installs update through Homebrew (Over&Out quits, updates and reopens itself);
    /// other installs open the release page to download the new version.
    func install() {
        guard case .available(_, _, let page) = state else { return }
        guard AppInfo.installedWithHomebrew, let brew = AppInfo.brew else {
            NSWorkspace.shared.open(page)
            return
        }
        state = .installing
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OverAndOut-update.log").path
        // Detached, so it survives Homebrew quitting Over&Out; reopens Over&Out when done.
        let command = "nohup /bin/sh -c '\"\(brew)\" upgrade --cask gokulmv/tap/over-and-out; /usr/bin/tccutil reset Accessibility com.gokulmv.overandout; open -b com.gokulmv.overandout' > \"\(log)\" 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
            Notifier.post("Updating Over&Out…", "Over&Out will close and reopen by itself in a moment.")
        } catch {
            state = .failed("Couldn't start Homebrew: \(error.localizedDescription)")
        }
    }
}

/// Settings → Updates.
struct UpdatesView: View {
    @ObservedObject var model: UpdateModel
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Installed version")
                    Spacer()
                    Text(AppInfo.version).monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Check for updates automatically (daily)", isOn: $autoCheck)
                HStack {
                    Button("Check Now") { model.check(userInitiated: true) }
                        .disabled(model.state == .checking || model.state == .installing)
                    Spacer()
                    if let lastChecked = model.lastChecked {
                        Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(AppInfo.installedWithHomebrew
                     ? "Installed with Homebrew: updates install through Homebrew and Over&Out reopens by itself."
                     : "Updates open the download page. Installing with Homebrew (brew install --cask gokulmv/tap/over-and-out) makes updating one click.")
            }

            Section { status }

            Section("What's new in \(AppInfo.version)") {
                Text(Changelog.markdown(Changelog.notes(for: AppInfo.version) ?? "No notes for this version."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .idle:
            Text("Press Check Now to look for a newer version.").foregroundStyle(.secondary)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Over&Out is up to date.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .noReleases:
            Text("No releases have been published yet.").foregroundStyle(.secondary)
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Updating… Over&Out will reopen by itself.") }
        case .failed(let reason):
            Label("Couldn't check for updates: \(reason)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .available(let version, let notes, _):
            VStack(alignment: .leading, spacing: 10) {
                Label("Over&Out \(version) is available", systemImage: "arrow.down.circle.fill")
                    .font(.headline).foregroundStyle(.blue)
                if !notes.isEmpty {
                    ScrollView {
                        Text(Changelog.markdown(notes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                Button(AppInfo.installedWithHomebrew ? "Update Now" : "Download Update") { model.install() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
