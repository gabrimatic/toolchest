import AppKit
import Carbon.HIToolbox

/// Every global hotkey Toolchest can register. App hotkeys are separate (one per app).
enum HotkeyAction: String, CaseIterable, Sendable {
    case isolate, captureText, translate, summarize, scanCode, pickColor
    case micMute, cycleOutput, cycleInput
    case keepAwake, cleaning, darkMode, clearNotifications, openNotification
    case mailLink, noteLink, dropdownFinder, dropdownTerminal

    var title: String {
        switch self {
        case .isolate: "Isolate window"
        case .captureText: "Capture text"
        case .translate: "Capture and translate"
        case .summarize: "Capture and summarize"
        case .scanCode: "Scan QR or barcode"
        case .pickColor: "Color Picker"
        case .micMute: "Mute microphone"
        case .cycleOutput: "Next output device"
        case .cycleInput: "Next input device"
        case .keepAwake: "Keep awake on or off"
        case .cleaning: "Cleaning mode"
        case .darkMode: "Dark Mode on or off"
        case .clearNotifications: "Clear notifications"
        case .openNotification: "Open top notification"
        case .mailLink: "Copy Mail message link"
        case .noteLink: "Copy note link"
        case .dropdownFinder: "Drop-down Finder"
        case .dropdownTerminal: "Drop-down terminal"
        }
    }

    /// Suggested combinations. A hotkey is only registered while its module and feature are on.
    static let defaultCombos: [String: KeyCombo] = {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        func combo(_ key: Int) -> KeyCombo { KeyCombo(keyCode: UInt16(key), modifiers: mods) }
        return [
            HotkeyAction.isolate.rawValue: combo(kVK_ANSI_I),
            HotkeyAction.captureText.rawValue: combo(kVK_ANSI_T),
            HotkeyAction.translate.rawValue: combo(kVK_ANSI_Y),
            HotkeyAction.scanCode.rawValue: combo(kVK_ANSI_B),
            HotkeyAction.micMute.rawValue: combo(kVK_ANSI_M),
            HotkeyAction.cycleOutput.rawValue: combo(kVK_ANSI_O),
            HotkeyAction.cycleInput.rawValue: combo(kVK_ANSI_U),
        ]
    }()
}

/// Global hotkeys through Carbon's RegisterEventHotKey. It needs no permission and costs nothing
/// while idle: the system only wakes Toolchest when a registered combination is pressed.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    /// Combinations macOS refused (another app registered them first).
    private(set) var failed: [String] = []

    private init() {}

    /// Replaces every registration with `bindings` (name, combo, action).
    func apply(_ bindings: [(name: String, combo: KeyCombo, action: @MainActor () -> Void)]) {
        unregisterAll()
        installHandlerIfNeeded()
        failed = []
        for binding in bindings where binding.combo.isValidHotkey {
            let id = nextID
            nextID &+= 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4B4E434B), id: id)
            let status = RegisterEventHotKey(UInt32(binding.combo.keyCode), binding.combo.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                handlers[id] = binding.action
            } else {
                failed.append(binding.name)
            }
        }
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}
