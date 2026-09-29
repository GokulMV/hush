import Foundation

/// Decides what a bundle ID seen by Core Audio means: a call, background noise, or media worth pausing.
enum AppClassifier {
    /// Apps whose microphone/speaker use means "you are in a call".
    static let callAppPrefixes = [
        "us.zoom.", "com.microsoft.teams", "com.apple.FaceTime", "com.apple.avconferenced",
        "com.apple.telephonyutilities", "Cisco-Systems.Spark", "com.cisco.webex",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.skype.", "net.whatsapp.", "com.whatsapp",
    ]

    /// Apps that can host a meeting, used to find the camera/mute buttons when the mic
    /// user can't be identified (macOS < 14.2) or outside a call (panic mode).
    static let meetingHostPrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webex", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.brave.Browser", "org.mozilla.firefox", "app.zen-browser.zen", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "net.whatsapp.", "com.whatsapp", "com.skype.", "com.apple.FaceTime",
    ]

    /// Mic users that are not a conversation (Siri, dictation, accessibility).
    static let ignoredMicPrefixes = [
        "com.apple.siri", "com.apple.Siri", "com.apple.assistant", "com.apple.corespeech",
        "com.apple.speech", "com.apple.SpeechRecognitionCore", "com.apple.dictation", "com.apple.accessibility",
    ]

    /// Apple processes that do play user media. Everything else under com.apple.* is system sound.
    static let appleMediaPrefixes = [
        "com.apple.WebKit", "com.apple.Safari", "com.apple.TV", "com.apple.QuickTimePlayerX",
        "com.apple.podcasts", "com.apple.Music",
    ]

    /// Players paused and resumed individually via AppleScript instead of the ⏯ key (which only ever
    /// reaches one app), so any number of them playing at once are all handled.
    static let scriptablePlayers = ["com.spotify.client", "com.apple.Music", "com.apple.TV",
                                    "org.videolan.vlc", "com.apple.QuickTimePlayerX"]

    /// Placeholder IDs used when macOS is older than 14.2 and per-app audio info is unavailable.
    static let unknownMicUser = "unknown-mic-user"
    static let unknownOutput = "system-output"

    /// Built-in hosts, plus the apps you added in Settings → Calls & Media.
    static func isMeetingHost(_ id: String) -> Bool {
        meetingHostPrefixes.contains { id.hasPrefix($0) } || CustomApps.contains(id)
    }

    static func isCallApp(_ id: String) -> Bool {
        callAppPrefixes.contains { id.hasPrefix($0) } || CustomApps.contains(id)
    }

    /// macOS's own background services (Siri and "Hey Siri" listening, dictation, voice control…)
    /// hold the mic without any call. They're ignored whatever their exact name or capitalisation
    /// ("com.apple.CoreSpeech" once kept a "call" going for good); Apple's calling services
    /// (FaceTime, iPhone calls) still count.
    static func countsAsCall(micUser id: String, ownBundleID: String?) -> Bool {
        guard id != ownBundleID else { return false }
        let lowered = id.lowercased()
        if ignoredMicPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return false }
        if lowered.hasPrefix("com.apple.") && !isCallApp(id) { return false }
        return true
    }

    /// True when sound from `id` is something you'd want paused (a video, music), not a call or a system chime.
    /// Spotify/Music are excluded here because they are handled by AppleScript.
    static func isMediaSource(_ id: String) -> Bool {
        if isCallApp(id) || scriptablePlayers.contains(id) { return false }
        if id == unknownOutput || !id.hasPrefix("com.apple.") { return true }
        return appleMediaPrefixes.contains { id.hasPrefix($0) }
    }
}
