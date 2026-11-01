import AppKit
import Carbon.HIToolbox

/// The pure decisions behind the keyboard interceptions, kept apart from the event tap.
enum KeyRules {
    struct Mods: OptionSet, Sendable, Hashable {
        let rawValue: UInt8
        static let command = Mods(rawValue: 1)
        static let option = Mods(rawValue: 2)
        static let control = Mods(rawValue: 4)
        static let shift = Mods(rawValue: 8)

        init(rawValue: UInt8) { self.rawValue = rawValue }

        init(_ flags: CGEventFlags) {
            var mods: Mods = []
            if flags.contains(.maskCommand) { mods.insert(.command) }
            if flags.contains(.maskAlternate) { mods.insert(.option) }
            if flags.contains(.maskControl) { mods.insert(.control) }
            if flags.contains(.maskShift) { mods.insert(.shift) }
            self = mods
        }
    }

    enum PasteboardKind: Sendable, Equatable { case files, imageOrText, other }

    enum FinderRule: Sendable, Equatable {
        case none
        /// ⌘X becomes ⌘C and the copy is remembered as a cut.
        case cutAsCopy
        /// ⌘V becomes ⌘⌥V (Move Item Here) because the clipboard still holds the cut files.
        case pasteMove
        /// ⌘V with an image or text and no files: Toolchest writes a file instead.
        case pasteAsFile
        /// Return becomes ⌘↓ (Open).
        case returnOpens
        /// F2 becomes Return (Rename).
        case f2Renames
        case reopenClosed
        case newTextFile
        /// ⌘W: remember the window's folder, then let Finder close it.
        case noteClose
    }

    struct FinderOptions: Sendable, Equatable {
        var cutPaste = false
        var returnOpens = false
        var reopen = false
        var newFile = false
        var pasteAsFile = false
    }

    /// Decides what a key-down in the frontmost Finder means. `focusInFileList` and `pasteboard`
    /// are only evaluated when the decision depends on them (both cost an IPC round trip).
    static func finderRule(keyCode: Int, mods: Mods, options: FinderOptions, cutArmed: Bool,
                           focusInFileList: () -> Bool, pasteboard: () -> PasteboardKind) -> FinderRule {
        switch (keyCode, mods) {
        case (kVK_ANSI_X, .command) where options.cutPaste:
            return focusInFileList() ? .cutAsCopy : .none
        case (kVK_ANSI_V, .command) where options.cutPaste || options.pasteAsFile:
            guard focusInFileList() else { return .none }
            let kind = pasteboard()
            if kind == .files { return options.cutPaste && cutArmed ? .pasteMove : .none }
            if kind == .imageOrText && options.pasteAsFile { return .pasteAsFile }
            return .none
        case (kVK_Return, []) where options.returnOpens:
            return focusInFileList() ? .returnOpens : .none
        case (kVK_F2, []) where options.returnOpens:
            return focusInFileList() ? .f2Renames : .none
        case (kVK_ANSI_T, [.command, .shift]) where options.reopen:
            return .reopenClosed
        case (kVK_ANSI_W, .command) where options.reopen:
            return .noteClose
        case (kVK_ANSI_N, .option) where options.newFile:
            return focusInFileList() ? .newTextFile : .none
        default:
            return .none
        }
    }

    /// Roles of the focused Finder element that mean "the file list has focus", not a text field,
    /// button or sheet. Anything else (or an AX failure) leaves the key alone.
    static let fileListRoles: Set<String> = [
        "AXOutline", "AXList", "AXTable", "AXBrowser", "AXScrollArea", "AXGroup", "AXRow", "AXCell", "AXImage",
    ]

    enum QuitKey: Sendable, Equatable { case none, quit, close }

    /// ⌘Q (or ⌘W in the chosen apps) aimed at an app the guard covers.
    static func quitKey(keyCode: Int, mods: Mods, frontBundleID: String?, ownBundleID: String,
                        closeGuardApps: Set<String>) -> QuitKey {
        guard mods == .command, let bundleID = frontBundleID,
              bundleID != "com.apple.finder", bundleID != ownBundleID else { return .none }
        if keyCode == kVK_ANSI_Q { return .quit }
        if keyCode == kVK_ANSI_W && closeGuardApps.contains(bundleID) { return .close }
        return .none
    }
}
