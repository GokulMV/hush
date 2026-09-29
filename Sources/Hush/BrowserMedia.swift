import AppKit

/// Pauses videos and music playing in browser tabs (Netflix, YouTube, Prime…) and later resumes
/// exactly those, while leaving meeting tabs (Meet, Teams, Zoom, Webex…) untouched. This is what
/// makes "Netflix and Meet both in Chrome" work: the ⏯ key can't tell the two apart.
///
/// It asks the browser via AppleScript to run a tiny script in each tab: pause every playing
/// <video>/<audio> and tag it; resuming plays only tagged ones. Needs, once per browser:
/// Automation permission, and "Allow JavaScript from Apple Events" (Chrome: View → Developer;
/// Safari: Develop menu).
enum BrowserMedia {
    enum Dialect { case chromium, safari, arc }

    /// Advanced option (Settings → Advanced), off by default: nothing here talks to a browser
    /// unless the user turned it on, so nobody is asked for developer settings or Automation.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.browserScripting) }

    /// Browsers with the AppleScript "run JavaScript in tab" command.
    static let supported: [String: Dialect] = [
        "com.google.Chrome": .chromium, "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium, "com.vivaldi.Vivaldi": .chromium,
        "com.apple.Safari": .safari, "company.thebrowser.Browser": .arc,
    ]

    /// Browsers without an AppleScript command to run JavaScript in a page (shown as such in Setup).
    static let unsupported: [String: String] = [
        "org.mozilla.firefox": "Firefox", "com.operasoftware.Opera": "Opera", "app.zen-browser.zen": "Zen",
    ]

    /// Tabs never touched: pausing a meeting's own <audio>/<video> would silence the call.
    static let meetingURLParts = [
        "meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us/wc", "zoom.us/j",
        "app.zoom.us", "webex.com", "app.slack.com/huddle", "discord.com/channels", "whereby.com", "jitsi",
    ]

    private static let queue = DispatchQueue(label: "hush.browser-media") // keeps pause → resume in order

    private static let pauseJS = """
        (function(){var n=0;document.querySelectorAll('video,audio').forEach(function(m){\
        if(!m.paused&&!m.ended){m.pause();m.setAttribute('data-hush-paused','1');n++;}});return n;})()
        """
    /// Plays what `pauseAll` paused (the tagged elements), keeping the tag for the check below.
    private static let resumeJS = """
        (function(){var n=0;document.querySelectorAll('[data-hush-paused]').forEach(function(m){\
        var p=m.play();if(p&&p.catch){p.catch(function(){});}n++;});return n;})()
        """
    /// A moment later: how many are still paused (some players, e.g. Netflix, refuse a scripted
    /// play()), then clear the tags.
    private static let verifyJS = """
        (function(){var n=0;document.querySelectorAll('[data-hush-paused]').forEach(function(m){\
        if(m.paused){n++;}m.removeAttribute('data-hush-paused');});return n;})()
        """

    private static let countJS = """
        (function(){var n=0;document.querySelectorAll('video,audio').forEach(function(m){\
        if(!m.paused&&!m.ended){n++;}});return n;})()
        """

    /// For "Test Meeting Controls": can Hush pause media in each running browser? Changes nothing.
    static func status(completion: @escaping @Sendable (String) -> Void) {
        guard enabled else {
            completion("Videos are paused with the ⏯ key (no setup needed). Tab-by-tab pausing for a video "
                + "and a meeting in the same browser is an optional advanced setting (Settings → Advanced).")
            return
        }
        queue.async {
            let browsers = runningBrowsers
            guard !browsers.isEmpty else {
                completion("No supported browser is running.")
                return
            }
            let lines = browsers.map { browser -> String in
                switch run(browser, js: countJS) {
                case .count(let playing):
                    return "✅ \(name(browser)): can pause videos (\(playing) playing outside meeting tabs)"
                case .blocked:
                    return "❌ \(name(browser)): can't pause videos yet. " + howToAllow(browser)
                case .notAuthorized:
                    return "❌ \(name(browser)): Automation is off. System Settings → Privacy & Security → Automation → Hush → turn on \(name(browser))."
                case .failed:
                    return "⚪️ \(name(browser)): no answer (no windows open?)"
                }
            }
            completion(lines.joined(separator: "\n\n"))
        }
    }

    /// Bundle IDs of supported browsers that are running right now (never launches one).
    static var runningBrowsers: [String] {
        supported.keys.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }.sorted()
    }

    /// Is this audio process a supported browser? ("com.google.Chrome.helper" → yes, WebKit → Safari)
    static func isSupportedBrowserProcess(_ id: String) -> Bool {
        id.hasPrefix("com.apple.WebKit") || supported.keys.contains { id.hasPrefix($0) }
    }

    /// Calls back (on a background thread) with how many tabs' media was paused, and the
    /// browsers whose JavaScript-from-AppleScript setting is off.
    /// `unresolved`: browsers that couldn't be asked at all (setting off, permission denied, no answer);
    /// the caller may fall back to the ⏯ key for those.
    static func pauseAll(in browsers: [String],
                         completion: @escaping @Sendable (_ blocked: [String], _ notAuthorized: [String], _ unresolved: [String]) -> Void) {
        queue.async {
            var blocked: [String] = []
            var notAuthorized: [String] = []
            var unresolved: [String] = []
            for browser in browsers {
                switch run(browser, js: pauseJS) {
                case .count: break
                case .blocked: blocked.append(browser); unresolved.append(browser)
                case .notAuthorized: notAuthorized.append(browser); unresolved.append(browser)
                case .failed: unresolved.append(browser)
                }
            }
            completion(blocked, notAuthorized, unresolved)
        }
    }

    /// Resumes what `pauseAll` paused, then reports (on a background thread) how many media
    /// elements are still paused a moment later, so the caller can fall back to ⏯.
    static func resumeAll(in browsers: [String], completion: @escaping @Sendable (_ stillPaused: Int) -> Void = { _ in }) {
        guard !browsers.isEmpty else { return }
        queue.async {
            for browser in browsers { _ = run(browser, js: resumeJS) }
            Thread.sleep(forTimeInterval: 1.2)
            var stillPaused = 0
            for browser in browsers {
                if case .count(let n) = run(browser, js: verifyJS) { stillPaused += n }
            }
            completion(stillPaused)
        }
    }

    static func name(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    static func howToAllow(_ bundleID: String) -> String {
        switch supported[bundleID] {
        case .safari?:
            return "In Safari, turn on Settings → Advanced → “Show features for web developers”, then in the menu bar at the top of the screen choose Develop → “Allow JavaScript from Apple Events”."
        case .arc?:
            return "Arc runs it without a browser setting; if macOS asked whether Hush may control Arc, allow it under Privacy & Security → Automation."
        default:
            return "With \(name(bundleID)) in front, use the menu bar at the top of the screen: View → Developer → “Allow JavaScript from Apple Events” (not the browser's settings page)."
        }
    }

    // MARK: Meeting buttons inside browser tabs

    /// JavaScript that finds the meeting's button by its label (aria-label / tooltip), e.g. Meet's
    /// "Turn off camera (⌘ + e)", and clicks it (or only counts it when `click` is false).
    static func meetingButtonJS(labels: [String], click: Bool) -> String {
        let list = labels.map { "'\($0)'" }.joined(separator: ",")
        return "(function(){var L=[\(list)];var hit=null;"
            + "document.querySelectorAll('button,[role=button],[role=checkbox],[role=switch]').forEach(function(e){"
            + "if(hit){return;}var t=((e.getAttribute('aria-label')||e.getAttribute('data-tooltip')||'')+'').toLowerCase().trim();"
            + "for(var i=0;i<L.length;i++){var p=L[i];"
            + "if(t===p||t.indexOf(p+' (')===0||t.indexOf(p+',')===0||t.indexOf(p+' ⌘')===0){hit=e;break;}}});"
            + "if(!hit){return 0;}" + (click ? "hit.click();" : "") + "return 1;})()"
    }

    /// Clicks (or counts) a labelled button in the browser's meeting tabs. Synchronous; call off the main thread.
    static func meetingButton(in bundleID: String, labels: [String], click: Bool) -> Outcome {
        run(bundleID, js: meetingButtonJS(labels: labels, click: click), meetingTabsOnly: true)
    }

    /// Runs "1" in the front tab: answers whether this browser accepts JavaScript from Hush.
    static func probe(_ bundleID: String) -> Outcome {
        probeDetailed(bundleID).outcome
    }

    /// Like `probe`, plus the browser's own words (shown in Setup when something's wrong).
    static func probeDetailed(_ bundleID: String) -> (outcome: Outcome, message: String) {
        guard let dialect = supported[bundleID] else { return (.failed, "not a supported browser") }
        let script: String
        switch dialect {
        case .safari:
            script = "tell application id \"\(bundleID)\" to return (do JavaScript \"1\" in front document) as text"
        case .chromium:
            script = "tell application id \"\(bundleID)\" to return (execute active tab of front window javascript \"1\") as text"
        case .arc:
            script = "tell application id \"\(bundleID)\" to tell front window to tell active tab to return (execute javascript \"1\") as text"
        }
        guard let output = osascript(script) else { return (.failed, "couldn't run osascript") }
        if output.hasPrefix("ERR:") {
            let raw = String(output.dropFirst(4))
            let message = raw.lowercased()
            if message.contains("not authorized") || message.contains("-1743") { return (.notAuthorized, raw) }
            // Only the browser's specific refusal counts as "setting off"; anything else is shown as-is.
            let refusal = message.contains("turned off") || message.contains("allow javascript")
                || message.contains("apple events") && message.contains("javascript")
            return (refusal ? .blocked : .failed, raw)
        }
        return (.count(Int(output) ?? 1), output)
    }

    // MARK: AppleScript

    enum Outcome { case count(Int), blocked, notAuthorized, failed }

    /// Runs `js` in every tab that is not a meeting (or, with `meetingTabsOnly`, only in meeting tabs)
    /// and adds up the numbers it returns.
    private static func run(_ bundleID: String, js: String, meetingTabsOnly: Bool = false) -> Outcome {
        guard let dialect = supported[bundleID] else { return .failed }
        let isMeeting = meetingURLParts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let skip = meetingTabsOnly ? "not (\(isMeeting))" : isMeeting
        let runInTab: String
        switch dialect {
        case .safari: runInTab = "set r to (do JavaScript \"\(js)\" in t)"
        case .chromium: runInTab = "set r to (execute t javascript \"\(js)\")"
        case .arc: runInTab = "tell t to set r to (execute javascript \"\(js)\")"
        }
        let script = """
            tell application id "\(bundleID)"
                set total to 0
                set failure to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to ""
                        try
                            set u to (URL of t) as text
                        end try
                        if not (\(skip)) then
                            try
                                \(runInTab)
                                try
                                    set total to total + (r as integer)
                                end try
                            on error errMsg
                                set failure to errMsg
                            end try
                        end if
                    end repeat
                end repeat
                if failure is not "" and total is 0 then return "ERR:" & failure
                return total as text
            end tell
            """
        guard let output = osascript(script) else { return .failed }
        if output.hasPrefix("ERR:") {
            let message = output.lowercased()
            if message.contains("not authorized") || message.contains("-1743") { return .notAuthorized }
            return message.contains("javascript") ? .blocked : .failed
        }
        return .count(Int(output) ?? 0)
    }

    /// Runs off the main thread via /usr/bin/osascript (NSAppleScript must stay on the main thread).
    private static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return "ERR:" + text // e.g. Automation denied, or the JavaScript setting is off
        }
        return text
    }
}
