import CoreAudio
import Foundation

/// System-wide "hard" mute: works in every app (Zoom, Teams, Meet, FaceTime…) because it
/// silences the microphone itself. Original levels are saved to UserDefaults so they
/// come back even if Over&Out crashes while muted.
enum MicMuter {
    private static let savedKey = "OverAndOut.savedMicState"
    private static let pendingKey = "OverAndOut.pendingMicRestore"

    /// [device UID: ["mute": 0/1] or ["<element>": volume, …]]
    private typealias State = [String: [String: Double]]

    private static var saved: State? {
        get { UserDefaults.standard.dictionary(forKey: savedKey) as? State }
        set { UserDefaults.standard.set(newValue, forKey: savedKey) }
    }

    /// Devices that were unplugged while muted; restored when they come back.
    private static var pending: State {
        get { UserDefaults.standard.dictionary(forKey: pendingKey) as? State ?? [:] }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: pendingKey) }
    }

    static var isMuted: Bool { saved != nil }

    /// All Core Audio work happens here, in order, off the main thread's hot path: some audio
    /// drivers answer slowly, and blocking the main thread froze the menu (and hammering them
    /// loaded coreaudiod enough to make the whole Mac stutter).
    private static let queue = DispatchQueue(label: "overandout.mic-mute")
    private static var lastEnforced = Date.distantPast   // main thread only
    private static var lastRestoreCheck = Date.distantPast // main thread only
    private static var refusals: [String: Int] = [:]     // queue only: consecutive re-mutes per mic
    private static let maxRefusals = 10

    /// Mutes every physical microphone (virtual/aggregate devices such as ZoomAudioDevice, Teams
    /// Audio or BlackHole are left alone: muting the real mic already silences you everywhere).
    /// Returns names of mics that have neither a mute switch nor a volume control.
    @discardableResult
    static func mute() -> [String] {
        queue.sync { muteLocked() }
    }

    static func unmute() {
        queue.sync { unmuteLocked() }
    }

    /// Call often (e.g. every poll); runs at most every 2 s, in the background. Mutes mics plugged
    /// in during the mute, and re-mutes ones an app turned back up (Zoom's auto-level), giving up on
    /// a mic that keeps refusing instead of fighting it forever.
    static func enforceInBackground() {
        guard isMuted, Date().timeIntervalSince(lastEnforced) >= 2 else { return }
        lastEnforced = Date()
        queue.async {
            guard let state = saved else { return }
            var newDevice = false
            for device in AudioDevices.physicalInputDevices {
                guard let uid = AudioDevices.uid(device) else { continue }
                guard let entry = state[uid] else {
                    newDevice = true
                    continue
                }
                guard refusals[uid, default: 0] < maxRefusals else { continue }
                refusals[uid] = enforce(device, entry) ? refusals[uid, default: 0] + 1 : 0
            }
            if newDevice { _ = muteLocked() }
        }
    }

    /// Call often; restores mics that were disconnected during a mute, at most every 2 s.
    static func restoreReconnected() {
        guard Date().timeIntervalSince(lastRestoreCheck) >= 2 else { return }
        lastRestoreCheck = Date()
        queue.async {
            var remaining = pending
            guard !remaining.isEmpty else { return }
            for device in AudioDevices.inputDevices {
                guard let uid = AudioDevices.uid(device), let entry = remaining[uid] else { continue }
                restore(device, entry)
                remaining[uid] = nil
            }
            pending = remaining
        }
    }

    // MARK: On `queue`

    private static func muteLocked() -> [String] {
        var state = saved ?? [:]
        var unmutable: [String] = []
        for device in AudioDevices.physicalInputDevices {
            guard let uid = AudioDevices.uid(device), state[uid] == nil else { continue }
            if AudioDevices.canMuteInput(device) {
                state[uid] = ["mute": AudioDevices.inputMute(device) == true ? 1 : 0]
                AudioDevices.setInputMute(device, true)
                continue
            }
            var volumes: [String: Double] = [:]
            for element in AudioDevices.settableInputVolumeElements(device) {
                guard let volume = AudioDevices.inputVolume(device, element: element) else { continue }
                volumes[String(element)] = Double(volume)
                AudioDevices.setInputVolume(device, element: element, 0)
            }
            if volumes.isEmpty {
                unmutable.append(AudioDevices.name(device))
            } else {
                state[uid] = volumes
            }
        }
        saved = state
        refusals = [:]
        return unmutable
    }

    private static func unmuteLocked() {
        guard let state = saved else { return }
        var leftovers = state
        // Every input device, virtual ones included: older versions muted those too.
        for device in AudioDevices.inputDevices {
            guard let uid = AudioDevices.uid(device), let entry = state[uid] else { continue }
            restore(device, entry)
            leftovers[uid] = nil
        }
        saved = nil
        refusals = [:]
        pending.merge(leftovers) { _, newer in newer }
    }

    /// Re-applies the mute. Returns true if the mic had come back on (so it had to be re-muted).
    private static func enforce(_ device: AudioDeviceID, _ entry: [String: Double]) -> Bool {
        if entry["mute"] != nil {
            guard AudioDevices.inputMute(device) != true else { return false }
            AudioDevices.setInputMute(device, true)
            return true
        }
        var reapplied = false
        for key in entry.keys {
            guard let element = UInt32(key), (AudioDevices.inputVolume(device, element: element) ?? 0) > 0 else { continue }
            AudioDevices.setInputVolume(device, element: element, 0)
            reapplied = true
        }
        return reapplied
    }

    private static func restore(_ device: AudioDeviceID, _ entry: [String: Double]) {
        if let wasMuted = entry["mute"] {
            AudioDevices.setInputMute(device, wasMuted != 0)
            return
        }
        for (key, volume) in entry {
            guard let element = UInt32(key) else { continue }
            AudioDevices.setInputVolume(device, element: element, Float32(volume))
        }
    }
}
