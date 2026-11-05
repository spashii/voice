import CoreAudio
import Foundation

/// A microphone or other input, as Core Audio names it. The UID survives restarts and
/// unplugging, so it is what Settings stores; the AudioDeviceID does not.
public struct InputDevice: Sendable, Hashable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }
}

/// Lists and finds input devices. Every call asks coreaudiod, and when coreaudiod stops
/// answering these calls block for as long as it does, so callers run them off the main
/// thread: an app that lists devices on its main thread freezes with it.
public enum InputDevices {
    public static func list() -> [InputDevice] {
        allDevices().compactMap { device in
            guard hasInput(device), let uid = string(device, kAudioDevicePropertyDeviceUID),
                  // The private aggregates macOS makes for voice processing aren't real inputs.
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return InputDevice(uid: uid, name: string(device, kAudioObjectPropertyName) ?? uid)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The device with this UID, if it is connected and has an input.
    public static func id(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
