import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Sendable, Equatable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasOutput: Bool
    let hasInput: Bool
    let transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return hasInput && !hasOutput ? "mic" : "hifispeaker"
        default: return hasOutput ? "speaker.wave.2" : "mic"
        }
    }
}

/// Small, typed wrappers over the Core Audio HAL. Every call checks its status; nothing here
/// assumes a property exists on a device.
enum CoreAudioHAL {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
        var address = address(selector, scope, element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func hasStreams(_ device: AudioDeviceID, input: Bool) -> Bool {
        var address = address(kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func devices() -> [AudioDevice] {
        deviceIDs().compactMap { id in
            guard uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  uint32(id, kAudioDevicePropertyIsHidden) != 1 else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Device \(id)"
            let uid = string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            // Aggregate and virtual devices other apps create are fine to include; private ones are hidden above.
            return AudioDevice(id: id, name: name, uid: uid, hasOutput: hasStreams(id, input: false),
                               hasInput: hasStreams(id, input: true), transport: transport)
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), selector), id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultDevice(_ device: AudioDeviceID, input: Bool) -> Bool {
        var address = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    private static func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    // MARK: Mute

    static func isMuted(_ device: AudioDeviceID, input: Bool) -> Bool? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            if let value = uint32(device, kAudioDevicePropertyMute, scope: scope, element: element) { return value != 0 }
        }
        return nil
    }

    /// Sets mute on the main element, or on each channel when the device only mutes per channel.
    /// Returns false when the device has no settable mute.
    @discardableResult
    static func setMuted(_ device: AudioDeviceID, input: Bool, _ muted: Bool) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var anySet = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = address(kAudioDevicePropertyMute, scope, element)
            guard isSettable(device, &address) else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                anySet = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return anySet
    }

    // MARK: Volume

    /// The 0...1 volume macOS shows in the menu bar.
    static func volume(_ device: AudioDeviceID, input: Bool) -> Float? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                              input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ device: AudioDeviceID, input: Bool, _ volume: Float) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                              input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        guard isSettable(device, &address) else { return false }
        var value = Float32(min(max(volume, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    /// Whether any process is using the device (for the default input: a call or recording is live).
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        (uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
    }

    // MARK: Listeners

    /// Calls `block` on the main queue when the property changes. Returns a token for removal.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ block: @escaping @Sendable () -> Void) -> AudioListener? {
        var address = address(selector, scope)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, listener) == noErr else { return nil }
        return AudioListener(object: object, address: address, block: listener)
    }

    /// The next device after `current` in a stable, name-sorted order, wrapping around.
    static func next(after current: AudioDeviceID?, in devices: [AudioDevice]) -> AudioDevice? {
        let sorted = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !sorted.isEmpty else { return nil }
        guard let current, let index = sorted.firstIndex(where: { $0.id == current }) else { return sorted.first }
        return sorted[(index + 1) % sorted.count]
    }
}

final class AudioListener: @unchecked Sendable {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.block = block
    }

    func remove() {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
