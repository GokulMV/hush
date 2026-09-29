import AppKit
import ApplicationServices

/// Reads the tab bar of Chromium browsers (Chrome, Brave, Edge, Vivaldi, Arc, Opera) through
/// Accessibility. Their tabs are named with what they're doing, e.g. "Netflix - Audio playing"
/// or "Meet - xyz - Camera and microphone recording", so Hush can tell a video playing next to a
/// meeting without any browser setting. Synchronous and quick (only the browser's own UI).
enum BrowserTabs {
    enum Audibility { case videoPlaying, nothingPlaying, unknown }

    private static let chromiumPrefixes = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]
    private static let meetingWords = ["recording", "google meet", "meet -", "zoom", "teams", "webex",
                                       "huddle", "whereby", "jitsi", "discord"]
    private static let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                     kAXChildrenAttribute] as CFArray

    /// Is a tab other than a meeting playing sound? `.unknown` for non-Chromium browsers, without
    /// Accessibility, or when no tabs could be read (callers then fall back to other signals).
    static func audibility(of app: NSRunningApplication) -> Audibility {
        // The tab labels ("Audio playing") are in the browser's UI language, which follows the Mac's.
        guard Locale.preferredLanguages.first?.hasPrefix("en") ?? false,
              let bundleID = app.bundleIdentifier,
              chromiumPrefixes.contains(where: { bundleID.hasPrefix($0) }),
              AXIsProcessTrusted() else { return .unknown }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let queueStart = windows as? [AXUIElement] else { return .unknown }

        // Accessibility only lists windows on the current desktop (Space). If the browser has windows
        // elsewhere (e.g. Netflix on another desktop or screen), "nothing playing" can't be known.
        if windowCountOnAllDesktops(app.processIdentifier) > queueStart.count { return .unknown }

        var queue = queueStart
        var index = 0
        var sawTab = false
        while index < queue.count && index < 5000 {
            let element = queue[index]
            index += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 4 else { continue }
            let role = list[0] as? String ?? ""
            let text = [list[1], list[2]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            if role == "AXRadioButton" || role == "AXTab" { sawTab = true }
            if text.contains("audio playing") && !meetingWords.contains(where: { text.contains($0) }) {
                return .videoPlaying
            }
            // Web page content is huge and irrelevant here; only the browser's own UI is walked.
            if role == "AXWebArea" { continue }
            if let children = list[3] as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return sawTab ? .nothingPlaying : .unknown
    }

    /// Normal-sized windows the app has on every desktop and screen, minimised or not.
    /// Window *counts* need no Screen Recording permission (only titles would).
    private static func windowCountOnAllDesktops(_ pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        return list.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 200, (bounds["Height"] ?? 0) > 150 else { return false }
            return true
        }.count
    }
}
