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

    /// Installed with Homebrew, or at least our tap is set up (Homebrew sometimes loses track of an
    /// app it installed; the updater then reinstalls over it).
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew", "/usr/local"].contains { prefix in
            FileManager.default.fileExists(atPath: prefix + "/Caskroom/over-and-out")
                || FileManager.default.fileExists(atPath: prefix + "/Library/Taps/gokulmv/homebrew-tap")
        }
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
        reportUpdateResult()
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
        var found = await Self.latestFromAPI()
        if found == nil { found = await Self.latestFromRedirect() }
        lastChecked = Date()
        defaults.set(lastChecked, forKey: Self.lastCheckKey)
        guard let found else {
            state = .failed("GitHub couldn't be reached. Check your internet connection and try again.")
            return
        }
        guard let tag = found.tag else {
            state = .noReleases
            return
        }
        let latest = AppVersion(tag)
        guard latest > AppVersion(AppInfo.version) else {
            state = .upToDate
            return
        }
        state = .available(version: latest.description, notes: found.notes, page: found.page)
        if !userInitiated && defaults.string(forKey: Self.notifiedKey) != latest.description {
            defaults.set(latest.description, forKey: Self.notifiedKey)
            Notifier.post("Over&Out \(latest.description) is available",
                          "Open the Over&Out menu → Check for Updates to see what's new and install it.")
        }
    }

    private struct LatestRelease {
        var tag: String? // nil: the repo has no releases
        var notes: String
        var page: URL
    }

    private static var releasesPage: URL { URL(string: "https://github.com/\(AppInfo.repo)/releases/latest")! }

    /// Never waits more than 15 s: a stalled connection used to leave "Checking…" up for good.
    private static func fetch(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("OverAndOut/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    /// GitHub's API: the newest release, with the notes of every release since the installed
    /// version (so skipping a few updates still shows everything that changed). nil when it fails
    /// (offline, or its hourly limit).
    private static func latestFromAPI() async -> LatestRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = await fetch(request), response.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let installed = AppVersion(AppInfo.version)
        let releases = list
            .filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }
            .compactMap { json -> (version: AppVersion, notes: String, page: URL?)? in
                guard let tag = json["tag_name"] as? String else { return nil }
                return (AppVersion(tag), releaseNotes(json["body"] as? String ?? ""),
                        (json["html_url"] as? String).flatMap(URL.init(string:)))
            }
            .sorted { $0.version > $1.version }
        guard let newest = releases.first else { return LatestRelease(tag: nil, notes: "", page: releasesPage) }
        let newer = releases.filter { $0.version > installed }
        let notes = newer.count <= 1
            ? newest.notes
            : newer.map { "**\($0.version.description)**\n\($0.notes)" }.joined(separator: "\n\n")
        return LatestRelease(tag: newest.version.description, notes: notes, page: newest.page ?? releasesPage)
    }

    /// A release's notes without the "Install with Homebrew" footer the release script adds for the
    /// GitHub page (inside the app it's just noise).
    nonisolated static func releaseNotes(_ body: String) -> String {
        let text = body.replacingOccurrences(of: "\r\n", with: "\n")
        let notes = text.range(of: "\n---\n").map { String(text[..<$0.lowerBound]) } ?? text
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback without the API's limit: github.com/…/releases/latest redirects to …/tag/v1.2.3.
    private static func latestFromRedirect() async -> LatestRelease? {
        guard let (_, response) = await fetch(URLRequest(url: releasesPage)), response.statusCode == 200,
              let final = response.url else { return nil }
        guard final.path.contains("/releases/tag/") else {
            return LatestRelease(tag: nil, notes: "", page: releasesPage) // no releases yet
        }
        return LatestRelease(tag: final.lastPathComponent, notes: "", page: final)
    }

    private static let pendingKey = "pendingUpdateVersion"
    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OverAndOut-update.log")
    }

    /// Homebrew installs update through Homebrew (Over&Out quits, updates and reopens itself);
    /// other installs open the release page to download the new version.
    func install() {
        guard case .available(let version, _, let page) = state else { return }
        guard AppInfo.installedWithHomebrew, let brew = AppInfo.brew else {
            NSWorkspace.shared.open(page)
            return
        }
        state = .installing
        defaults.set(version, forKey: Self.pendingKey)
        // `brew update` first: Homebrew only refreshes its list of versions about once a day, so
        // a bare `brew upgrade` often doesn't know the new version yet and quietly does nothing.
        // Run from a script file, detached, so it survives Homebrew quitting Over&Out.
        let script = """
        #!/bin/sh
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOMEBREW_NO_INSTALL_CLEANUP=1
        echo "Over&Out update to \(version), $(date)"
        "\(brew)" update --quiet
        # If Homebrew lost track of the app (it then refuses: "there is already an App at …"),
        # reinstall over it; settings and permissions are kept.
        "\(brew)" upgrade --cask gokulmv/tap/over-and-out \\
            || "\(brew)" install --cask --force gokulmv/tap/over-and-out
        echo "brew finished with status $?"
        open -b com.gokulmv.overandout
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("overandout-update.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \"\(scriptURL.path)\" > \"\(Self.logURL.path)\" 2>&1 &"]
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try process.run()
            Notifier.post("Updating Over&Out…", "Over&Out will close and reopen by itself in a moment.")
        } catch {
            defaults.removeObject(forKey: Self.pendingKey)
            state = .failed("Couldn't start Homebrew: \(error.localizedDescription)")
        }
    }

    /// After an update attempt, on the next launch: confirm it, or say plainly that it didn't happen.
    func reportUpdateResult() {
        guard let wanted = defaults.string(forKey: Self.pendingKey) else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        if AppVersion(AppInfo.version) >= AppVersion(wanted) {
            Notifier.post("Over&Out updated to \(AppInfo.version)", "Open the menu → What's New to see what changed.")
            return
        }
        let log = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
        let tail = log.split(separator: "\n").suffix(4).joined(separator: "\n")
        state = .failed("Homebrew didn't install \(wanted). You can run this in Terminal instead:\n"
                        + "brew update && brew upgrade --cask gokulmv/tap/over-and-out"
                        + (tail.isEmpty ? "" : "\n\nHomebrew said:\n\(tail)"))
        Notifier.post("Over&Out couldn't update itself", "Open Settings → Updates for what went wrong.")
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
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
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
