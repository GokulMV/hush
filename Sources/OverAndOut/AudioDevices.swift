import AudioToolbox
import CoreAudio
import Foundation

/// What is using the microphone and the speakers right now.
struct AudioActivity {
    var micUsers: Set<String>
    var outputUsers: Set<String>
    /// False on macOS < 14.2, where only "some app" can be known, not which one.
    var perProcess: Bool
}

/// Small non-throwing wrappers around the Core Audio C API.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func activity() -> AudioActivity {
        if #available(macOS 14.2, *) {
            return processActivity()
        }
        let micBusy = inputDevices.contains(where: isRunningSomewhere)
        let outputBusy = defaultOutput.map(isRunningSomewhere) ?? false
        return AudioActivity(
            micUsers: micBusy ? [AppClassifier.unknownMicUser] : [],
            outputUsers: outputBusy ? [AppClassifier.unknownOutput] : [],
            perProcess: false
        )
    }

    @available(macOS 14.2, *)
    private static func processActivity() -> AudioActivity {
        var mic = Set<String>()
        var output = Set<String>()
        for process in objectList(system, kAudioHardwarePropertyProcessObjectList) {
            let usesMic = (uint32(process, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            let usesOutput = (uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            guard usesMic || usesOutput else { continue }
            let pid = Int32(bitPattern: uint32(process, kAudioProcessPropertyPID) ?? 0)
            let bundleID = string(process, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 } ?? "pid:\(pid)"
            if usesMic { mic.insert(bundleID) }
            if usesOutput { output.insert(bundleID) }
        }
        return AudioActivity(micUsers: mic, outputUsers: output, perProcess: true)
    }

    // MARK: Devices

    static var inputDevices: [AudioDeviceID] {
        objectList(system, kAudioHardwarePropertyDevices).filter { hasStreams($0, scope: kAudioObjectPropertyScopeInput) }
    }

    /// Real microphones: skips virtual and aggregate devices (ZoomAudioDevice, Teams Audio,
    /// BlackHole, Loopback, aggregate devices), which Over&Out must not mute or poll.
    static var physicalInputDevices: [AudioDeviceID] {
        let skipped: Set<UInt32> = [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                    kAudioDeviceTransportTypeAutoAggregate]
        return inputDevices.filter { !skipped.contains(uint32($0, kAudioDevicePropertyTransportType) ?? 0) }
    }

    static var defaultOutput: AudioDeviceID? {
        uint32(system, kAudioHardwarePropertyDefaultOutputDevice).flatMap { $0 == 0 ? nil : $0 }
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ device: AudioDeviceID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Unknown microphone"
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        (uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
    }

    // MARK: Input mute / volume

    static func canMuteInput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
        return isSettable(device, &addr)
    }

    static func inputMute(_ device: AudioDeviceID) -> Bool? {
        uint32(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput).map { $0 != 0 }
    }

    @discardableResult
    static func setInputMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
        guard isSettable(device, &addr) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Elements (0 = main, 1… = channels) whose input volume can be changed.
    static func settableInputVolumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        (0...8).map { AudioObjectPropertyElement($0) }.filter { element in
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            return isSettable(device, &addr)
        }
    }

    static func inputVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setInputVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement, _ volume: Float32) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
        var value = volume
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: Output volume (the same slider as the menu bar volume control)

    static func outputVolume(_ device: AudioDeviceID) -> Float32? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setOutputVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value = max(0, min(1, volume))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: Plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func isSettable(_ object: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
