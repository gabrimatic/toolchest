import Foundation

/// Every user choice, stored as one JSON document in UserDefaults.
///
/// Loading merges the stored JSON over the encoded defaults, so a setting added in a later version
/// simply takes its default instead of discarding everything else.
struct Settings: Codable, Equatable, Sendable {
    var general = GeneralSettings()
    var finder = FinderSettings()
    var windows = WindowSettings()
    var keyboard = KeyboardSettings()
    var screen = ScreenSettings()
    var audio = AudioSettings()
    var utilities = UtilitySettings()
    var links = LinkSettings()
    var hotkeys: [String: KeyCombo] = HotkeyAction.defaultCombos

    func isEnabled(_ module: Module) -> Bool {
        switch module {
        case .finder: finder.enabled
        case .windows: windows.enabled
        case .keyboard: keyboard.enabled
        case .screen: screen.enabled
        case .audio: audio.enabled
        case .utilities: utilities.enabled
        case .links: links.enabled
        }
    }

    mutating func setEnabled(_ module: Module, _ on: Bool) {
        switch module {
        case .finder: finder.enabled = on
        case .windows: windows.enabled = on
        case .keyboard: keyboard.enabled = on
        case .screen: screen.enabled = on
        case .audio: audio.enabled = on
        case .utilities: utilities.enabled = on
        case .links: links.enabled = on
        }
    }

    // MARK: Effective state (module switch AND feature switch)

    var finderTapActive: Bool { finder.enabled && (finder.cutPaste || finder.returnOpens || finder.reopenClosed || finder.newTextFile || finder.pasteAsFile) }
    var quitGuardActive: Bool { windows.enabled && windows.quitGuard }
    var dockClickActive: Bool { windows.enabled && windows.dockClick }
    var dockMiddleActive: Bool { windows.enabled && windows.dockMiddleQuit }
    var greenFillActive: Bool { windows.enabled && windows.greenFill }
    var hyperActive: Bool { keyboard.enabled && keyboard.hyper }
    var clipboardClearActive: Bool { utilities.enabled && utilities.clipboardClear }
    var autoMuteActive: Bool { audio.enabled && audio.micMute && audio.autoMuteTyping }

    /// Whether anything needs the shared event tap (cleaning mode starts its own use of it on demand).
    var needsEventTap: Bool {
        finderTapActive || quitGuardActive || dockClickActive || dockMiddleActive || greenFillActive
            || hyperActive || clipboardClearActive || autoMuteActive
    }

    // MARK: Persistence

    static let storageKey = "settings.v1"

    static func decode(_ data: Data?) -> Settings {
        guard let data,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Settings()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else { return Settings() }
        let merged = merge(defaults, over: stored)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(Settings.self, from: mergedData) else { return Settings() }
        return settings
    }

    /// Stored values win; nested objects merge key by key; values of the wrong JSON kind are ignored.
    static func merge(_ base: [String: Any], over stored: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in stored {
            guard let baseValue = base[key] else {
                // Keys only the stored side knows (e.g. hotkey names) are kept when the base is an open map.
                result[key] = value
                continue
            }
            if let baseObject = baseValue as? [String: Any] {
                if key == "hotkeys", let storedObject = value as? [String: Any] {
                    // The hotkey map is the user's whole choice: a cleared hotkey must stay cleared.
                    result[key] = storedObject
                } else if let storedObject = value as? [String: Any] {
                    result[key] = merge(baseObject, over: storedObject)
                }
            } else if sameKind(baseValue, value) {
                result[key] = value
            }
        }
        return result
    }

    private static func sameKind(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNumber, is NSNumber), (is String, is String), (is [Any], is [Any]): true
        default: false
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

enum Module: String, CaseIterable, Identifiable, Sendable {
    case finder, windows, keyboard, screen, audio, utilities, links
    var id: String { rawValue }

    var title: String {
        switch self {
        case .finder: "Finder"
        case .windows: "Windows & Dock"
        case .keyboard: "Keyboard"
        case .screen: "Screen"
        case .audio: "Audio"
        case .utilities: "Utilities"
        case .links: "Mail & Notes"
        }
    }

    var symbol: String {
        switch self {
        case .finder: "folder"
        case .windows: "macwindow.on.rectangle"
        case .keyboard: "keyboard"
        case .screen: "text.viewfinder"
        case .audio: "speaker.wave.2"
        case .utilities: "wrench.and.screwdriver"
        case .links: "link"
        }
    }

    var summary: String {
        switch self {
        case .finder: "Cut and paste files, Return to open, reopen closed windows, new files and right-click extras."
        case .windows: "Quit guard, isolate a window, smarter Dock clicks and a green button that fills the screen."
        case .keyboard: "Caps Lock as a Hyper key, app hotkeys, drop-down windows and a shortcut inspector."
        case .screen: "Copy text from anywhere, translate it, scan codes and pick colors."
        case .audio: "Keep Music shut, mute the mic, switch devices and cap the volume after wake."
        case .utilities: "Keep awake, cleaning mode, quick toggles, clipboard clearing and notifications."
        case .links: "Copy a link to the selected Mail message or note."
        }
    }
}

struct FinderSettings: Codable, Equatable, Sendable {
    var enabled = false
    var cutPaste = true
    var returnOpens = true
    var reopenClosed = true
    var newTextFile = true
    var pasteAsFile = true
    var rightClickExtras = true
}

enum DockClickAction: String, Codable, CaseIterable, Sendable {
    case hide, minimize, cycle
    var title: String {
        switch self {
        case .hide: "Hide the app"
        case .minimize: "Minimize its windows"
        case .cycle: "Cycle its windows"
        }
    }
}

struct WindowSettings: Codable, Equatable, Sendable {
    var enabled = false
    var quitGuard = true
    var holdDuration = 0.6
    /// Apps where ⌘W also needs the hold or a double press.
    var closeGuardBundleIDs: [String] = []
    var isolate = true
    var dockClick = true
    var dockClickAction = DockClickAction.hide
    var dockMiddleQuit = true
    var greenFill = true
}

struct AppHotkey: Codable, Equatable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var combo: KeyCombo?
    var id: String { bundleID }
}

struct KeyboardSettings: Codable, Equatable, Sendable {
    var enabled = false
    var hyper = true
    var hyperEscOnTap = true
    var appHotkeys: [AppHotkey] = []
    var dropdownFinder = true
    var dropdownTerminal = true
    /// Share of the screen height a drop-down window takes.
    var dropdownHeight = 0.45
}

enum ColorFormat: String, Codable, CaseIterable, Sendable {
    case hex, rgb, oklch
    var title: String {
        switch self {
        case .hex: "Hex"
        case .rgb: "RGB"
        case .oklch: "OKLCH"
        }
    }
}

struct ScreenSettings: Codable, Equatable, Sendable {
    var enabled = true
    var captureText = false
    var translate = false
    /// BCP 47 code of the target language; empty means the system language.
    var translateTarget = ""
    var scanCode = false
    var colorPicker = true
    var colorFormat = ColorFormat.hex
    /// Plain rules (TextReflow) tidy captured text (join broken lines, fix hyphenation) before copying. No model.
    var cleanUpText = false
    /// Capture and Summarize, with Apple Intelligence on this Mac.
    var summarize = false
}

struct GeneralSettings: Codable, Equatable, Sendable {
    /// Light Force Touch taps when a guarded key commits, a shortcut is recorded and similar moments.
    var haptics = true
}

struct AudioSettings: Codable, Equatable, Sendable {
    var enabled = false
    var musicGuard = true
    var micMute = true
    var autoMuteTyping = false
    var deviceSwitch = true
    var volumeCap = true
    var volumeCapLevel = 0.5
}

struct UtilitySettings: Codable, Equatable, Sendable {
    var enabled = true
    var keepAwake = true
    var cleaning = false
    var toggles = false
    var clipboardClear = false
    var clipboardAge = 60.0
    var notifications = false
}

struct LinkSettings: Codable, Equatable, Sendable {
    var enabled = false
    var mailLink = true
    var noteLink = true
}
