import AppKit

/// Pauses whatever you are watching or listening to, and resumes exactly that later.
/// - Spotify and Music: AppleScript ("pause if playing").
/// - Browser tabs (Netflix, YouTube…): paused inside each tab, meeting tabs skipped (BrowserMedia).
/// - Everything else (VLC, QuickTime, TV…): the keyboard ⏯ key, routed to the Now Playing app.
final class MediaController: @unchecked Sendable {
    private var pausedPlayers: [String] = []
    private var pausedBrowsers: [String] = []
    private var sentMediaKey = false
    /// Bumped on every resume/forget so a late browser answer can't act on a finished pause.
    private var generation = 0

    /// Browsers whose "Allow JavaScript from Apple Events" is off, and ones Automation denied.
    var onBrowserProblem: (@MainActor (_ blocked: [String], _ notAuthorized: [String]) -> Void)?

    /// - keyTargetPlaying: a non-browser, non-scriptable source (VLC…) is playing. The ⏯ key is only
    ///   sent then, because it's a toggle and would otherwise *start* playback.
    /// - browsers: browsers with media playing, paused tab by tab (meeting tabs are skipped).
    /// - browserKeyFallback: if a browser refuses, the ⏯ key is safe to use instead (it isn't
    ///   also hosting the call).
    /// Returns true if anything was (or is being) paused.
    func pause(keyTargetPlaying: Bool, browsers: [String], browserKeyFallback: Bool) -> Bool {
        if keyTargetPlaying {
            MediaKey.playPause()
            sentMediaKey = true
        }
        if !browsers.isEmpty {
            pausedBrowsers = browsers
            let started = generation
            BrowserMedia.pauseAll(in: browsers) { [self] blocked, notAuthorized, unresolved in
                guard !unresolved.isEmpty else { return }
                Task { @MainActor in
                    guard started == generation else { return }
                    if !blocked.isEmpty || !notAuthorized.isEmpty { onBrowserProblem?(blocked, notAuthorized) }
                    // The browser couldn't be asked, so press ⏯ like before (when that's safe).
                    if browserKeyFallback && !sentMediaKey {
                        MediaKey.playPause()
                        sentMediaKey = true
                    }
                }
            }
        }
        for bundleID in AppClassifier.scriptablePlayers where isRunning(bundleID) && !pausedPlayers.contains(bundleID) {
            if run(bundleID, Self.pauseScript(bundleID)) == "paused" { pausedPlayers.append(bundleID) }
        }
        return sentMediaKey || !pausedPlayers.isEmpty || !pausedBrowsers.isEmpty
    }

    func resume() {
        let keyWillBeSent = sentMediaKey
        BrowserMedia.resumeAll(in: pausedBrowsers) { stillPaused in
            // The tab refused a scripted play (Netflix does this): ⏯ resumes it through the browser.
            guard stillPaused > 0, !keyWillBeSent else { return }
            Task { @MainActor in MediaKey.playPause() }
        }
        for bundleID in pausedPlayers where isRunning(bundleID) {
            _ = run(bundleID, Self.resumeScript(bundleID))
        }
        if sentMediaKey { MediaKey.playPause() }
        forget()
    }

    func forget() {
        generation += 1
        pausedPlayers = []
        pausedBrowsers = []
        sentMediaKey = false
    }

    /// "Pause if playing", answering "paused" when it did. Each app's AppleScript differs a little.
    private static func pauseScript(_ bundleID: String) -> String {
        switch bundleID {
        case "org.videolan.vlc": // VLC's `play` toggles
            return "if playing then\nplay\nreturn \"paused\"\nend if\nreturn \"idle\""
        case "com.apple.QuickTimePlayerX": // one app, possibly several movies
            return """
                set n to 0
                repeat with d in documents
                    if playing of d then
                        pause d
                        set n to n + 1
                    end if
                end repeat
                if n > 0 then return "paused"
                return "idle"
                """
        default: // Spotify, Music, TV
            return "if player state is playing then\npause\nreturn \"paused\"\nend if\nreturn \"idle\""
        }
    }

    private static func resumeScript(_ bundleID: String) -> String {
        switch bundleID {
        case "org.videolan.vlc": return "if not playing then play"
        case "com.apple.QuickTimePlayerX": return "repeat with d in documents\nplay d\nend repeat"
        default: return "play"
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func run(_ bundleID: String, _ body: String) -> String? {
        var error: NSDictionary?
        let source = "tell application id \"\(bundleID)\"\n\(body)\nend tell"
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let number = error?[NSAppleScript.errorNumber] as? Int, number == -1743 {
            Permissions.recordAutomation(bundleID, allowed: false)
        } else if result != nil {
            Permissions.recordAutomation(bundleID, allowed: true)
        }
        return result?.stringValue
    }
}

enum MediaKey {
    private static let playKey = 16 // NX_KEYTYPE_PLAY

    /// Presses the keyboard ⏯ key. Needs Accessibility permission.
    static func playPause() {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (playKey << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
