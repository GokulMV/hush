import Foundation

/// macOS's own "Now Playing": the one thing the system considers playing right now, whatever the
/// app (Spotify, Music, a YouTube or Netflix tab in any browser, VLC…). One signal for every player,
/// instead of guessing from which app has the speakers open.
///
/// - Reading it: since macOS 15.4 only Apple-signed processes may, so it's read by a tiny script run
///   with Apple's /usr/bin/osascript (JavaScript for Automation), off the main thread.
/// - Controlling it: a real Pause and Play (not the ⏯ toggle, which could *start* something).
enum NowPlaying {
    struct State: Equatable {
        var playing: Bool
        var bundleID: String?
        var title: String?

        /// Worth pausing: playing, and not the meeting itself.
        var pausable: Bool {
            guard playing else { return false }
            if let bundleID, AppClassifier.isCallApp(bundleID) { return false }
            let lowered = (title ?? "").lowercased()
            return !Self.meetingWords.contains { lowered.contains($0) }
        }

        private static let meetingWords = ["google meet", "meet -", "zoom meeting", "microsoft teams",
                                           "webex", "huddle", "whereby", "jitsi"]
    }

    /// Latest reading (refreshed every couple of seconds by `refreshInBackground`); nil when it
    /// couldn't be read, in which case callers fall back to the older per-app signals.
    static var latest: State? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    private static let lock = NSLock()
    private static var cached: State?
    private static var refreshing = false
    private static var lastRefresh = Date.distantPast

    /// Reads Now Playing in the background, at most every `interval` seconds.
    static func refreshInBackground(interval: TimeInterval = 2) {
        lock.lock()
        guard !refreshing, Date().timeIntervalSince(lastRefresh) >= interval else { lock.unlock(); return }
        refreshing = true
        lastRefresh = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let state = read()
            lock.lock()
            cached = state
            refreshing = false
            lock.unlock()
        }
    }

    /// Pauses whatever is playing (does nothing if nothing is).
    static func pause() { send(.pause) }

    /// Plays again what was paused.
    static func play() { send(.play) }

    // MARK: Reading

    private static let readScript = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
        const request = $.NSClassFromString('MRNowPlayingRequest');
        const out = { playing: false, bundle: null, title: null };
        const item = request.localNowPlayingItem;
        if (item.js) {
            const info = item.nowPlayingInfo;
            const rate = info.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate');
            out.playing = (rate.js || 0) > 0;
            const title = info.valueForKey('kMRMediaRemoteNowPlayingInfoTitle');
            if (title.js) out.title = title.js;
        }
        try {
            const client = request.localNowPlayingPlayerPath.client;
            out.bundle = client.parentApplicationBundleIdentifier.js || client.bundleIdentifier.js || null;
        } catch (e) {}
        JSON.stringify(out);
        """

    /// nil: couldn't be read (osascript failed, or took longer than 2 s).
    static func read() -> State? {
        guard let output = runJavaScript(readScript, timeout: 2),
              let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return State(playing: json["playing"] as? Bool ?? false,
                     bundleID: json["bundle"] as? String,
                     title: json["title"] as? String)
    }

    // MARK: Controlling

    private enum Command: Int32 {
        case play = 0, pause = 1 // MRMediaRemoteCommand values
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    /// Sending commands still works from inside the app; the same command also goes through
    /// osascript in case this macOS refuses it. Pause and Play are idempotent, so twice is harmless.
    private static func send(_ command: Command) {
        if let sendCommand {
            _ = sendCommand(command.rawValue, nil)
        }
        let script = """
            ObjC.import('Foundation');
            $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
            ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
            $.MRMediaRemoteSendCommand(\(command.rawValue), $());
            'ok';
            """
        DispatchQueue.global(qos: .userInitiated).async { _ = runJavaScript(script, timeout: 2) }
    }

    private static let sendCommand: SendCommand? = {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else { return nil }
        return unsafeBitCast(pointer, to: SendCommand.self)
    }()

    /// Runs JavaScript for Automation with Apple's osascript; the result, or nil on error/timeout.
    private static func runJavaScript(_ source: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
