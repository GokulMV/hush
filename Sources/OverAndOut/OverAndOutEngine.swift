import AppKit

/// The brain: watches calls, the camera and what's playing, and decides what to take
/// away (mic, the meeting's mute/camera, media, volume) and when to give it back.
@MainActor
final class OverAndOutEngine {
    enum CallPhase: Equatable {
        case idle
        case ringing(since: Date)
        case inCall
    }

    private(set) var callPhase: CallPhase = .idle
    private(set) var callApps: Set<String> = []
    private(set) var presence: PresenceTracker.State = .present
    /// What the camera saw in its latest frame (nil while the camera is off).
    private(set) var lastReading: PresenceReading?
    /// Set while the Camera Preview window is open: keeps the camera on and receives every frame.
    var previewHandler: (@MainActor (PresenceAnalysis, CGImage?) -> Void)? {
        didSet { sensor.wantsPreviewFrames = previewHandler != nil }
    }
    private(set) var unmutableMics: [String] = []
    private(set) var ledger = Ledger()
    var onChange: (@MainActor () -> Void)?

    var isSensing: Bool { sensor.isRunning }
    /// The camera session is running but no video is arriving (see the watchdog in updateSensing).
    var cameraStalled: Bool { sensor.isStalled }
    private var lastCameraRestart = Date.distantPast
    var panicActive: Bool { ledger.isEngaged(.panic) }

    private let settings: Settings
    private let media = MediaController()
    private let sensor = PresenceSensor()
    private var tracker = PresenceTracker()
    private var applied: Set<Resource> = []
    private var outputSince: [String: Date] = [:]
    private var perProcessAudio = true
    private var lastMicSeen: Date?
    private var callStartedAt: Date?
    private var sensingIdleSince: Date?
    private var cameraWasPaused = false
    private var warnedAboutAccessibility = false
    private let ownBundleID = Bundle.main.bundleIdentifier

    /// Mic must stay silent this long before a call counts as over (apps briefly reopen the mic).
    static let callEndGrace: TimeInterval = 4
    /// An unanswered ring stops mattering after this.
    static let ringTimeout: TimeInterval = 45
    /// Sound must have been playing this long before a call to count as "you were watching something".
    static let steadyPlayback: TimeInterval = 3
    /// Keep the camera on this long after it stops being needed, to avoid flapping.
    static let sensingLinger: TimeInterval = 15

    init() {
        settings = Settings.shared
        // Undo anything a previous crash left behind.
        MicMuter.unmute()
        VolumeDucker.restoreInBackground()

        sensor.onAnalysis = { [weak self] analysis, image in
            self?.previewHandler?(analysis, image)
            self?.handle(analysis.reading)
        }
        media.onBrowserProblem = { [weak self] blocked, notAuthorized in
            self?.reportBrowserProblem(blocked: blocked, notAuthorized: notAuthorized)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            Task { @MainActor in self?.appLaunched(bundleID) }
        }
    }

    // MARK: Heartbeat (once a second)

    /// Which apps use the mic and speakers, sampled in the background: every Core Audio query is a
    /// round trip to coreaudiod, and when that daemon is busy a query on the main thread froze the
    /// whole app ("Not Responding"). The main thread only ever reads the latest finished sample.
    private var latestActivity: AudioActivity?
    private var sampling = false

    private func sampleActivity() {
        guard !sampling else { return } // a slow sample is still running: don't pile up
        sampling = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let activity = AudioDevices.activity()
            await MainActor.run {
                self?.latestActivity = activity
                self?.sampling = false
            }
        }
    }

    func poll() {
        let now = Date()
        sampleActivity()
        guard let activity = latestActivity else {
            onChange?()
            return
        }
        perProcessAudio = activity.perProcess
        callApps = activity.micUsers.filter { AppClassifier.countsAsCall(micUser: $0, ownBundleID: ownBundleID) }
        for id in activity.outputUsers where outputSince[id] == nil { outputSince[id] = now }
        outputSince = outputSince.filter { activity.outputUsers.contains($0.key) }

        noticeCameraPauseEnding()
        if settings.enabled {
            updateCallPhase(now)
            updateSensing(now)
        } else {
            suspend()
        }

        // Keep the hard mute airtight: new mics, apps that auto-raise input volume.
        MicMuter.enforceInBackground()
        MicMuter.restoreReconnected()
        onChange?()
    }

    private func updateCallPhase(_ now: Date) {
        let micBusy = !callApps.isEmpty
        if micBusy { lastMicSeen = now }

        switch callPhase {
        case .idle:
            if micBusy { callStarted() }
        case .ringing(let since):
            if micBusy {
                callStarted()
            } else if now.timeIntervalSince(since) > Self.ringTimeout {
                callPhase = .idle
                release(.ring)
            }
        case .inCall:
            if !micBusy, let last = lastMicSeen, now.timeIntervalSince(last) > Self.callEndGrace {
                callEnded()
            }
        }
    }

    private func callStarted() {
        callPhase = .inCall
        callStartedAt = Date()
        MeetingControl.shared.prepare(meetingApps())
        var resources: [Resource] = []
        if settings.callPauseMedia { resources.append(.media) }
        if settings.callMuteOnJoin { resources += [.mic, .meetingAudio] }
        engage(.call, resources)
        release(.ring) // answered: stop ducking so you can hear the caller
        if settings.callMuteOnJoin {
            Notifier.post("Muted as your call started", "Press ⌃⌥⌘M to unmute.")
        }
    }

    private func callEnded() {
        callPhase = .idle
        callStartedAt = nil
        lastMicSeen = nil
        release(.call)
        release(.manual) // a manual mute lasts until you unmute or the call ends
    }

    /// Incoming iPhone/FaceTime calls launch FaceTime on the Mac: treat that as ringing.
    private func appLaunched(_ bundleID: String) {
        guard bundleID == "com.apple.FaceTime", callPhase == .idle, settings.ringProtect else { return }
        callPhase = .ringing(since: Date())
        engage(.ring, [.media, .volume])
        onChange?()
    }

    // MARK: Presence (camera)

    private func updateSensing(_ now: Date) {
        guard settings.cameraActive else {
            if sensor.isRunning { sensor.stop() }
            lastReading = nil
            leavePresenceMode()
            return
        }
        let reasons = cameraReasons()
        let needed = !reasons.isEmpty
        // Only a call or video that just ended keeps the camera on a little longer (so it doesn't
        // flicker between videos). If the last reasons were your own switches (Keep watching,
        // Camera Preview), turning them off turns the camera off right away.
        let userOnly = !lastCameraReasons.isEmpty
            && lastCameraReasons.allSatisfy { $0 == .keepWatching || $0 == .preview }
        lastCameraReasons = reasons
        cameraReasonsText = reasons.map(\.text).joined(separator: ", ")

        // Watchdog: a session that runs but delivers no frames can't see you leave. Restart it
        // (at most every 10 s) instead of silently watching nothing.
        if sensor.isStalled && now.timeIntervalSince(lastCameraRestart) > 10 {
            lastCameraRestart = now
            sensor.restart()
        }

        if needed {
            sensingIdleSince = nil
            if !sensor.isRunning {
                tracker.reset()
                presence = .present
                sensor.start()
            }
        } else if sensor.isRunning && userOnly {
            sensor.stop()
            lastReading = nil
            sensingIdleSince = nil
        } else if sensor.isRunning {
            let idleSince = sensingIdleSince ?? now
            sensingIdleSince = idleSince
            if now.timeIntervalSince(idleSince) > Self.sensingLinger {
                sensor.stop()
                lastReading = nil
                sensingIdleSince = nil
            }
        }
    }

    /// Why the camera is needed right now (shown in the menu, so it's never a mystery).
    enum CameraReason: Equatable {
        case preview, keepWatching, call(String), media(String), stepAway

        var text: String {
            switch self {
            case .preview: return "Camera Preview is open"
            case .keepWatching: return "Keep watching is on"
            case .call(let app): return "you're in a call (\(app))"
            case .media(let app): return "\(app) is playing"
            case .stepAway: return "waiting for you to come back"
            }
        }
    }

    private var lastCameraReasons: [CameraReason] = []
    /// e.g. "Brave Browser is playing" — empty when the camera isn't needed.
    private(set) var cameraReasonsText = ""

    private func cameraReasons() -> [CameraReason] {
        var reasons: [CameraReason] = []
        if previewHandler != nil { reasons.append(.preview) }
        if settings.bool(Settings.Key.alwaysWatch) { reasons.append(.keepWatching) }
        if callPhase == .inCall {
            reasons.append(.call(callApps.map(Self.displayName).sorted().first ?? "an app"))
        }
        if let playing = outputSince.keys.first(where: {
            AppClassifier.isMediaSource($0) || AppClassifier.scriptablePlayers.contains($0)
        }) {
            reasons.append(.media(playing == AppClassifier.unknownOutput ? "Something" : Self.displayName(playing)))
        }
        if ledger.isEngaged(.away) || ledger.isEngaged(.phone) { reasons.append(.stepAway) }
        return reasons
    }

    private func handle(_ reading: PresenceReading) {
        guard sensor.isRunning else { return }
        lastReading = reading
        tracker.awayAfter = settings.awayDelay
        let effective: PresenceReading = (reading == .phoneToEar && !settings.phoneDetection) ? .present : reading
        guard let newState = tracker.update(effective, at: Date()) else { return }
        presence = newState

        // Engage the new reason before releasing the old one so nothing flickers back on in between.
        switch newState {
        case .present:
            release(.away)
            release(.phone)
        case .away:
            engage(.away, settings.awayResources)
            release(.phone)
        case .onPhone:
            engage(.phone, settings.awayResources)
            release(.away)
        }
        onChange?()
    }

    private func leavePresenceMode() {
        presence = .present
        release(.away)
        release(.phone)
    }

    // MARK: User commands

    func toggleMic() {
        if ledger.isHeld(.mic) || MicMuter.isMuted {
            // You asked to talk: that beats every automatic reason.
            ledger.clear(.mic)
            ledger.clear(.meetingAudio)
            undo(.mic)
            undo(.meetingAudio)
            MicMuter.unmute()
        } else {
            engage(.manual, [.mic, .meetingAudio])
        }
        onChange?()
    }

    func togglePanic() {
        if panicActive {
            release(.panic)
        } else {
            engage(.panic, Resource.allCases)
            Notifier.post("Panic mode on", "Mic muted, camera off, media paused. Press ⌃⌥⌘P to undo.")
        }
        onChange?()
    }

    /// ⌃⌥⌘G: switch all automatic behaviour off/on. The mute and panic shortcuts keep working.
    func toggleEnabled() {
        settings.toggle(Settings.Key.enabled)
        Notifier.post(settings.enabled ? "Over&Out is on" : "Over&Out is off",
                      settings.enabled ? "Watching for calls and for you stepping away." : "Nothing will be muted or paused automatically.")
        poll()
    }

    /// ⌃⌥⌘C: Over&Out's camera off/on. Turning it on also ends a timed pause.
    func toggleCamera() {
        setCamera(on: !settings.cameraActive)
    }

    func setCamera(on: Bool) {
        settings.setCamera(on: on)
        cameraWasPaused = false
        Notifier.post(on ? "Over&Out camera on" : "Over&Out camera off",
                      on ? "It watches during calls and videos to see if you step away."
                         : "Over&Out won't use the camera until you turn it back on (⌃⌥⌘C).")
        poll()
    }

    func pauseCamera(minutes: Int) {
        settings.pauseCamera(for: TimeInterval(minutes * 60))
        cameraWasPaused = true
        let until = settings.cameraPausedUntil?.formatted(date: .omitted, time: .shortened) ?? "later"
        Notifier.post("Over&Out camera paused until \(until)", "It turns back on by itself. Press ⌃⌥⌘C to turn it on sooner.")
        poll()
    }

    /// Tells you when a timed pause runs out and the camera may be used again.
    private func noticeCameraPauseEnding() {
        let pausedNow = settings.presenceEnabled && settings.cameraPausedUntil != nil
        if cameraWasPaused && !pausedNow && settings.cameraActive {
            Notifier.post("Over&Out camera is back on", "The pause you set has ended.")
        }
        cameraWasPaused = pausedNow
    }

    /// Everything automatic stops and is given back; manual mute and panic stay as they are.
    private func suspend() {
        if sensor.isRunning { sensor.stop() }
        lastReading = nil
        tracker.reset()
        presence = .present
        callPhase = .idle
        lastMicSeen = nil
        for reason in [Reason.ring, .call, .away, .phone] { release(reason) }
    }

    /// Give everything back before quitting.
    func shutdown() {
        sensor.stop()
        for resource in applied { undo(resource) }
        MicMuter.unmuteBeforeQuit() // give the mic back before quitting (waits at most 2 s)
        VolumeDucker.restore()
    }

    // MARK: Holding and releasing resources

    private func engage(_ reason: Reason, _ resources: [Resource]) {
        let newlyHeld = ledger.engage(reason, resources)
        for resource in newlyHeld {
            apply(resource, for: reason)
        }
        // Media already "paused" by an earlier reason may have been started again by you
        // (e.g. you pressed play during the call): pause whatever is playing *now* as well.
        if resources.contains(.media) && !newlyHeld.contains(.media) {
            repauseIfPlaying(for: reason)
        }
    }

    /// Only acts on a confirmed-playing video (tab bar, or tab-level pausing): a blind ⏯ here could
    /// resume something that's still paused.
    private func repauseIfPlaying(for reason: Reason) {
        let playing = outputSince.contains { id, _ in
            guard AppClassifier.isMediaSource(id), let app = Self.runningApp(for: id) else { return false }
            return BrowserTabs.audibility(of: app) == .videoPlaying
        }
        let browsers = BrowserMedia.enabled ? mediaPlan(steadyOnly: false).browsers : []
        guard playing || !browsers.isEmpty else { return }
        if media.pause(keyTargetPlaying: playing && browsers.isEmpty, browsers: browsers, browserKeyFallback: false) {
            applied.insert(.media)
        }
        if playing {
            // You started it again yourself, overriding the earlier pause: this reason owns it now,
            // so it resumes when this reason ends (e.g. when you're back), not when the call ends.
            for other in ledger.reasons(for: .media) where other != reason {
                ledger.drop(other, from: .media)
            }
        }
    }

    private func release(_ reason: Reason) {
        for resource in ledger.release(reason) {
            undo(resource)
        }
    }

    private func apply(_ resource: Resource, for reason: Reason) {
        let changed: Bool
        switch resource {
        case .mic:
            MicMuter.mute { unmutable in
                guard !unmutable.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.unmutableMics = unmutable
                    Notifier.post("Couldn't mute \(unmutable.joined(separator: ", "))",
                                  "This microphone has no mute or volume control. Mute it in your meeting app.")
                }
            }
            changed = true
        case .meetingAudio:
            warnIfAccessibilityMissing()
            MeetingControl.shared.turnOff(.audio, in: meetingApps())
            changed = true // runs in the background; restore() only undoes what it really switched off
        case .meetingVideo:
            warnIfAccessibilityMissing()
            MeetingControl.shared.turnOff(.video, in: meetingApps())
            changed = true
        case .media:
            // A call start only pauses what was already playing; walking away pauses whatever is on now.
            let steadyOnly = reason == .call || reason == .ring
            let plan = mediaPlan(steadyOnly: steadyOnly)
            changed = media.pause(keyTargetPlaying: plan.keyTarget, browsers: plan.browsers,
                                  browserKeyFallback: plan.keyFallback)
        case .volume:
            VolumeDucker.duckInBackground(to: settings.duckLevel)
            changed = true
        }
        if changed {
            applied.insert(resource)
        } else {
            ledger.drop(reason, from: resource) // did nothing, so it holds nothing
        }
    }

    private func undo(_ resource: Resource) {
        guard applied.remove(resource) != nil else { return }
        switch resource {
        case .mic:
            MicMuter.unmute()
            unmutableMics = []
        case .meetingAudio:
            MeetingControl.shared.restore(.audio)
        case .meetingVideo:
            MeetingControl.shared.restore(.video)
        case .media:
            if settings.autoResumeMedia { media.resume() } else { media.forget() }
        case .volume:
            VolumeDucker.restoreInBackground()
        }
    }

    // MARK: What's playing


    /// How to pause what's playing (Spotify/Music are always checked separately):
    /// - keyTarget: press ⏯. Used for players and for browsers that aren't hosting the call,
    ///   exactly like the first version, with no browser setting needed.
    /// - browsers: browsers hosting the call *and* playing a video, paused tab by tab with the
    ///   meeting tab skipped. That's what pauses Netflix while Meet runs in the same browser.
    /// - keyFallback: ⏯ is safe if such a browser can't be asked (it was playing before the call).
    private func mediaPlan(steadyOnly: Bool) -> (keyTarget: Bool, browsers: [String], keyFallback: Bool) {
        let now = Date()
        let sources = outputSince.filter { id, since in
            AppClassifier.isMediaSource(id) && (!steadyOnly || now.timeIntervalSince(since) >= Self.steadyPlayback)
        }.map(\.key)

        var browsers = Set<String>()
        var keyTarget = false
        var keyFallback = false
        for id in sources {
            let app = Self.runningApp(for: id)
            let hostsCall = callApps.contains(id)
            let supportedID = app?.bundleIdentifier.flatMap { BrowserMedia.supported[$0] != nil ? $0 : nil }

            // Tab control on: pause every playing tab of every supported browser directly (all
            // windows, desktops and screens; meeting tabs skipped). The ⏯ key only reaches one app,
            // so it's kept for players nothing else can control.
            if BrowserMedia.enabled, let supportedID, BrowserMedia.isSupportedBrowserProcess(id) {
                browsers.insert(supportedID)
                if !hostsCall || playedBeforeCall(id) { keyFallback = true } // if the browser refuses
                continue
            }

            // Chromium browsers: their tab bar says which tab is playing ("… - Audio playing"),
            // so we know whether a video is on, even next to a meeting, without any setting.
            switch app.map(BrowserTabs.audibility(of:)) ?? .unknown {
            case .videoPlaying:
                if hostsCall && BrowserMedia.enabled, let supportedID {
                    browsers.insert(supportedID) // tab-level pausing is more precise when it's on
                } else {
                    keyTarget = true // ⏯ goes to the video; Meet doesn't take the media keys
                }
                continue
            case .nothingPlaying:
                continue // only the meeting (or nothing) is making sound: pressing ⏯ could start a paused video
            case .unknown:
                break
            }

            if BrowserMedia.isSupportedBrowserProcess(id), let bundleID = supportedID {
                if !hostsCall {
                    // Not hosting the call: the ⏯ key pauses it, no browser setting needed.
                    keyTarget = true
                } else if BrowserMedia.enabled {
                    // Hosting the call too (Meet + Netflix in one browser): pause inside the tabs,
                    // skipping the meeting tab. If the browser can't be asked, ⏯ is still safe when
                    // it was playing before the call began.
                    browsers.insert(bundleID)
                    if playedBeforeCall(id) { keyFallback = true }
                } else if playedBeforeCall(id) {
                    // No tab-level option: ⏯ is safe because the sound predates the call (a video).
                    keyTarget = true
                }
            } else if !hostsCall {
                keyTarget = true
            }
        }

        // Before macOS 14.2 sound can't be traced to an app. Outside a call (or for sound that
        // predates it) press ⏯ like the first version; mid-call, only tab-level pausing is safe.
        if !perProcessAudio && !sources.isEmpty {
            let keySafe = callPhase != .inCall || steadyOnly
            keyTarget = keySafe
            keyFallback = false
            if !keySafe && BrowserMedia.enabled { browsers.formUnion(BrowserMedia.runningBrowsers) }
        }
        return (keyTarget, browsers.sorted(), keyFallback)
    }

    private func playedBeforeCall(_ id: String) -> Bool {
        guard let started = callStartedAt, let since = outputSince[id] else { return false }
        return since <= started.addingTimeInterval(-Self.steadyPlayback)
    }

    private var reportedBrowsers: Set<String> = []

    /// One notification per browser per launch explaining the one-time setting it needs.
    private func reportBrowserProblem(blocked: [String], notAuthorized: [String]) {
        for browser in blocked where reportedBrowsers.insert(browser).inserted {
            Notifier.post("Over&Out couldn't pause videos in \(BrowserMedia.name(browser))", BrowserMedia.howToAllow(browser))
        }
        for browser in notAuthorized where reportedBrowsers.insert(browser).inserted {
            Notifier.post("Allow Over&Out to control \(BrowserMedia.name(browser))",
                          "System Settings → Privacy & Security → Automation → Over&Out → turn on \(BrowserMedia.name(browser)).")
        }
    }

    // MARK: Display helpers

    func describe(_ resource: Resource) -> String? {
        if resource == .meetingVideo && !MeetingControl.shared.isSwitchedOff(.video) { return nil }
        let reasons = ledger.reasons(for: resource)
        guard !reasons.isEmpty, applied.contains(resource) || resource == .mic && MicMuter.isMuted else { return nil }
        return Reason.allCases.filter { reasons.contains($0) }.map(\.rawValue).joined(separator: ", ")
    }

    static func displayName(_ bundleID: String) -> String {
        if let name = runningApp(for: bundleID)?.localizedName { return name }
        return bundleID == AppClassifier.unknownMicUser ? "an app" : bundleID
    }

    /// The app behind an audio process: "com.brave.Browser.helper" → Brave, WebKit → Safari.
    /// Helper processes are running applications too, but windowless and background-only
    /// (activation policy .prohibited), so keep going until we reach a regular app with windows.
    static func runningApp(for bundleID: String) -> NSRunningApplication? {
        if bundleID.hasPrefix("pid:"), let pid = pid_t(bundleID.dropFirst(4)) {
            return NSRunningApplication(processIdentifier: pid)
        }
        if bundleID.hasPrefix("com.apple.WebKit") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
        }
        var candidate = bundleID
        for _ in 0..<3 {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: candidate)
            if let app = apps.first(where: { $0.activationPolicy == .regular }) {
                return app
            }
            guard let dot = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<dot])
        }
        return nil
    }

    /// Apps whose buttons to press: the ones using the mic, or (when that's unknown, or it's not
    /// a call) every running meeting app and browser. Pressing only happens where a
    /// "Turn off camera"-style button exists, so apps without a meeting are left alone.
    /// Once per launch: without Accessibility only the system-wide mic mute can work.
    private func warnIfAccessibilityMissing() {
        guard !Permissions.accessibilityGranted, !warnedAboutAccessibility else { return }
        warnedAboutAccessibility = true
        Notifier.post("Over&Out can't reach your meeting's camera and mute buttons",
                      "Allow Accessibility for Over&Out in System Settings. After a rebuild, remove Over&Out there and add it again.")
    }

    func meetingApps() -> [pid_t] {
        var apps = callApps.compactMap(Self.runningApp(for:))
        if apps.isEmpty || !perProcessAudio {
            apps += NSWorkspace.shared.runningApplications.filter {
                AppClassifier.isMeetingHost($0.bundleIdentifier ?? "")
            }
        }
        var seen = Set<pid_t>()
        return apps.map(\.processIdentifier).filter { seen.insert($0).inserted }
    }
}
