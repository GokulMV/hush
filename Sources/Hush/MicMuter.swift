import CoreAudio
import Foundation

/// System-wide "hard" mute: works in every app (Zoom, Teams, Meet, FaceTime…) because it
/// silences the microphone itself. Original levels are saved to UserDefaults so they
/// come back even if Hush crashes while muted.
enum MicMuter {
    private static let savedKey = "Hush.savedMicState"
    private static let pendingKey = "Hush.pendingMicRestore"

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

    /// Mutes every microphone. Safe to call repeatedly: it also catches mics plugged in
    /// later and apps (e.g. Zoom's auto-level) that push the volume back up.
    /// Returns names of mics that have neither a mute switch nor a volume control.
    @discardableResult
    static func mute() -> [String] {
        var state = saved ?? [:]
        var unmutable: [String] = []
        for device in AudioDevices.inputDevices {
            guard let uid = AudioDevices.uid(device) else { continue }
            if let entry = state[uid] {
                enforce(device, entry)
                continue
            }
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
        return unmutable
    }

    static func unmute() {
        guard let state = saved else { return }
        var leftovers = state
        for device in AudioDevices.inputDevices {
            guard let uid = AudioDevices.uid(device), let entry = state[uid] else { continue }
            restore(device, entry)
            leftovers[uid] = nil
        }
        saved = nil
        pending.merge(leftovers) { _, newer in newer }
    }

    /// Call periodically: restores mics that were disconnected during a mute.
    static func restoreReconnected() {
        var remaining = pending
        guard !remaining.isEmpty else { return }
        for device in AudioDevices.inputDevices {
            guard let uid = AudioDevices.uid(device), let entry = remaining[uid] else { continue }
            restore(device, entry)
            remaining[uid] = nil
        }
        pending = remaining
    }

    private static func enforce(_ device: AudioDeviceID, _ entry: [String: Double]) {
        if entry["mute"] != nil {
            if AudioDevices.inputMute(device) != true { AudioDevices.setInputMute(device, true) }
            return
        }
        for key in entry.keys {
            guard let element = UInt32(key), (AudioDevices.inputVolume(device, element: element) ?? 0) > 0 else { continue }
            AudioDevices.setInputVolume(device, element: element, 0)
        }
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
