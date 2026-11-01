import Foundation
import IOKit.hid
import IOKit.hidsystem
import os

/// Caps Lock → F18 at the HID level, so the event tap can turn F18 into the Hyper chord.
///
/// The mapping is a per-keyboard `UserKeyMapping` property, set through the public IOHID event
/// system client (the same thing `hidutil property --set` does). Toolchest only adds and removes its own
/// entry and keeps any other mappings the user has. The property does not survive a reboot, and
/// Toolchest removes its entry on disable, on quit, on SIGTERM, and on the next launch after a crash.
enum HyperMapping {
    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Existing mappings plus Caps Lock → F18 (replacing any other Caps Lock mapping).
    static func adding(to existing: [[String: UInt64]]) -> [[String: UInt64]] {
        existing.filter { $0[srcKey] != capsLock } + [[srcKey: capsLock, dstKey: f18]]
    }

    /// Existing mappings minus Toolchest's own Caps Lock → F18 entry.
    static func removing(from existing: [[String: UInt64]]) -> [[String: UInt64]] {
        existing.filter { !($0[srcKey] == capsLock && $0[dstKey] == f18) }
    }

    static func contains(_ existing: [[String: UInt64]]) -> Bool {
        existing.contains { $0[srcKey] == capsLock && $0[dstKey] == f18 }
    }

    private static let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "hyper")

    /// Runs `body` with the current keyboard services. The services belong to the client, so the
    /// client must outlive every use of them (a fresh client also sees newly attached keyboards).
    private static func withKeyboards<T>(_ body: ([IOHIDServiceClient]) -> T) -> T {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return withExtendedLifetime(client) {
            let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
            return body(services.filter {
                IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
            })
        }
    }

    private static func mapping(of service: IOHIDServiceClient) -> [[String: UInt64]] {
        guard let raw = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let src = (entry[srcKey] as? NSNumber)?.uint64Value, let dst = (entry[dstKey] as? NSNumber)?.uint64Value else { return nil }
            return [srcKey: src, dstKey: dst]
        }
    }

    private static func setMapping(_ mapping: [[String: UInt64]], on service: IOHIDServiceClient) -> Bool {
        let value = mapping.map { entry in entry.mapValues { NSNumber(value: $0) } } as NSArray
        return IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, value)
    }

    /// Applies Caps Lock → F18 to every keyboard. Returns false if no keyboard accepted it.
    @discardableResult
    static func apply() -> Bool {
        let applied = withKeyboards { keyboards in
            keyboards.reduce(0) { count, keyboard in
                let current = mapping(of: keyboard)
                if contains(current) { return count + 1 }
                return setMapping(adding(to: current), on: keyboard) ? count + 1 : count
            }
        }
        if applied == 0 { log.error("no keyboard accepted the Caps Lock mapping") }
        return applied > 0
    }

    /// Removes Toolchest's entry from every keyboard; leaves other mappings alone.
    static func revert() {
        withKeyboards { keyboards in
            for keyboard in keyboards {
                let current = mapping(of: keyboard)
                guard contains(current) else { continue }
                _ = setMapping(removing(from: current), on: keyboard)
            }
        }
    }

    static var isApplied: Bool { withKeyboards { $0.contains { contains(mapping(of: $0)) } } }
}

/// Re-applies the mapping when a keyboard is plugged in or reconnects over Bluetooth.
@MainActor
final class KeyboardWatcher {
    private var manager: IOHIDManager?
    var onKeyboardAdded: (() -> Void)?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<KeyboardWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                // The new service appears a moment after the device.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { watcher.onKeyboardAdded?() }
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Opening is not needed for matching callbacks, and would need Input Monitoring.
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
    }
}
