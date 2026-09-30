import AppKit

/// Pauses whatever you are watching or listening to, and resumes exactly that later.
/// - Spotify and Music: AppleScript ("pause if playing").
/// - Browser tabs (Netflix, YouTube…): paused inside each tab, meeting tabs skipped (BrowserMedia).
/// - Everything else (VLC, QuickTime, TV…): the keyboard ⏯ key, routed to the Now Playing app.
/// - Safety net: anything macOS still reports as Now Playing that none of those handled gets a real
///   Pause (NowPlaying), and Play when you're back.
final class MediaController: @unchecked Sendable {
    private var pausedPlayers: [String] = []
    /// Spotify / Music turned down instead of paused (the "lower volume" option), with the volume
    /// each had before, to put back.
    private var loweredPlayers: [String: Int] = [:]
    private var pausedBrowsers: [String] = []
    private var sentMediaKey = false
    /// What Now Playing showed when it was paused (resumed only if it's still the same thing).
    private var pausedNowPlaying: NowPlaying.State?
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
    func pause(keyTargetPlaying: Bool, browsers: [String], browserKeyFallback: Bool, allowLowering: Bool = true) -> Bool {
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
        for bundleID in AppClassifier.scriptablePlayers
        where isRunning(bundleID) && !pausedPlayers.contains(bundleID) && !IgnoredApps.contains(bundleID) {
            if allowLowering, Self.lowerInsteadOfPause, Self.lowerable.contains(bundleID) {
                guard loweredPlayers[bundleID] == nil else { continue }
                if let answer = run(bundleID, Self.lowerScript(to: Self.lowerLevel)), let before = Int(answer) {
                    loweredPlayers[bundleID] = before
                }
                continue
            }
            if run(bundleID, Self.pauseScript(bundleID)) == "paused" { pausedPlayers.append(bundleID) }
        }
        pauseNowPlayingIfUnhandled(browsers: browsers)
        return sentMediaKey || pausedNowPlaying != nil || !pausedPlayers.isEmpty || !pausedBrowsers.isEmpty
            || !loweredPlayers.isEmpty
    }

    func resume() {
        let keyWillBeSent = sentMediaKey
        _ = resumeNowPlaying()
        BrowserMedia.resumeAll(in: pausedBrowsers) { stillPaused in
            // The tab refused a scripted play (Netflix does this): ⏯ resumes it through the browser.
            guard stillPaused > 0, !keyWillBeSent else { return }
            Task { @MainActor in MediaKey.playPause() }
        }
        for bundleID in pausedPlayers where isRunning(bundleID) {
            _ = run(bundleID, Self.resumeScript(bundleID))
        }
        for (bundleID, volume) in loweredPlayers where isRunning(bundleID) {
            _ = run(bundleID, "set sound volume to \(volume)")
        }
        if sentMediaKey { MediaKey.playPause() }
        forget()
    }

    /// An extra safety net on top of the steps above, which work exactly as before: if macOS says
    /// something is still playing that none of them handled (an app with no AppleScript, a player
    /// they didn't recognise), pause it with a real Pause. Skipped whenever one of the older steps
    /// is dealing with the same app, or the ⏯ key was pressed, so the two can never cancel out.
    private func pauseNowPlayingIfUnhandled(browsers: [String]) {
        guard !sentMediaKey, pausedNowPlaying == nil,
              let nowPlaying = NowPlaying.latest, nowPlaying.pausable else { return }
        if let app = nowPlaying.bundleID {
            let handled = browsers.contains { app.hasPrefix($0) }
                || AppClassifier.scriptablePlayers.contains { app.hasPrefix($0) }
            guard !handled else { return }
        } else if !browsers.isEmpty || !pausedPlayers.isEmpty {
            return // can't tell which app it is, and something else is already being paused
        }
        NowPlaying.pause()
        pausedNowPlaying = nowPlaying
    }

    /// Plays what Now Playing paused, unless you've since switched to something else.
    private func resumeNowPlaying() -> Bool {
        guard let paused = pausedNowPlaying else { return false }
        let current = NowPlaying.latest
        if current?.playing == true { return true } // already playing again (you, or a script above)
        if let was = paused.bundleID, let now = current?.bundleID, was != now { return false }
        NowPlaying.play()
        return true
    }

    func forget() {
        loweredPlayers = [:]
        pausedNowPlaying = nil
        generation += 1
        pausedPlayers = []
        pausedBrowsers = []
        sentMediaKey = false
    }

    // MARK: Lower instead of pause (Settings → Calls & Media)

    /// Players with their own volume that AppleScript can set.
    private static let lowerable: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private static var lowerInsteadOfPause: Bool {
        UserDefaults.standard.string(forKey: SettingsKey.musicAction) == MusicAction.lower.rawValue
    }

    /// 0…100, the player's own volume scale.
    private static var lowerLevel: Int {
        let level = UserDefaults.standard.object(forKey: SettingsKey.musicLowerLevel) as? Double ?? 0.2
        return max(0, min(100, Int((level * 100).rounded())))
    }

    /// "If playing, remember the volume and turn it down", answering the old volume.
    private static func lowerScript(to level: Int) -> String {
        "if player state is playing then\nset v to sound volume\nif v > \(level) then set sound volume to \(level)\nreturn v as text\nend if\nreturn \"idle\""
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
