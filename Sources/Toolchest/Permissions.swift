import AppKit
import ApplicationServices
import CoreGraphics

/// The macOS permissions Toolchest's modules need. Toolchest reads their state, asks macOS and opens the
/// right System Settings pane; granting is always the user's step.
enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, inputMonitoring, screenRecording, automationFinder, automationSystemEvents, automationMail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        case .automationFinder: "Automation: Finder"
        case .automationSystemEvents: "Automation: System Events"
        case .automationMail: "Automation: Mail"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: "Key remaps, the quit guard, Dock clicks, the green button, Hyper key, cleaning mode and notifications."
        case .inputMonitoring: "Listening for key presses for the Hyper key and auto-mute while typing."
        case .screenRecording: "Capture Text, Translate and code scanning read the region you select."
        case .automationFinder: "Finding the current Finder folder for new files, pastes and reopening windows."
        case .automationSystemEvents: "Switching Dark Mode."
        case .automationMail: "Reading the selected message’s ID for a message:// link."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard.badge.eye"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .automationFinder, .automationSystemEvents, .automationMail: "gearshape.2"
        }
    }

    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
        switch self {
        case .accessibility: return URL(string: base + "Privacy_Accessibility")
        case .inputMonitoring: return URL(string: base + "Privacy_ListenEvent")
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")
        case .automationFinder, .automationSystemEvents, .automationMail: return URL(string: base + "Privacy_Automation")
        }
    }

    var automationBundleID: String? {
        switch self {
        case .automationFinder: "com.apple.finder"
        case .automationSystemEvents: "com.apple.systemevents"
        case .automationMail: "com.apple.mail"
        default: nil
        }
    }
}

enum PermissionState: Sendable, Equatable {
    case granted, denied, notDetermined
    /// Automation can only be checked while the target app is running.
    case unknown
}

@MainActor
enum Permissions {
    static func state(_ permission: Permission) -> PermissionState {
        switch permission {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring: return CGPreflightListenEventAccess() ? .granted : .denied
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .automationFinder, .automationSystemEvents, .automationMail:
            guard let bundleID = permission.automationBundleID else { return .unknown }
            return automationState(bundleID, ask: false)
        }
    }

    /// Checks (and with `ask`, requests) Apple Events access to an app. Never blocks on a dialog
    /// unless `ask` is true, which only happens from an explicit user action.
    nonisolated static func automationState(_ bundleID: String, ask: Bool) -> PermissionState {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .unknown }
        var target = AEAddressDesc()
        let status: OSStatus = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }

    /// Adds Toolchest to the Accessibility list and shows the system prompt. The user flips the switch.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Whether Toolchest already asked macOS for this permission. After that macOS shows no second
    /// prompt, so the only way forward is the System Settings pane.
    static func hasAsked(_ permission: Permission, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: askedKey(permission))
    }

    static func forgetAsked(defaults: UserDefaults = .standard) {
        for permission in Permission.allCases { defaults.removeObject(forKey: askedKey(permission)) }
    }

    private static func askedKey(_ permission: Permission) -> String { "permission.asked.\(permission.rawValue)" }

    /// True when the next press should open System Settings instead of asking macOS.
    static func shouldOpenSettings(_ permission: Permission, defaults: UserDefaults = .standard) -> Bool {
        let state = state(permission)
        return state != .granted && hasAsked(permission, defaults: defaults)
    }

    /// Triggers the real macOS prompt through the proper request API, so macOS itself adds Toolchest to
    /// the list and asks. Opens no pane.
    static func ask(_ permission: Permission, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: askedKey(permission))
        switch permission {
        case .accessibility: requestAccessibility()
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .automationFinder, .automationSystemEvents, .automationMail:
            guard let bundleID = permission.automationBundleID else { return }
            // The consent dialog blocks the caller until answered, so ask off the main thread.
            // Toolchest never starts Finder or Mail for this (it asks while they run), but System Events
            // is a background helper macOS starts on demand, so it is started here to have something to ask.
            Task.detached {
                if permission == .automationSystemEvents, !AppleScript.isRunningNow(bundleID) {
                    await MainActor.run {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                }
                _ = Permissions.automationState(bundleID, ask: true)
            }
        }
    }

    /// The button a permission row offers: ask macOS the first time, open the pane after a refusal.
    static func request(_ permission: Permission, defaults: UserDefaults = .standard) {
        if shouldOpenSettings(permission, defaults: defaults) {
            open(permission)
        } else {
            ask(permission, defaults: defaults)
        }
    }

    static func open(_ permission: Permission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
