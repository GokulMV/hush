import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import ServiceManagement
import UserNotifications

/// Live status of every permission Hush uses, for the Permissions menu.
enum Permissions {
    enum Status {
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

    static func rows() -> [Row] {
        refreshNotificationStatus()
        var rows = [
            Row(name: "Camera", purpose: "see if you're at your desk or on the phone",
                status: cameraStatus, settingsURL: privacy("Privacy_Camera")),
            Row(name: "Accessibility", purpose: "press camera/mute in Meet, Zoom, Teams… and the ⏯ key",
                status: accessibilityGranted ? .granted : .denied, settingsURL: privacy("Privacy_Accessibility")),
        ]
        var automated = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        if BrowserMedia.enabled { // browsers are only contacted when the advanced option is on
            automated += [("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"),
                          ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"), ("com.vivaldi.Vivaldi", "Vivaldi")]
        }
        for (bundleID, name) in automated
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            rows.append(Row(name: "Automation → \(name)", purpose: "pause and resume media in \(name)",
                            status: automationStatus(bundleID), settingsURL: privacy("Privacy_Automation")))
        }
        rows.append(Row(name: "Notifications", purpose: "tell you when it mutes you",
                        status: notificationStatus,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.notifications"))
        rows.append(Row(name: "Open at Login", purpose: "start with your Mac",
                        status: SMAppService.mainApp.status == .enabled ? .granted : .unknown("off"),
                        settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))
        return rows
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
