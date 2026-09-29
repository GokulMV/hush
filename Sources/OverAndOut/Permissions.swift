import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import ServiceManagement
import UserNotifications

/// Live status of every permission Over&Out uses, for the Permissions menu.
enum Permissions {
    enum Status: Equatable {
        case granted, denied, notAsked
        case unknown(String)

        var badge: String {
            switch self {
            case .granted: return "✅"
            case .denied: return "❌"
            case .notAsked: return "⚪️"
            case .unknown: return "➖"
            }
        }

        var label: String {
            switch self {
            case .granted: return "allowed"
            case .denied: return "denied"
            case .notAsked: return "not asked yet"
            case .unknown(let why): return why
            }
        }
    }

    struct Row {
        let name: String
        let purpose: String
        let status: Status
        let settingsURL: String
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Updated asynchronously (the API has no synchronous form); refreshed each time the menu opens.
    private static var notificationStatus: Status = .unknown("checking…")

    static func rows() -> [Row] { rows(automation: automationRows()) }

    /// Everything, with the Automation rows (slow: each one asks macOS about another app) passed in,
    /// so the quick rows can be shown right away while those are still being checked.
    static func rows(automation: [Row]) -> [Row] {
        refreshNotificationStatus()
        var rows = [
            Row(name: "Camera", purpose: "see if you're at your desk or on the phone",
                status: cameraStatus, settingsURL: privacy("Privacy_Camera")),
            Row(name: "Accessibility", purpose: "press camera/mute in Meet, Zoom, Teams… and the ⏯ key",
                status: accessibilityGranted ? .granted : .denied, settingsURL: privacy("Privacy_Accessibility")),
        ]
        rows += automation
        rows.append(Row(name: "Notifications", purpose: "tell you when it mutes you",
                        status: notificationStatus,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.notifications"))
        rows.append(Row(name: "Open at Login", purpose: "start with your Mac",
                        status: SMAppService.mainApp.status == .enabled ? .granted : .unknown("off"),
                        settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))
        return rows
    }

    private static var automatedApps: [(bundleID: String, name: String)] {
        var apps = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        if BrowserMedia.enabled { // browsers are only contacted when the advanced option is on
            apps += [("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"),
                     ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"), ("com.vivaldi.Vivaldi", "Vivaldi")]
        }
        return apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
    }

    private static func automationRow(_ app: (bundleID: String, name: String), _ status: Status) -> Row {
        Row(name: "Automation → \(app.name)", purpose: "pause and resume media in \(app.name)",
            status: status, settingsURL: privacy("Privacy_Automation"))
    }

    /// Placeholders shown while `automationRows()` runs.
    static func automationPlaceholders() -> [Row] {
        automatedApps.map { automationRow($0, .unknown("checking…")) }
    }

    /// Asks macOS about every app at once, each on its own thread, and waits at most 3 s in total:
    /// macOS sometimes never answers for an app (the page used to sit on "checking…" for good).
    /// Apps it doesn't answer for fall back to what Over&Out saw the last time it controlled them.
    /// Call off the main thread.
    static func automationRows() -> [Row] {
        let apps = automatedApps
        let lock = NSLock()
        var answers: [String: Status] = [:]
        let group = DispatchGroup()
        for app in apps {
            // One question per app at a time: if macOS still hasn't answered the last one, don't
            // pile up another thread behind it (its answer is picked up from `lastAnswer` later).
            observedLock.lock()
            let busy = !pendingChecks.insert(app.bundleID).inserted
            observedLock.unlock()
            if busy { continue }
            group.enter()
            Thread.detachNewThread {
                let status = automationStatus(app.bundleID)
                lock.lock(); answers[app.bundleID] = status; lock.unlock()
                observedLock.lock()
                pendingChecks.remove(app.bundleID)
                lastAnswer[app.bundleID] = status
                observedLock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
        lock.lock(); var answered = answers; lock.unlock()

        // No answer, but the app is open: ask the app itself something harmless ("get version").
        // It replies only if the permission is on; macOS refuses with -1743 if it's off. Never for
        // an app that isn't running (a command would launch it).
        let unanswered = apps.filter { app in
            answered[app.bundleID] == nil
                && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        }
        if !unanswered.isEmpty {
            let probes = DispatchGroup()
            for app in unanswered {
                probes.enter()
                DispatchQueue.global(qos: .utility).async {
                    if let status = probeAutomation(app.bundleID) {
                        lock.lock(); answers[app.bundleID] = status; lock.unlock()
                        recordAutomation(app.bundleID, allowed: status == .granted)
                    }
                    probes.leave()
                }
            }
            _ = probes.wait(timeout: .now() + 4)
            lock.lock(); answered = answers; lock.unlock()
        }
        observedLock.lock(); let previous = lastAnswer; observedLock.unlock()
        return apps.map { app in
            var status = answered[app.bundleID] ?? previous[app.bundleID] ?? .unknown("no answer from macOS")
            // "Unknown"/"open the app to check": what actually happened last time is more useful.
            if case .unknown = status, let seen = observed(app.bundleID) { status = seen }
            return automationRow(app, status)
        }
    }

    /// Sends the app a harmless command through osascript (killed after 3 s). nil: no clear answer.
    private static func probeAutomation(_ bundleID: String) -> Status? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(bundleID)\" to get version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 { return .granted }
        if text.contains("-1743") || text.lowercased().contains("not authorized") { return .denied }
        return nil
    }

    // What really happened the last time Over&Out controlled an app (a script ran, or macOS refused).
    private static let observedLock = NSLock()
    private static var observedStatus: [String: Status] = [:]
    private static var pendingChecks: Set<String> = []
    private static var lastAnswer: [String: Status] = [:]

    /// Called by the media and browser controllers after talking to an app.
    static func recordAutomation(_ bundleID: String, allowed: Bool) {
        observedLock.lock()
        observedStatus[bundleID] = allowed ? .granted : .denied
        observedLock.unlock()
    }

    private static func observed(_ bundleID: String) -> Status? {
        observedLock.lock(); defer { observedLock.unlock() }
        return observedStatus[bundleID]
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for Accessibility in a way that survives updates. macOS ties the ✓ to the exact app
    /// signature, so after an update the old Over&Out row can still look switched on while macOS
    /// ignores it — and toggling it does nothing. Clearing our own row first (only ours, by bundle ID)
    /// makes macOS add a fresh one for this version. Then it watches for the grant and says so.
    static func requestAccessibility(clearStaleEntry: Bool = true, prompt: Bool = true, openSettings: Bool = true) {
        guard !accessibilityGranted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if clearStaleEntry, let bundleID = Bundle.main.bundleIdentifier {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "Accessibility", bundleID]
                reset.standardOutput = FileHandle.nullDevice
                reset.standardError = FileHandle.nullDevice
                try? reset.run()
                reset.waitUntilExit()
            }
            DispatchQueue.main.async {
                if prompt { promptForAccessibility() }
                if openSettings { openPrivacySettings("Privacy_Accessibility") }
                watchForAccessibility()
            }
        }
    }

    private static var accessibilityWatch: Timer?

    /// Polls for up to 5 minutes after asking, and confirms as soon as the switch takes effect.
    private static func watchForAccessibility() {
        accessibilityWatch?.invalidate()
        let started = Date()
        accessibilityWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                Notifier.post("Accessibility is on", "Over&Out can now press camera/mute in meetings and pause media.")
            } else if Date().timeIntervalSince(started) > 5 * 60 {
                timer.invalidate()
            }
        }
    }

    static func openPrivacySettings(_ pane: String) {
        open(privacy(pane))
    }

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private static func privacy(_ pane: String) -> String {
        "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    }

    static var cameraStatus: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Checks Automation consent without showing a prompt.
    private static func automationStatus(_ bundleID: String) -> Status {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, Int(strlen(pointer)), &target)
        }
        guard OSStatus(created) == noErr else { return .unknown("unknown") }
        defer { _ = AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .unknown("open the app to check")
        default: return .unknown("unknown")
        }
    }

    /// Last known notification permission (refreshed in the background on each read).
    static var notificationsStatus: Status {
        refreshNotificationStatus()
        return notificationStatus
    }

    private static func refreshNotificationStatus() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationStatus = .unknown("needs the .app build")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .granted
            case .denied: status = .denied
            case .notDetermined: status = .notAsked
            default: status = .unknown("unknown")
            }
            DispatchQueue.main.async { notificationStatus = status }
        }
    }
}
