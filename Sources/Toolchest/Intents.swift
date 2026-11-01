import AppIntents
import AppKit
import Translation
import UniformTypeIdentifiers
import Vision

// App Intents for every module action: they show up in Shortcuts, Spotlight and Siri, and run in
// Toolchest's own process. Actions respect the module switches: an action whose module or feature is
// off fails with a message saying which switch to turn on.

enum ToolchestIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case off(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Toolchest isn’t ready yet. Try again in a moment."
        case .off(let feature): "Turn on \(feature) in Toolchest’s settings first."
        case .failed(let message): "\(message)"
        }
    }
}

@MainActor
private func toolchest() throws -> AppController {
    guard let controller = AppController.current else { throw ToolchestIntentError.notRunning }
    return controller
}

@MainActor
private func require(_ on: Bool, _ feature: String) throws {
    if !on { throw ToolchestIntentError.off(feature) }
}

// MARK: Enums and entities

enum ToolchestModuleEnum: String, AppEnum {
    case finder, windows, keyboard, screen, audio, utilities, links

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Toolchest Module"
    static let caseDisplayRepresentations: [ToolchestModuleEnum: DisplayRepresentation] = [
        .finder: "Finder", .windows: "Windows & Dock", .keyboard: "Keyboard", .screen: "Screen",
        .audio: "Audio", .utilities: "Utilities", .links: "Mail & Notes",
    ]

    var module: Module { Module(rawValue: rawValue) ?? .utilities }
}

enum SwitchState: String, AppEnum {
    case on, off, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "State"
    static let caseDisplayRepresentations: [SwitchState: DisplayRepresentation] = [.on: "On", .off: "Off", .toggle: "Toggle"]

    func resolve(current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

enum AudioDirection: String, AppEnum {
    case output, input

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device Kind"
    static let caseDisplayRepresentations: [AudioDirection: DisplayRepresentation] = [.output: "Output", .input: "Input"]
}

enum DropdownApp: String, AppEnum {
    case finder, terminal

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drop-down App"
    static let caseDisplayRepresentations: [DropdownApp: DisplayRepresentation] = [.finder: "Finder", .terminal: "Terminal"]
}

struct AudioDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audio Device"
    static let defaultQuery = AudioDeviceQuery()

    let id: String
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(_ device: AudioDevice) {
        id = device.uid
        name = device.name
        symbol = device.symbol
    }
}

struct AudioDeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AudioDeviceEntity] {
        CoreAudioHAL.devices().filter { identifiers.contains($0.uid) }.map(AudioDeviceEntity.init)
    }

    func suggestedEntities() async throws -> [AudioDeviceEntity] {
        CoreAudioHAL.devices().filter(\.hasOutput).map(AudioDeviceEntity.init)
    }
}

// MARK: Utilities

struct StartKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription("Stops the Mac and display from sleeping, for a while or until turned off.")

    @Parameter(title: "Minutes", description: "Leave empty to stay awake until turned off.", inclusiveRange: (1, 1440))
    var minutes: Int?

    static var parameterSummary: some ParameterSummary { Summary("Keep the Mac awake for \(\.$minutes) minutes") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.keepAwake, "Keep Awake")
        guard app.keepAwake.start(for: minutes.map { Double($0) * 60 }) else { throw ToolchestIntentError.failed("macOS refused to keep the Mac awake.") }
        return .result(dialog: "\(app.keepAwake.statusText)")
    }
}

struct StopKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Let Mac Sleep"
    static let description = IntentDescription("Turns Keep Awake off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try toolchest().keepAwake.stop()
        return .result()
    }
}

struct StartCleaningModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cleaning Mode"
    static let description = IntentDescription("Blacks out the screens and pauses input. Hold Esc for 2 seconds to leave; it ends after 60 seconds.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.cleaning, "Cleaning Mode")
        app.cleaning.start()
        return .result()
    }
}

struct SetDarkModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Dark Mode"

    @Parameter(title: "Dark Mode", default: .toggle) var state: SwitchState

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.toggles, "Quick toggles")
        if state.resolve(current: SystemToggles.isDarkMode) != SystemToggles.isDarkMode { SystemToggles.toggleDarkMode() }
        return .result()
    }
}

struct SetDesktopIconsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show or Hide Desktop Icons"

    @Parameter(title: "Desktop icons", default: .toggle) var state: SwitchState

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.toggles, "Quick toggles")
        if state.resolve(current: SystemToggles.desktopIconsShown) != SystemToggles.desktopIconsShown { SystemToggles.toggleDesktopIcons() }
        return .result()
    }
}

struct ClearNotificationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Notifications"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.notifications, "Notification shortcuts")
        NotificationsAX.clearAll()
        return .result()
    }
}

struct OpenTopNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Top Notification"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.utilities.enabled && app.settings.utilities.notifications, "Notification shortcuts")
        NotificationsAX.openTop()
        return .result()
    }
}

// MARK: Screen

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Select a region of the screen and copy its text.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.screen.enabled && app.settings.screen.captureText, "Capture Text")
        app.screen.captureText()
        return .result()
    }
}

struct CaptureAndTranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture and Translate"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.screen.enabled && app.settings.screen.translate, "Capture and Translate")
        app.screen.captureAndTranslate()
        return .result()
    }
}

struct CaptureAndSummarizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture and Summarize"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.screen.enabled && app.settings.screen.summarize, "Capture and Summarize")
        app.screen.captureAndSummarize()
        return .result()
    }
}

struct ScanCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan QR Code on Screen"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.screen.enabled && app.settings.screen.scanCode, "Code scanning")
        app.screen.scanRegion()
        return .result()
    }
}

struct PickColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick Color on Screen"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.screen.enabled && app.settings.screen.colorPicker, "Color picker")
        app.screen.pickColor()
        return .result()
    }
}

/// Headless: works on a file, no screen involved.
struct RecognizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Recognize Text in Image"
    static let description = IntentDescription("Reads the text in an image on this Mac.")

    @Parameter(title: "Image", supportedContentTypes: [.image]) var image: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Recognize text in \(\.$image)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolchestIntentError.failed("That file isn’t an image Toolchest can read.")
        }
        return .result(value: await ScreenModule.recognizeText(in: cgImage))
    }
}

struct SummarizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Text"
    static let description = IntentDescription("Returns an Apple Intelligence summary of the text, made on this Mac. It’s model output and may be wrong.")

    @Parameter(title: "Text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Summarize \(\.$text)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            return .result(value: try await Intelligence.summarize(text))
        } catch {
            throw ToolchestIntentError.failed(error.localizedDescription)
        }
    }
}

struct TranslateTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Text on Device"
    static let description = IntentDescription("Translates text with Apple’s on-device Translation. The language pair must already be downloaded.")

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Into", description: "A language code such as en, de or fa. Empty means the system language.") var target: String?

    static var parameterSummary: some ParameterSummary { Summary("Translate \(\.$text) into \(\.$target)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            return .result(value: try await TextTranslator.translate(text, into: target))
        } catch {
            throw ToolchestIntentError.failed(error.localizedDescription)
        }
    }
}

// MARK: Audio

struct SetMicrophoneMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Microphone"

    @Parameter(title: "Muted", default: .toggle) var state: SwitchState

    static var parameterSummary: some ParameterSummary { Summary("Set microphone mute to \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.audio.enabled && app.settings.audio.micMute, "Mic mute")
        app.audio.setMicMuted(state.resolve(current: app.audio.currentInputMuted))
        return .result()
    }
}

struct NextAudioDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch to Next Audio Device"

    @Parameter(title: "Kind", default: .output) var direction: AudioDirection

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.audio.enabled && app.settings.audio.deviceSwitch, "Device switching")
        app.audio.cycle(input: direction == .input)
        return .result()
    }
}

struct SetOutputDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Output Device"

    @Parameter(title: "Device") var device: AudioDeviceEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.audio.enabled && app.settings.audio.deviceSwitch, "Device switching")
        guard let target = CoreAudioHAL.devices().first(where: { $0.uid == device.id && $0.hasOutput }),
              CoreAudioHAL.setDefaultDevice(target.id, input: false) else {
            throw ToolchestIntentError.failed("\(device.name) isn’t available.")
        }
        HUD.shared.show(target.symbol, target.name, detail: "Output")
        return .result()
    }
}

// MARK: Windows and keyboard

struct IsolateWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Isolate Window"
    static let description = IntentDescription("Hides every app except the one in front.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.windows.enabled && app.settings.windows.isolate, "Isolate window")
        app.windows.isolate()
        return .result()
    }
}

struct ShowDropdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Drop-down Window"

    @Parameter(title: "App", default: .finder) var app: DropdownApp

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = try toolchest()
        let s = controller.settings.keyboard
        switch app {
        case .finder:
            try require(s.enabled && s.dropdownFinder, "Drop-down Finder")
            controller.keyboard.dropdown("com.apple.finder")
        case .terminal:
            try require(s.enabled && s.dropdownTerminal, "Drop-down terminal")
            controller.keyboard.dropdown(KeyboardModule.terminalBundleID)
        }
        return .result()
    }
}

struct SetHyperKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Hyper Key On or Off"
    static let description = IntentDescription("Caps Lock as ⌃⌥⇧⌘. Turning it on also turns on the Keyboard module.")

    @Parameter(title: "Hyper key", default: .toggle) var state: SwitchState

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        let on = state.resolve(current: app.settings.hyperActive)
        if on { app.prefs.settings.keyboard.enabled = true }
        app.prefs.settings.keyboard.hyper = on
        return .result()
    }
}

// MARK: Mail and Notes

struct CopyMailLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Mail Message Link"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.links.enabled && app.settings.links.mailLink, "Mail links")
        Links.copyMailLink()
        return .result()
    }
}

struct CopyNoteLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Note Link"

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        try require(app.settings.links.enabled && app.settings.links.noteLink, "Note links")
        Links.copyNoteLink()
        return .result()
    }
}

// MARK: Toolchest itself

struct SetModuleIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Toolchest Module On or Off"

    @Parameter(title: "Module") var module: ToolchestModuleEnum
    @Parameter(title: "State", default: .toggle) var state: SwitchState

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$module) \(\.$state)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try toolchest()
        app.prefs.settings.setEnabled(module.module, state.resolve(current: app.settings.isEnabled(module.module)))
        return .result()
    }
}

struct OpenToolchestSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Toolchest Settings"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        return .result()
    }
}

// MARK: Focus filter

/// Per-Focus profile: mute the mic, force the quit guard on, or keep the Mac awake while a Focus is on.
/// macOS calls perform() with these values when the Focus starts and with the defaults when it ends.
struct ToolchestFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Toolchest Filter"
    static let description = IntentDescription("Mute the microphone, turn on the quit guard or keep the Mac awake while this Focus is on.")

    @Parameter(title: "Mute the microphone", default: false) var muteMicrophone: Bool
    @Parameter(title: "Guard ⌘Q in every app", default: false) var quitGuard: Bool
    @Parameter(title: "Keep the Mac awake", default: false) var keepAwake: Bool

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if muteMicrophone { parts.append("Mic muted") }
        if quitGuard { parts.append("Quit guard") }
        if keepAwake { parts.append("Keep awake") }
        return DisplayRepresentation(title: "Toolchest", subtitle: "\(parts.isEmpty ? "No changes" : parts.joined(separator: ", "))")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try toolchest().applyFocus(FocusOverrides(muteMicrophone: muteMicrophone, quitGuard: quitGuard, keepAwake: keepAwake))
        return .result()
    }
}

// MARK: Suggested shortcuts

struct ToolchestShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartKeepAwakeIntent(), phrases: ["Keep my Mac awake with \(.applicationName)", "\(.applicationName) keep awake"],
                    shortTitle: "Keep Awake", systemImageName: "cup.and.heat.waves")
        AppShortcut(intent: StopKeepAwakeIntent(), phrases: ["Let my Mac sleep with \(.applicationName)"],
                    shortTitle: "Let Mac Sleep", systemImageName: "cup.and.saucer")
        AppShortcut(intent: CaptureTextIntent(), phrases: ["Capture text with \(.applicationName)"],
                    shortTitle: "Capture Text", systemImageName: "text.viewfinder")
        AppShortcut(intent: CaptureAndTranslateIntent(), phrases: ["Translate the screen with \(.applicationName)"],
                    shortTitle: "Capture and Translate", systemImageName: "translate")
        AppShortcut(intent: SetMicrophoneMuteIntent(), phrases: ["Mute my mic with \(.applicationName)", "\(.applicationName) mute"],
                    shortTitle: "Mute Microphone", systemImageName: "mic.slash")
        AppShortcut(intent: NextAudioDeviceIntent(), phrases: ["Next audio device with \(.applicationName)"],
                    shortTitle: "Next Audio Device", systemImageName: "hifispeaker")
        AppShortcut(intent: StartCleaningModeIntent(), phrases: ["Start cleaning mode in \(.applicationName)"],
                    shortTitle: "Cleaning Mode", systemImageName: "display")
        AppShortcut(intent: IsolateWindowIntent(), phrases: ["Isolate this window with \(.applicationName)"],
                    shortTitle: "Isolate Window", systemImageName: "macwindow")
        AppShortcut(intent: PickColorIntent(), phrases: ["Pick a color with \(.applicationName)"],
                    shortTitle: "Pick Color", systemImageName: "eyedropper")
        AppShortcut(intent: SetDarkModeIntent(), phrases: ["Switch dark mode with \(.applicationName)"],
                    shortTitle: "Dark Mode", systemImageName: "circle.lefthalf.filled")
    }
}
