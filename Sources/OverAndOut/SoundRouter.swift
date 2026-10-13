import AppKit
import CoreAudio

/// One rule from Settings → Sound: play this app's sound on that device.
struct SoundRoute: Codable, Identifiable, Equatable {
    var bundleID: String
    var appName: String
    var deviceUID: String
    var deviceName: String
    var id: String { bundleID }
}

enum SoundRoutes {
    private static let key = "soundRoutes"
    static let enabledKey = "soundRoutingEnabled"

    static var all: [SoundRoute] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let routes = try? JSONDecoder().decode([SoundRoute].self, from: data) else { return [] }
        return routes
    }

    static func save(_ routes: [SoundRoute]) {
        if let data = try? JSONEncoder().encode(routes) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Master switch (on by default once you've added a rule).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Sends each app's sound to the device its rule names, using Core Audio process taps (macOS 14.2+):
/// the app's sound is tapped (and silenced on the normal output) and played on the chosen device
/// through a private aggregate device. Nothing is recorded or saved; the sound only passes through.
///
/// Safe by design:
/// - The device isn't connected, the app isn't running, or the device already is the Mac's output:
///   nothing is done, so the app plays where it normally would.
/// - If macOS shows the app playing but the tap delivers only silence (no permission, or the tap
///   stalls), the route is removed at once, so you never end up hearing nothing.
/// All Core Audio work runs on one background queue.
final class SoundRouter: @unchecked Sendable {
    static let shared = SoundRouter()

    enum Status: Equatable {
        case routing(String)        // device name
        case waitingForApp
        case deviceMissing(String)  // device name
        case alreadyThere
        case needsPermission
        case failed(String)
        case off
        case unsupported

        var text: String {
            switch self {
            case .routing(let device): return "Playing on \(device)"
            case .waitingForApp: return "Waiting for the app to open"
            case .deviceMissing(let device): return "\(device) isn't connected: plays normally"
            case .alreadyThere: return "That device is the Mac's output already"
            case .needsPermission: return "Allow System Audio Recording for Over&Out (Privacy & Security), then turn routing off and on"
            case .failed(let why): return "Couldn't route: \(why)"
            case .off: return "Routing is switched off"
            case .unsupported: return "Needs macOS 14.2 or later"
            }
        }
    }

    private let queue = DispatchQueue(label: "overandout.sound-router", qos: .userInitiated)
    private let lock = NSLock()
    private var statuses: [String: Status] = [:]
    private var reconciling = false
    /// After a silent tap (permission missing), don't try again for a while.
    private var blockedUntil: [String: Date] = [:]
    private var routes: [String: AnyObject] = [:] // bundleID → ActiveRoute (typed below, 14.2+)

    func status(for bundleID: String) -> Status? {
        lock.lock(); defer { lock.unlock() }
        return statuses[bundleID]
    }

    /// Brings the routes in line with the rules, the running apps and the connected devices.
    /// Called every couple of seconds; cheap when nothing changed.
    func reconcileInBackground() {
        lock.lock()
        guard !reconciling else { lock.unlock(); return }
        reconciling = true
        lock.unlock()
        queue.async { [self] in
            reconcile()
            lock.lock(); reconciling = false; lock.unlock()
        }
    }

    /// Removes every route (on quit, or when switched off).
    func stopAll() {
        queue.sync { [self] in
            for bundleID in Array(routes.keys) { remove(bundleID) }
        }
    }

    /// Lets a blocked rule try again (after allowing the permission).
    func retry() {
        queue.async { [self] in blockedUntil = [:] }
    }

    private func setStatus(_ bundleID: String, _ status: Status) {
        lock.lock(); statuses[bundleID] = status; lock.unlock()
    }

    private func reconcile() {
        let rules = SoundRoutes.all
        // Rules that were deleted: remove their routes.
        for bundleID in routes.keys where !rules.contains(where: { $0.bundleID == bundleID }) { remove(bundleID) }
        guard #available(macOS 14.2, *) else {
            for rule in rules { setStatus(rule.bundleID, .unsupported) }
            return
        }
        guard SoundRoutes.isEnabled else {
            for bundleID in Array(routes.keys) { remove(bundleID) }
            for rule in rules { setStatus(rule.bundleID, .off) }
            return
        }
        let processes = AudioDevices.processes()
        let devices = AudioDevices.outputDevices
        let defaultUID = AudioDevices.defaultOutputUID
        let nowPlaying = NowPlaying.latest

        for rule in rules {
            let mine = processes.filter { $0.bundleID == rule.bundleID || $0.bundleID.hasPrefix(rule.bundleID + ".") }
            let active = routes[rule.bundleID] as? ActiveRoute
            guard !mine.isEmpty else {
                if active != nil { remove(rule.bundleID) }
                setStatus(rule.bundleID, .waitingForApp)
                continue
            }
            guard let device = devices.first(where: { $0.uid == rule.deviceUID }) else {
                if active != nil { remove(rule.bundleID) }
                setStatus(rule.bundleID, .deviceMissing(rule.deviceName))
                continue
            }
            if device.uid == defaultUID {
                if active != nil { remove(rule.bundleID) }
                setStatus(rule.bundleID, .alreadyThere)
                continue
            }
            if let until = blockedUntil[rule.bundleID], until > Date() {
                setStatus(rule.bundleID, .needsPermission)
                continue
            }

            let objectIDs = Set(mine.map(\.objectID))
            if let active {
                // Still right? Same processes (apps start helper processes for sound), same device.
                if active.objectIDs == objectIDs && active.deviceUID == device.uid {
                    // Safety: macOS says the app is playing (it's the Now Playing app, playing), but
                    // the tap has delivered nothing but silence for a while: remove the route.
                    let appPlaying = nowPlaying.map { now in
                        now.playing && (now.bundleID.map { $0 == rule.bundleID || $0.hasPrefix(rule.bundleID + ".") } ?? false)
                    } ?? false
                    if appPlaying && active.silentFor > 4 && active.age > 4 {
                        remove(rule.bundleID)
                        blockedUntil[rule.bundleID] = Date().addingTimeInterval(60)
                        setStatus(rule.bundleID, .needsPermission)
                        Notifier.post("Sound routing paused for \(rule.appName)",
                                      "\(rule.appName) was silent through the route, so it plays normally again. Allow System Audio Recording for Over&Out in Privacy & Security.")
                    } else {
                        setStatus(rule.bundleID, .routing(device.name))
                    }
                    continue
                }
                remove(rule.bundleID)
            }
            do {
                routes[rule.bundleID] = try ActiveRoute(processes: Array(objectIDs), device: device, label: rule.appName)
                setStatus(rule.bundleID, .routing(device.name))
            } catch {
                setStatus(rule.bundleID, .failed(error.localizedDescription))
            }
        }
    }

    private func remove(_ bundleID: String) {
        if #available(macOS 14.2, *), let route = routes[bundleID] as? ActiveRoute { route.stop() }
        routes[bundleID] = nil
    }
}

/// One live route: a process tap (the app's sound, silenced on the normal output) inside a private
/// aggregate device whose output is the chosen device, and an IO block copying one to the other.
@available(macOS 14.2, *)
private final class ActiveRoute {
    struct RouteError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (\(status))" }
    }

    let objectIDs: Set<AudioObjectID>
    let deviceUID: String
    private let started = Date()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "overandout.sound-route", qos: .userInteractive)
    private let meter = SilenceMeter()

    var age: TimeInterval { Date().timeIntervalSince(started) }
    var silentFor: TimeInterval { meter.silentFor }

    init(processes: [AudioObjectID], device: AudioDevices.OutputDevice, label: String) throws {
        objectIDs = Set(processes)
        deviceUID = device.uid

        // 1. Tap the app's processes; silence them on the normal output while tapped.
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map { NSNumber(value: $0) })
        description.name = "Over&Out: \(label)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw RouteError(step: "Tapping \(label)", status: status) }

        // 2. A private aggregate device: the tap in, the chosen device out.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Over&Out route (\(label))",
            kAudioAggregateDeviceUIDKey: "com.gokulmv.overandout.route.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            "tapautostart": true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            "taps": [["uid": description.uuid.uuidString, "drift": true]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw RouteError(step: "Creating the route", status: status)
        }

        // 3. Copy what the tap delivers to the device's output.
        let meter = self.meter
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, output, _ in
            ActiveRoute.copy(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                             to: UnsafeMutableAudioBufferListPointer(output), meter: meter)
        }
        guard status == noErr, let ioProcID else {
            stop()
            throw RouteError(step: "Starting the route", status: status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw RouteError(step: "Starting the route", status: status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Float32 samples, any mix of interleaved / separate channels on either side: output channel k
    /// gets input channel k (wrapping, so stereo fills a mono or a multichannel device sensibly).
    private static func copy(_ input: UnsafeMutableAudioBufferListPointer,
                             to output: UnsafeMutableAudioBufferListPointer, meter: SilenceMeter) {
        var sources: [(UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
        for buffer in input {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels { sources.append((samples + channel, channels, frames)) }
        }
        var heard = false
        var outputChannel = 0
        for buffer in output {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                defer { outputChannel += 1 }
                guard !sources.isEmpty else {
                    for frame in 0..<frames { samples[frame * channels + channel] = 0 }
                    continue
                }
                let source = sources[outputChannel % sources.count]
                let count = min(frames, source.frames)
                for frame in 0..<count {
                    let value = source.0[frame * source.stride]
                    samples[frame * channels + channel] = value
                    if !heard && abs(value) > 0.000_01 { heard = true }
                }
                for frame in count..<frames { samples[frame * channels + channel] = 0 }
            }
        }
        if heard { meter.heard() }
    }
}

/// When the route last carried actual sound (written on the audio thread, read on the router's).
private final class SilenceMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastHeard = Date()

    func heard() {
        // Called up to ~100 times a second: only update every half second.
        if lock.try() {
            if Date().timeIntervalSince(lastHeard) > 0.5 { lastHeard = Date() }
            lock.unlock()
        }
    }

    var silentFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastHeard)
    }
}
