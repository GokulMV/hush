import AppKit
import ApplicationServices

/// Turns your camera and microphone off, and later back on, *inside* the meeting app,
/// so the meeting shows you as muted with video off. It works in any app or web page with
/// labelled buttons: Google Meet, Teams, Webex, Slack huddles, Discord, Zoom (web and app)…
///
/// It uses the Accessibility API, like VoiceOver does: it finds the button whose label is
/// "Turn off camera" (Meet), "Turn camera off" (Teams), "Stop video" (Webex/Zoom)… and presses it.
/// Buttons only offer the action that changes the current state, so "turn off" can never turn
/// something on. Zoom's desktop app is driven through its Meeting menu, which is faster.
///
/// All work runs on one background queue, in order, so the menu bar never stalls.
final class MeetingControl: @unchecked Sendable {
    enum Kind: CaseIterable { case video, audio }

    static let shared = MeetingControl()

    private let queue = DispatchQueue(label: "hush.meeting-control")
    /// Apps where Hush switched something off and must switch it back on. Only touched on `queue`.
    private var switchedOff: [Kind: Set<pid_t>] = [:]
    /// Mirrors `switchedOff` for the menu; read on any thread.
    private let displayLock = NSLock()
    private var displayState: Set<Kind> = []

    // MARK: Public API

    /// Switches camera or mic off in every given app that currently has it on.
    func turnOff(_ kind: Kind, in pids: [pid_t]) {
        queue.async { [self] in
            for pid in pids where !(switchedOff[kind]?.contains(pid) ?? false) {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                if press(kind, on: false, in: app) {
                    switchedOff[kind, default: []].insert(pid)
                }
            }
            publish()
        }
    }

    /// Switches back on whatever `turnOff` switched off.
    func restore(_ kind: Kind) {
        queue.async { [self] in
            for pid in switchedOff[kind] ?? [] {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                _ = press(kind, on: true, in: app)
            }
            switchedOff[kind] = nil
            publish()
        }
    }

    /// Browsers and Electron apps (Chrome, Edge, Brave, Arc, Teams, Slack, Discord) hide web
    /// content from accessibility tools until asked. Call this when a call starts so it's ready.
    func prepare(_ pids: [pid_t]) {
        queue.async { [self] in
            for pid in pids { exposeWebContent(pid) }
        }
    }

    func isSwitchedOff(_ kind: Kind) -> Bool {
        displayLock.lock()
        defer { displayLock.unlock() }
        return displayState.contains(kind)
    }

    /// For the "Test Meeting Controls" menu item: what Hush can see in each app, in plain words.
    func diagnose(_ pids: [pid_t], completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            // Browsers first: they're reached through JavaScript, not Accessibility.
            var lines: [String] = []
            var accessibilityPIDs: [pid_t] = []
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                let name = app.localizedName ?? "App \(pid)"
                guard BrowserMedia.enabled, let bundleID = app.bundleIdentifier, BrowserMedia.supported[bundleID] != nil else {
                    accessibilityPIDs.append(pid)
                    continue
                }
                let allLabels = Kind.allCases.flatMap { Self.labels($0, on: false) + Self.labels($0, on: true) }
                switch BrowserMedia.meetingButton(in: bundleID, labels: allLabels, click: false) {
                case .count(let found) where found > 0:
                    lines.append("✅ \(name): meeting buttons found (via JavaScript)")
                    continue
                case .blocked:
                    lines.append("❌ \(name): " + BrowserMedia.howToAllow(bundleID))
                case .notAuthorized:
                    lines.append("❌ \(name): Automation is off. System Settings → Privacy & Security → Automation → Hush → turn on \(name).")
                default:
                    break
                }
                accessibilityPIDs.append(pid) // also try Accessibility below
            }

            guard AXIsProcessTrusted() else {
                lines.append("""
                    ❌ Hush isn't allowed to use Accessibility, so it can't press Meet's buttons.

                    Open System Settings → Privacy & Security → Accessibility, select Hush, press “–” to \
                    remove it, then press “+” and add /Applications/Hush.app again. (Each rebuild changes the \
                    app's signature, so an old ✓ there no longer counts.)
                    """)
                completion(lines.joined(separator: "\n\n"))
                return
            }
            guard !accessibilityPIDs.isEmpty || !lines.isEmpty else {
                completion("No meeting app or browser is running. Join a meeting, then try again.")
                return
            }
            for pid in accessibilityPIDs {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                let name = app.localizedName ?? "App \(pid)"
                exposeWebContent(pid)
                Thread.sleep(forTimeInterval: 0.6)
                var found: [String] = []
                let scanned = walk(pid: pid) { _, texts in
                    for text in texts where Kind.allCases.contains(where: { kind in
                        (Self.labels(kind, on: false) + Self.labels(kind, on: true)).contains { Self.matches(text, $0) }
                    }) {
                        found.append(text)
                    }
                    return false
                }
                if found.isEmpty {
                    lines.append("⚪️ \(name): no camera/mute buttons found (\(scanned) items checked). "
                        + "If your meeting is here, make sure its tab is the selected tab in its window.")
                } else {
                    lines.append("✅ \(name): found " + found.prefix(4).map { "“\($0)”" }.joined(separator: ", "))
                }
            }
            completion(lines.joined(separator: "\n\n"))
        }
    }

    // MARK: Pressing

    private func press(_ kind: Kind, on: Bool, in app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let labels = Self.labels(kind, on: on)
        // Browsers: ask the meeting tab to click its own button (needs "Allow JavaScript from
        // Apple Events"; no Accessibility needed). Most reliable, as browsers often hide pages
        // from Accessibility.
        if BrowserMedia.enabled, let bundleID = app.bundleIdentifier, BrowserMedia.supported[bundleID] != nil,
           case .count(let clicked) = BrowserMedia.meetingButton(in: bundleID, labels: labels, click: true), clicked > 0 {
            if on { finishTurningOn(kind, in: bundleID) }
            return true
        }
        guard AXIsProcessTrusted() else { return false }
        if app.bundleIdentifier == "us.zoom.xos", pressZoomMenu(kind, on: on, pid: pid) {
            return true
        }
        // A browser that was just asked to expose its page needs a moment to build the tree.
        for delay in [0, 0.6, 1.0] {
            if delay > 0 {
                exposeWebContent(pid)
                Thread.sleep(forTimeInterval: delay)
            }
            if let button = findButton(pid: pid, labels: labels) {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Chrome listens to AXEnhancedUserInterface (what VoiceOver sets); Electron apps to
    /// AXManualAccessibility. Only sent to browsers/Electron meeting apps, never to Zoom's app.
    private func exposeWebContent(_ pid: pid_t) {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              AppClassifier.isMeetingHost(bundleID), bundleID != "us.zoom.xos" else { return }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Browsers throttle background tabs, so a meeting may not finish turning the camera/mic back on
    /// until its tab is visible. Check a moment later; if it's still off, bring the meeting tab to
    /// the front and, only if it's *still* off there, click once more (never a blind second toggle).
    private func finishTurningOn(_ kind: Kind, in bundleID: String) {
        let turnOn = Self.labels(kind, on: true)
        func stillOff() -> Bool {
            if case .count(let n) = BrowserMedia.meetingButton(in: bundleID, labels: turnOn, click: false) { return n > 0 }
            return false
        }
        Thread.sleep(forTimeInterval: 1.5)
        guard stillOff(), BrowserMedia.focusMeetingTab(in: bundleID) else { return }
        Thread.sleep(forTimeInterval: 1.5) // the queued click often completes once the tab is visible
        if stillOff() {
            _ = BrowserMedia.meetingButton(in: bundleID, labels: turnOn, click: true)
        }
        Notifier.post("Your meeting is in front again",
                      "Hush brought the meeting tab forward so it could turn your \(kind == .video ? "camera" : "microphone") back on.")
    }

    /// Button labels (lower-cased) that perform the wanted change. Real labels often carry a
    /// shortcut, e.g. Meet's "Turn off camera (⌘ + e)"; `matches` allows for that.
    static func labels(_ kind: Kind, on: Bool) -> [String] {
        switch (kind, on) {
        case (.video, false):
            return ["turn off camera", "turn camera off", "stop video", "stop my video", "stop camera",
                    "disable camera", "hide video", "video off"]
        case (.video, true):
            return ["turn on camera", "turn camera on", "start video", "start my video", "start camera",
                    "enable camera", "show video", "video on"]
        case (.audio, false):
            return ["turn off microphone", "turn microphone off", "turn off mic", "mute microphone", "mute mic",
                    "mute audio", "mute myself", "mute"]
        case (.audio, true):
            return ["turn on microphone", "turn microphone on", "turn on mic", "unmute microphone", "unmute mic",
                    "unmute audio", "unmute myself", "unmute"]
        }
    }

    /// "Turn off camera (⌘ + e)" matches "turn off camera"; "mute notifications" does not match "mute".
    static func matches(_ label: String, _ phrase: String) -> Bool {
        let text = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(phrase) else { return false }
        let rest = text.dropFirst(phrase.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("(") || rest.hasPrefix(",") || rest.hasPrefix("⌘") || rest.hasPrefix("⌃")
    }

    // MARK: Accessibility tree search

    private static let pressableRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton"]
    private static let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                     kAXHelpAttribute, kAXChildrenAttribute] as CFArray

    /// First pressable element whose label performs the wanted change.
    private func findButton(pid: pid_t, labels: [String]) -> AXUIElement? {
        var match: AXUIElement?
        walk(pid: pid) { element, texts in
            guard texts.contains(where: { text in labels.contains { Self.matches(text, $0) } }) else { return false }
            match = element
            return true
        }
        return match
    }

    /// Breadth-first over the app's windows (meeting-looking windows first), calling `visit` with
    /// each button's labels until it returns true. Capped so a huge page can't hang us.
    /// Returns how many elements were checked.
    @discardableResult
    private func walk(pid: pid_t, visit: (AXUIElement, [String]) -> Bool) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var windows = elements(app, kAXWindowsAttribute)
        let hints = ["meet", "teams", "zoom", "webex", "huddle", "call", "meeting", "discord", "facetime"]
        windows.sort { a, b in
            let aHit = hints.contains { (string(a, kAXTitleAttribute)?.lowercased() ?? "").contains($0) }
            let bHit = hints.contains { (string(b, kAXTitleAttribute)?.lowercased() ?? "").contains($0) }
            return aHit && !bHit
        }

        var checked = 0
        for window in windows {
            var queue = [window]
            var index = 0
            while index < queue.count && index < 15000 {
                let element = queue[index]
                index += 1
                checked += 1
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                      let list = values as? [AnyObject], list.count == 5 else { continue }
                if let role = list[0] as? String, Self.pressableRoles.contains(role) {
                    let texts = [list[1], list[2], list[3]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                    if !texts.isEmpty && visit(element, texts) { return checked }
                }
                if let children = list[4] as? [AXUIElement] { queue.append(contentsOf: children) }
            }
        }
        return checked
    }

    // MARK: Zoom desktop app (menu bar: Meeting → Stop Video / Mute Audio …)

    private func pressZoomMenu(_ kind: Kind, on: Bool, pid: pid_t) -> Bool {
        let title: String
        switch (kind, on) {
        case (.video, false): title = "stop video"
        case (.video, true): title = "start video"
        case (.audio, false): title = "mute audio"
        case (.audio, true): title = "unmute audio"
        }
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = element(app, kAXMenuBarAttribute) else { return false }
        let barItems = elements(menuBar, kAXChildrenAttribute)
        let meeting = barItems.filter { string($0, kAXTitleAttribute)?.caseInsensitiveCompare("Meeting") == .orderedSame }
        for barItem in meeting.isEmpty ? barItems : meeting {
            for menu in elements(barItem, kAXChildrenAttribute) {
                for item in elements(menu, kAXChildrenAttribute) where string(item, kAXTitleAttribute)?.lowercased() == title {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    // MARK: AX helpers

    private func element(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ of: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ of: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func publish() {
        let state = Set(Kind.allCases.filter { !(switchedOff[$0]?.isEmpty ?? true) })
        displayLock.lock()
        displayState = state
        displayLock.unlock()
    }
}
