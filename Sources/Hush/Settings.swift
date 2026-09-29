import Foundation

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.presenceEnabled: true,
            Key.alwaysWatch: false,
            Key.phoneDetection: true,
            Key.awayMuteMic: true,
            Key.awayZoomVideoOff: true,
            Key.awayPauseMedia: true,
            Key.awayDelay: 2.0,
            Key.callPauseMedia: true,
            Key.callMuteOnJoin: false,
            Key.ringProtect: true,
            Key.duckLevel: 0.3,
            Key.autoResumeMedia: true,
            Key.showNotifications: true,
            Key.browserScripting: false,
            Key.autoCheckUpdates: true,
        ])
    }

    typealias Key = SettingsKey

    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func toggle(_ key: String) { defaults.set(!bool(key), forKey: key) }

    var enabled: Bool { bool(Key.enabled) }
    var presenceEnabled: Bool { bool(Key.presenceEnabled) }

    /// When a timed camera pause ends, or nil if the camera isn't paused.
    var cameraPausedUntil: Date? {
        let until = defaults.double(forKey: Key.cameraPausedUntil)
        return until > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: until) : nil
    }

    /// The camera may be used right now: switched on and not paused.
    var cameraActive: Bool { presenceEnabled && cameraPausedUntil == nil }

    func setCamera(on: Bool) {
        defaults.set(on, forKey: Key.presenceEnabled)
        defaults.set(0.0, forKey: Key.cameraPausedUntil)
    }

    func pauseCamera(for seconds: TimeInterval) {
        defaults.set(true, forKey: Key.presenceEnabled)
        defaults.set(Date().addingTimeInterval(seconds).timeIntervalSince1970, forKey: Key.cameraPausedUntil)
    }
    var phoneDetection: Bool { bool(Key.phoneDetection) }
    var callPauseMedia: Bool { bool(Key.callPauseMedia) }
    var callMuteOnJoin: Bool { bool(Key.callMuteOnJoin) }
    var ringProtect: Bool { bool(Key.ringProtect) }
    var autoResumeMedia: Bool { bool(Key.autoResumeMedia) }

    var awayDelay: TimeInterval {
        get { defaults.double(forKey: Key.awayDelay) }
        set { defaults.set(newValue, forKey: Key.awayDelay) }
    }

    var duckLevel: Float32 {
        get { Float32(defaults.double(forKey: Key.duckLevel)) }
        set { defaults.set(Double(newValue), forKey: Key.duckLevel) }
    }

    /// What to take away when you walk off or put a phone to your ear.
    var awayResources: [Resource] {
        var resources: [Resource] = []
        if bool(Key.awayMuteMic) { resources += [.mic, .meetingAudio] }
        if bool(Key.awayZoomVideoOff) { resources.append(.meetingVideo) }
        if bool(Key.awayPauseMedia) { resources.append(.media) }
        return resources
    }
}

/// UserDefaults keys, shared by the engine and the SwiftUI settings window.
enum SettingsKey {
    static let enabled = "enabled"
    static let presenceEnabled = "presenceEnabled"
    static let alwaysWatch = "alwaysWatch"
    /// Seconds since 1970; the camera stays off until then (0 = not paused).
    static let cameraPausedUntil = "cameraPausedUntil"
    static let phoneDetection = "phoneDetection"
    static let awayMuteMic = "awayMuteMic"
    static let awayZoomVideoOff = "awayZoomVideoOff"
    static let awayPauseMedia = "awayPauseMedia"
    static let awayDelay = "awayDelay"
    static let callPauseMedia = "callPauseMedia"
    static let callMuteOnJoin = "callMuteOnJoin"
    static let ringProtect = "ringProtect"
    static let duckLevel = "duckLevel"
    static let autoResumeMedia = "autoResumeMedia"
    static let showNotifications = "showNotifications"
    /// Advanced, off by default: talk to browsers through "Allow JavaScript from Apple Events".
    static let browserScripting = "browserScripting"
    static let autoCheckUpdates = "autoCheckUpdates"
    /// The version that ran last, to show "What's New" once after an upgrade.
    static let lastRunVersion = "lastRunVersion"
    static let hasShownWelcome = "hasShownWelcome"
    static let hasCompletedSetup = "hasCompletedSetup"
}
