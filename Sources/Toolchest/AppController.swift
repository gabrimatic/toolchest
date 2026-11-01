import AppKit
import ApplicationServices
import SwiftUI
import os
import WidgetKit

/// Owns the modules, applies settings to them, and routes hotkeys and tap signals.
@MainActor
@Observable
final class AppController {
    let prefs: Prefs
    @ObservationIgnored let keepAwake = KeepAwake()
    @ObservationIgnored let cleaning = CleaningMode()
    @ObservationIgnored let windows = WindowsModule()
    @ObservationIgnored let keyboard = KeyboardModule()
    @ObservationIgnored let screen = ScreenModule()
    @ObservationIgnored let audio = AudioModule()
    @ObservationIgnored let finder = FinderModule()
    @ObservationIgnored let clipboard = ClipboardGuard()
    @ObservationIgnored private let keyboardWatcher = KeyboardWatcher()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "app")

    /// Bumped when a permission may have changed, so the UI re-reads permission state.
    var permissionsToken = 0
    /// Set when a feature needs the event tap but macOS refused it.
    var tapUnavailable = false
    /// Hotkeys macOS refused because another app holds them.
    var refusedHotkeys: [String] = []
    /// Bumped on Keep Awake and mic changes so menus and settings refresh.
    var stateToken = 0
    /// Called after every state change, for the menu bar icon.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// The page Settings shows.
    var settingsPage: SettingsPage = .general
    /// Shows the welcome window (set by the app delegate).
    @ObservationIgnored var onShowOnboarding: (() -> Void)?

    var settings: Settings { prefs.settings }

    /// "Show Again": the welcome window shows again and every permission can be asked for again.
    func resetOnboarding() {
        Onboarding.reset()
        permissionsToken += 1
        onShowOnboarding?()
    }

    /// The running controller, for App Intents (they run in Toolchest's process).
    static private(set) weak var current: AppController?

    /// What the active Focus asks for (see ToolchestFocusFilter). Kept across launches.
    private(set) var focus = FocusOverrides.load()
    @ObservationIgnored private var focusMutedMic = false
    @ObservationIgnored private var focusStartedKeepAwake = false
    @ObservationIgnored let widgetIPC = IPCServer(portName: WidgetIPC.portName, secretURL: WidgetIPC.secretURL)
    @ObservationIgnored private var widgetReload: DispatchWorkItem?

    init(prefs: Prefs = Prefs()) {
        self.prefs = prefs
    }

    func start() {
        Self.current = self
        widgetIPC.onRequest = { [weak self] data in self?.handleWidget(data) ?? IPCServer.rejection }
        widgetIPC.start()
        EventTap.shared.onSignal = { [weak self] signal in self?.handle(signal) }
        keepAwake.onChange = { [weak self] in self?.stateChanged() }
        audio.onChange = { [weak self] in self?.stateChanged() }
        keyboardWatcher.onKeyboardAdded = { [weak self] in
            guard let self, self.settings.hyperActive, EventTap.shared.isRunning else { return }
            HyperMapping.apply()
        }
        prefs.onChange = { [weak self] _ in self?.apply() }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            EventTap.shared.setFrontmost(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier ?? 0)
            _ = self
        }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.finder" { self?.finder.finderRelaunched() }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.lockedOrSleeping() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.keepAwake.expireIfDue()
            // Keyboards come back as new HID services after sleep.
            guard let self, self.settings.hyperActive, EventTap.shared.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { HyperMapping.apply() }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.lockedOrSleeping() }
        observe(distributed, Notification.Name("com.apple.accessibility.api")) { [weak self] _ in
            // Posted when any app's Accessibility grant changes; the change lands a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    self?.permissionsToken += 1
                    self?.apply()
                }
            }
        }

        let front = NSWorkspace.shared.frontmostApplication
        EventTap.shared.setFrontmost(bundleID: front?.bundleIdentifier, pid: front?.processIdentifier ?? 0)

        // A previous run that crashed may have left Caps Lock mapped to F18.
        if !settings.hyperActive { HyperMapping.revert() }
        apply()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated { block(note) }
        }
        observers.append((center, token))
    }

    private func lockedOrSleeping() {
        if settings.clipboardClearActive { clipboard.clearSeenNow() }
        if cleaning.isActive { cleaning.stop() }
    }

    func shutdown() {
        cleaning.stop()
        keepAwake.stop(notify: false)
        HyperMapping.revert()
        finder.ipc.stop()
        widgetIPC.stop()
        HotkeyCenter.shared.unregisterAll()
    }

    // MARK: Applying settings

    func apply() {
        let s = settings
        Haptics.enabled = s.general.haptics
        windows.apply(s.windows)
        keyboard.settings = s.keyboard
        screen.settings = s.screen
        audio.apply(s.audio)
        finder.apply(s.finder)
        clipboard.age = s.utilities.clipboardAge
        if !s.clipboardClearActive { clipboard.reset() }
        if !(s.utilities.enabled && s.utilities.keepAwake) && keepAwake.isActive { keepAwake.stop() }

        var config = TapConfig()
        if s.finder.enabled {
            config.finder = .init(cutPaste: s.finder.cutPaste, returnOpens: s.finder.returnOpens, reopen: s.finder.reopenClosed,
                                  newFile: s.finder.newTextFile, pasteAsFile: s.finder.pasteAsFile)
        }
        config.quitGuard = s.quitGuardActive || focus.quitGuard
        config.closeGuardApps = s.quitGuardActive ? Set(s.windows.closeGuardBundleIDs) : []
        config.hyper = s.hyperActive
        config.hyperEscapeOnTap = s.keyboard.hyperEscOnTap
        config.dockClick = s.dockClickActive
        config.dockMiddle = s.dockMiddleActive
        config.greenFill = s.greenFillActive
        config.watchClipboard = s.clipboardClearActive
        config.watchTyping = s.autoMuteActive

        let tapOK: Bool
        if config.isEmpty {
            EventTap.shared.update(config)
            tapOK = true
        } else if AXIsProcessTrusted() {
            tapOK = EventTap.shared.update(config)
        } else {
            EventTap.shared.update(TapConfig())
            tapOK = false
        }
        tapUnavailable = !tapOK

        // Caps Lock only becomes F18 while the tap is there to turn F18 into Hyper.
        if s.hyperActive && tapOK && EventTap.shared.isRunning {
            if !HyperMapping.apply() { log.error("Hyper mapping not applied") }
            keyboardWatcher.start()
        } else {
            HyperMapping.revert()
            keyboardWatcher.stop()
        }

        HotkeyCenter.shared.apply(hotkeyBindings(s))
        refusedHotkeys = HotkeyCenter.shared.failed
        stateChanged()
    }

    /// Something widgets or controls show changed: refresh menus now and widgets shortly.
    func stateChanged() {
        stateToken += 1
        onStateChange?()
        widgetReload?.cancel()
        let work = DispatchWorkItem {
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
        }
        widgetReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Focus

    func applyFocus(_ overrides: FocusOverrides) {
        focus = overrides
        overrides.save()
        if let device = CoreAudioHAL.defaultDevice(input: true) {
            if overrides.muteMicrophone && !audio.currentInputMuted {
                if CoreAudioHAL.setMuted(device, input: true, true) { focusMutedMic = true }
            } else if !overrides.muteMicrophone && focusMutedMic {
                CoreAudioHAL.setMuted(device, input: true, false)
                focusMutedMic = false
            }
        }
        if overrides.keepAwake && !keepAwake.isActive {
            focusStartedKeepAwake = keepAwake.start(for: nil)
        } else if !overrides.keepAwake && focusStartedKeepAwake {
            keepAwake.stop()
            focusStartedKeepAwake = false
        }
        apply()
    }

    // MARK: Widgets and controls

    func widgetState(error: String? = nil) -> WidgetIPC.State {
        let s = settings
        var state = WidgetIPC.State()
        state.keepAwakeAvailable = s.utilities.enabled && s.utilities.keepAwake
        state.keepAwakeOn = keepAwake.isActive
        state.keepAwakeUntil = keepAwake.until
        state.micAvailable = s.audio.enabled && s.audio.micMute
        state.micMuted = audio.currentInputMuted
        let devices = CoreAudioHAL.devices()
        if let output = CoreAudioHAL.defaultDevice(input: false), let device = devices.first(where: { $0.id == output }) {
            state.outputName = device.name
            state.outputSymbol = device.symbol
        }
        if let input = CoreAudioHAL.defaultDevice(input: true) {
            state.inputName = devices.first { $0.id == input }?.name
        }
        state.cleaningAvailable = s.utilities.enabled && s.utilities.cleaning
        state.hyperAvailable = true
        state.hyperOn = s.hyperActive
        state.error = error
        return state
    }

    /// Commands from widgets and controls. The module switches still apply.
    func performWidget(_ command: WidgetIPC.Command, minutes: Int?) -> String? {
        let s = settings
        switch command {
        case .state:
            return nil
        case .keepAwakeOn:
            guard s.utilities.enabled && s.utilities.keepAwake else { return "Turn on Keep Awake in Toolchest." }
            return keepAwake.start(for: minutes.map { Double($0) * 60 }) ? nil : "macOS refused to keep the Mac awake."
        case .keepAwakeOff:
            keepAwake.stop()
        case .micMute, .micUnmute:
            guard s.audio.enabled && s.audio.micMute else { return "Turn on Mic mute in Toolchest." }
            audio.setMicMuted(command == .micMute)
        case .nextOutput:
            guard s.audio.enabled && s.audio.deviceSwitch else { return "Turn on device switching in Toolchest." }
            audio.cycle(input: false)
        case .cleaning:
            guard s.utilities.enabled && s.utilities.cleaning else { return "Turn on Cleaning Mode in Toolchest." }
            // Let the control's tap finish before the input gate closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.cleaning.start() }
        case .hyperOn:
            prefs.settings.keyboard.enabled = true
            prefs.settings.keyboard.hyper = true
        case .hyperOff:
            prefs.settings.keyboard.hyper = false
        }
        return nil
    }

    private func handleWidget(_ data: Data) -> Data {
        guard let request = try? JSONDecoder().decode(WidgetIPC.Request.self, from: data) else { return IPCServer.rejection }
        let error = performWidget(request.command, minutes: request.minutes)
        if request.command != .state { stateChanged() }
        return (try? JSONEncoder().encode(widgetState(error: error))) ?? IPCServer.rejection
    }

    private func hotkeyBindings(_ s: Settings) -> [(name: String, combo: KeyCombo, action: @MainActor () -> Void)] {
        var list: [(name: String, combo: KeyCombo, action: @MainActor () -> Void)] = []
        func add(_ action: HotkeyAction, _ enabled: Bool, _ run: @escaping @MainActor () -> Void) {
            guard enabled, let combo = s.hotkeys[action.rawValue] else { return }
            list.append((action.title, combo, run))
        }
        add(.isolate, s.windows.enabled && s.windows.isolate) { [weak self] in self?.windows.isolate() }
        add(.captureText, s.screen.enabled && s.screen.captureText) { [weak self] in self?.screen.captureText() }
        add(.translate, s.screen.enabled && s.screen.translate) { [weak self] in self?.screen.captureAndTranslate() }
        add(.summarize, s.screen.enabled && s.screen.summarize) { [weak self] in self?.screen.captureAndSummarize() }
        add(.scanCode, s.screen.enabled && s.screen.scanCode) { [weak self] in self?.screen.scanRegion() }
        add(.pickColor, s.screen.enabled && s.screen.colorPicker) { [weak self] in self?.screen.pickColor() }
        add(.micMute, s.audio.enabled && s.audio.micMute) { [weak self] in self?.audio.toggleMicMute() }
        add(.cycleOutput, s.audio.enabled && s.audio.deviceSwitch) { [weak self] in self?.audio.cycle(input: false) }
        add(.cycleInput, s.audio.enabled && s.audio.deviceSwitch) { [weak self] in self?.audio.cycle(input: true) }
        add(.keepAwake, s.utilities.enabled && s.utilities.keepAwake) { [weak self] in self?.toggleKeepAwake() }
        add(.cleaning, s.utilities.enabled && s.utilities.cleaning) { [weak self] in self?.cleaning.start() }
        add(.darkMode, s.utilities.enabled && s.utilities.toggles) { SystemToggles.toggleDarkMode() }
        add(.clearNotifications, s.utilities.enabled && s.utilities.notifications) { NotificationsAX.clearAll() }
        add(.openNotification, s.utilities.enabled && s.utilities.notifications) { NotificationsAX.openTop() }
        add(.mailLink, s.links.enabled && s.links.mailLink) { Links.copyMailLink() }
        add(.noteLink, s.links.enabled && s.links.noteLink) { Links.copyNoteLink() }
        add(.dropdownFinder, s.keyboard.enabled && s.keyboard.dropdownFinder) { [weak self] in self?.keyboard.dropdown("com.apple.finder") }
        add(.dropdownTerminal, s.keyboard.enabled && s.keyboard.dropdownTerminal) { [weak self] in
            self?.keyboard.dropdown(KeyboardModule.terminalBundleID)
        }
        if s.keyboard.enabled {
            for app in s.keyboard.appHotkeys {
                guard let combo = app.combo else { continue }
                let bundleID = app.bundleID
                list.append(("Open \(app.name)", combo, { [weak self] in self?.keyboard.toggleApp(bundleID) }))
            }
        }
        return list
    }

    /// Every hotkey Toolchest has assigned, for conflict checks in the recorder.
    func assignedHotkeys(excluding name: String) -> [(KeyCombo, String)] {
        var list: [(KeyCombo, String)] = []
        for action in HotkeyAction.allCases where action.title != name {
            if let combo = settings.hotkeys[action.rawValue] { list.append((combo, action.title)) }
        }
        for app in settings.keyboard.appHotkeys where "Open \(app.name)" != name {
            if let combo = app.combo { list.append((combo, "Open \(app.name)")) }
        }
        return list
    }

    func toggleKeepAwake() {
        if keepAwake.isActive {
            keepAwake.stop()
            HUD.shared.show("cup.and.saucer", "Keep Awake off")
        } else {
            keepAwake.start(for: nil)
            HUD.shared.show("cup.and.heat.waves.fill", "Keep Awake on", detail: "Until turned off")
        }
    }

    // MARK: Signals from the event tap

    func handle(_ signal: TapSignal) {
        switch signal {
        case .guardKey(let key, let down, let pid): windows.guardKey(key, down: down, pid: pid)
        case .finderCut(let before): finder.cut(changeCountBefore: before)
        case .finderPasteMove: finder.pasteMoved()
        case .finderPasteAsFile: finder.pasteAsFile()
        case .finderReopen: finder.reopen()
        case .finderNewFile: finder.newTextFile()
        case .finderClose: finder.close()
        case .dockLeftDown(let point, let pid): windows.dockLeftDown(point, frontPID: pid)
        case .dockLeftUp(let point): windows.dockLeftUp(point)
        case .middleDown(let point): windows.middleDown(point)
        case .middleUp: windows.middleUp()
        case .greenButton(let window, let fullScreen): windows.greenButton(window, fullScreen: fullScreen)
        case .copyObserved, .clickObserved: clipboard.noteCopyCandidate()
        case .pasteObserved: clipboard.notePaste()
        case .typing: audio.noteTyping()
        case .cleaningEscDown, .cleaningEscUp, .cleaningExit: cleaning.handle(signal)
        }
    }
}

/// What a Focus filter asks Toolchest to do while that Focus is on.
struct FocusOverrides: Codable, Equatable, Sendable {
    var muteMicrophone = false
    var quitGuard = false
    var keepAwake = false

    static let storageKey = "focus.v1"

    static func load(_ defaults: UserDefaults = .standard) -> FocusOverrides {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(FocusOverrides.self, from: $0) } ?? FocusOverrides()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
