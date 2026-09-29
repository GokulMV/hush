import Foundation

/// Lowers the speaker volume while a phone rings, then puts it back.
enum VolumeDucker {
    private static let originalKey = "Hush.volumeBeforeDuck"
    private static let duckedKey = "Hush.volumeDuckedTo"
    private static var defaults: UserDefaults { .standard }

    static var isDucked: Bool { defaults.object(forKey: originalKey) != nil }

    /// Returns true if the volume was actually lowered.
    static func duck(to level: Float32) -> Bool {
        guard !isDucked,
              let device = AudioDevices.defaultOutput,
              let current = AudioDevices.outputVolume(device),
              current > level,
              AudioDevices.setOutputVolume(device, level) else { return false }
        defaults.set(Double(current), forKey: originalKey)
        defaults.set(Double(level), forKey: duckedKey)
        return true
    }

    static func restore() {
        guard isDucked else { return }
        let original = Float32(defaults.double(forKey: originalKey))
        let duckedTo = Float32(defaults.double(forKey: duckedKey))
        defaults.removeObject(forKey: originalKey)
        defaults.removeObject(forKey: duckedKey)

        guard let device = AudioDevices.defaultOutput, let current = AudioDevices.outputVolume(device) else { return }
        // If you changed the volume yourself meanwhile, your choice wins.
        if abs(current - duckedTo) < 0.03 {
            AudioDevices.setOutputVolume(device, original)
        }
    }
}
