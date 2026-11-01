import AppKit
import Carbon.HIToolbox

/// Finds what else already uses a key combination: macOS's own shortcuts (System Settings >
/// Keyboard > Keyboard Shortcuts), the standard app commands every Mac user relies on, and
/// Toolchest's other hotkeys.
enum ShortcutConflicts {
    struct SystemShortcut: Equatable, Sendable {
        let id: Int
        let combo: KeyCombo
    }

    /// Names for the symbolic hotkey IDs macOS stores in com.apple.symbolichotkeys.
    static let systemNames: [Int: String] = [
        7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to the active or next window",
        10: "Move focus to the window toolbar", 11: "Move focus to the floating window", 12: "Change the way Tab moves focus",
        13: "Turn keyboard access on or off", 15: "Zoom in", 17: "Zoom out", 19: "Turn zoom on or off",
        21: "Invert colors", 23: "Turn image smoothing on or off", 25: "Increase contrast", 26: "Decrease contrast",
        27: "Move focus to the next window", 28: "Save picture of screen as a file", 29: "Copy picture of screen",
        30: "Save picture of selected area as a file", 31: "Copy picture of selected area",
        32: "Mission Control", 33: "Application windows", 34: "Mission Control (slow)", 35: "Application windows (slow)",
        36: "Show Desktop", 37: "Show Desktop (slow)", 52: "Turn Dock hiding on or off", 57: "Move focus to the status menus",
        59: "Turn VoiceOver on or off", 60: "Select the previous input source", 61: "Select the next input source",
        62: "Show Dashboard", 64: "Show Spotlight search", 65: "Show Finder search window",
        70: "Show Dictionary", 73: "Look up in Dictionary", 75: "Show Help menu", 79: "Move left a space",
        80: "Move left a space (slow)", 81: "Move right a space", 82: "Move right a space (slow)",
        98: "Show Help menu", 118: "Switch to Desktop 1", 119: "Switch to Desktop 2", 120: "Switch to Desktop 3",
        121: "Switch to Desktop 4", 160: "Show Launchpad", 162: "Accessibility controls", 163: "Notification Center",
        164: "Do Not Disturb", 175: "Focus mode", 179: "Quick Note", 184: "Screenshot and recording options",
        190: "Live Text", 215: "Show Apps", 222: "Turn Stage Manager on or off", 224: "Game Mode",
    ]

    /// Shortcuts every app or macOS itself reserves, so a global hotkey on them would break something basic.
    static let reserved: [(KeyCombo, String)] = {
        let cmd: NSEvent.ModifierFlags = .command
        var list: [(KeyCombo, String)] = []
        let standard: [(Int, String)] = [
            (kVK_ANSI_Q, "Quit"), (kVK_ANSI_W, "Close window"), (kVK_ANSI_H, "Hide app"), (kVK_ANSI_M, "Minimize"),
            (kVK_ANSI_C, "Copy"), (kVK_ANSI_V, "Paste"), (kVK_ANSI_X, "Cut"), (kVK_ANSI_Z, "Undo"), (kVK_ANSI_A, "Select All"),
            (kVK_ANSI_S, "Save"), (kVK_ANSI_O, "Open"), (kVK_ANSI_N, "New"), (kVK_ANSI_P, "Print"), (kVK_ANSI_F, "Find"),
            (kVK_ANSI_T, "New tab"), (kVK_ANSI_Comma, "Settings"), (kVK_Tab, "App Switcher"), (kVK_Space, "Spotlight"),
            (kVK_ANSI_R, "Reload"), (kVK_ANSI_L, "Location"), (kVK_ANSI_B, "Bold"), (kVK_ANSI_I, "Italic"), (kVK_ANSI_U, "Underline"),
            (kVK_ANSI_G, "Find next"), (kVK_ANSI_E, "Use selection for Find"), (kVK_ANSI_K, "Insert link"),
            (kVK_ANSI_Y, "Show history"), (kVK_ANSI_D, "Duplicate or bookmark"), (kVK_ANSI_J, "Downloads"),
            (kVK_ANSI_Grave, "Cycle windows"),
        ]
        for (key, name) in standard { list.append((KeyCombo(keyCode: UInt16(key), modifiers: cmd), name)) }
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift]), "Redo"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .shift]), "Log Out"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .control]), "Lock Screen"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .control]), "Enter Full Screen"))
        list.append((KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [.command, .option]), "Force Quit"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command, .option]), "Hide others"))
        list.append((KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command, .control]), "Emoji & Symbols"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .option]), "Show or hide the Dock"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift]), "Reopen closed tab"))
        list.append((KeyCombo(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .shift]), "New folder"))
        return list
    }()

    /// Parses the AppleSymbolicHotKeys dictionary from com.apple.symbolichotkeys.
    /// Entries look like `{ enabled = 1; value = { parameters = (ascii, keyCode, modifierMask); type = standard; }; }`.
    static func parseSymbolicHotkeys(_ dictionary: [String: Any]) -> [SystemShortcut] {
        var result: [SystemShortcut] = []
        for (key, entry) in dictionary {
            guard let id = Int(key), let entry = entry as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
            guard enabled, let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any], parameters.count >= 3,
                  let code = number(parameters[1]), let mask = number(parameters[2]),
                  code >= 0, code < 0xFFFF else { continue }
            let combo = KeyCombo(keyCode: UInt16(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mask)))
            result.append(SystemShortcut(id: id, combo: combo))
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func number(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// macOS's factory shortcuts. com.apple.symbolichotkeys only stores the ones the user changed
    /// (or that macOS has touched), so these fill in the rest.
    static let factoryShortcuts: [SystemShortcut] = {
        let cmd: NSEvent.ModifierFlags = .command, ctrl: NSEvent.ModifierFlags = .control
        let list: [(Int, Int, NSEvent.ModifierFlags)] = [
            (7, kVK_F2, ctrl), (8, kVK_F3, ctrl), (9, kVK_F4, ctrl), (10, kVK_F5, ctrl), (11, kVK_F6, ctrl),
            (28, kVK_ANSI_3, [.command, .shift]), (29, kVK_ANSI_3, [.command, .shift, .control]),
            (30, kVK_ANSI_4, [.command, .shift]), (31, kVK_ANSI_4, [.command, .shift, .control]),
            (184, kVK_ANSI_5, [.command, .shift]),
            (32, kVK_UpArrow, ctrl), (33, kVK_DownArrow, ctrl), (79, kVK_LeftArrow, ctrl), (81, kVK_RightArrow, ctrl),
            (36, kVK_F11, []), (59, kVK_F5, cmd),
            (60, kVK_Space, ctrl), (61, kVK_Space, [.control, .option]),
            (64, kVK_Space, cmd), (65, kVK_Space, [.command, .option]),
            (98, kVK_ANSI_Slash, [.command, .shift]),
        ]
        return list.map { SystemShortcut(id: $0.0, combo: KeyCombo(keyCode: UInt16($0.1), modifiers: $0.2)) }
    }()

    /// Factory shortcuts with the user's stored changes applied: a stored entry replaces the
    /// factory one, and a stored disabled entry removes it.
    static func effective(stored dictionary: [String: Any]) -> [SystemShortcut] {
        let storedIDs = Set(dictionary.keys.compactMap(Int.init))
        let factory = factoryShortcuts.filter { !storedIDs.contains($0.id) }
        return (factory + parseSymbolicHotkeys(dictionary)).sorted { $0.id < $1.id }
    }

    /// The system's enabled shortcuts, read fresh each time (the user can change them at any moment).
    static func currentSystemShortcuts() -> [SystemShortcut] {
        let dictionary = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return effective(stored: dictionary)
    }

    /// Human-readable descriptions of everything `combo` collides with.
    static func conflicts(for combo: KeyCombo, system: [SystemShortcut], toolchest: [(KeyCombo, String)]) -> [String] {
        var found: [String] = []
        for shortcut in system where shortcut.combo == combo {
            found.append("macOS: " + (systemNames[shortcut.id] ?? "system shortcut \(shortcut.id)"))
        }
        for (other, name) in reserved where other == combo {
            found.append("Standard app command: \(name)")
        }
        for (other, name) in toolchest where other == combo {
            found.append("Toolchest: \(name)")
        }
        return found
    }
}
