import Darwin
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = AppController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var focusCleared: Set<ObjectIdentifier> = []
    /// Built on first use and installed only while a window is open, so a closed Toolchest is a plain
    /// menu bar item (its status item is the first thing in its menu bar).
    private lazy var mainMenu = MainMenu.build(target: self)
    private var signalSources: [DispatchSourceSignal] = []
    private let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch leaves freed heap behind; hand it back once everything has settled.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            malloc_zone_pressure_relief(nil, 0)
        }
        if handOverToRunningInstance() { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusImage(awake: false)
        // A stable name keeps macOS from forgetting where the user dragged the icon, and the
        // identifier lets accessibility clients (System Events) find it by name, not index.
        item.autosaveName = "info.gabrimatic.toolchest.status"
        item.button?.setAccessibilityLabel("Toolchest")
        item.button?.setAccessibilityIdentifier("toolchest.statusItem")
        item.button?.toolTip = "Toolchest"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        controller.onStateChange = { [weak self] in
            self?.statusItem?.button?.image = Self.statusImage(awake: self?.controller.keepAwake.isActive ?? false)
        }
        controller.onShowOnboarding = { [weak self] in self?.showOnboarding() }
        controller.start()
        log.info("launched; menu bar icon requested")
        reportStatusItemPlacement()
        // Launch at login starts on: the first launch registers it, and the switch is the user's after that.
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            if let error = LoginItem.set(true) { log.error("login item registration failed: \(error, privacy: .public)") }
            UserDefaults.standard.set(true, forKey: "loginConfigured")
        }
        if Onboarding.shouldShow() { showOnboarding() }

        // Undo the Caps Lock mapping and release input on a polite kill, too.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// A second launch hands over to the first one, which shows its window, and quits itself. A copy
    /// that was just told to quit (a relaunch) gets a moment to finish first, so a restart never hands
    /// over to a process that is on its way out.
    private func handOverToRunningInstance() -> Bool {
        let id = Bundle.main.bundleIdentifier ?? "info.gabrimatic.toolchest"
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        for _ in 0..<15 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        guard let first = others().first else { return false }
        log.notice("Toolchest is already running (pid \(first.processIdentifier)); showing its Settings and quitting this copy")
        if let url = first.bundleURL {
            // Opening a running app sends it the reopen event, which shows its welcome or Settings window.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                DispatchQueue.main.async { exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        } else {
            first.activate()
            exit(0)
        }
        return true
    }

    /// Says in the log whether the icon really got a place in the menu bar. macOS hides icons that
    /// do not fit (for example behind the notch) without telling the app, so a missing icon is
    /// otherwise silent. Runs once, one second after launch.
    private func reportStatusItemPlacement() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let item = self.statusItem else { return }
            guard item.isVisible else {
                self.log.notice("menu bar icon is hidden in the menu bar settings; open Toolchest again to get Settings")
                return
            }
            guard let window = item.button?.window else {
                self.log.error("menu bar icon has no window")
                return
            }
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            if onScreen && window.occlusionState.contains(.visible) {
                self.log.info("menu bar icon visible at x=\(Int(window.frame.minX))")
            } else {
                self.log.notice("menu bar icon is not on screen: the menu bar is full or the icon was moved away")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Toolchest again (Finder, Spotlight, Launchpad) shows its window, so everything stays
        // reachable even when the menu bar icon is hidden.
        if onboardingWindow?.isVisible == true { reveal(onboardingWindow) } else { showSettings(nil) }
        return true
    }

    static func statusImage(awake: Bool) -> NSImage {
        BrandMark.menuBarImage(description: awake ? "Toolchest, keeping awake" : "Toolchest", active: awake)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = controller.settings
        menu.addItem(.appName("Toolchest"))
        func separate() { if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) } }
        separate()

        if s.utilities.enabled && s.utilities.keepAwake {
            let awake = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
            decorate(awake, symbol: controller.keepAwake.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
            awake.submenu = keepAwakeMenu()
            menu.addItem(awake)
        }

        var screenItems: [NSMenuItem] = []
        if s.screen.enabled {
            if s.screen.colorPicker { screenItems.append(action("Color Picker", #selector(pickColor), symbol: "eyedropper", hotkey: .pickColor)) }
            if s.screen.captureText { screenItems.append(action("Capture Text", #selector(captureText), symbol: "text.viewfinder", hotkey: .captureText)) }
            if s.screen.translate { screenItems.append(action("Capture and Translate", #selector(translate), symbol: "translate", hotkey: .translate)) }
            if s.screen.summarize { screenItems.append(action("Capture and Summarize", #selector(summarize), symbol: "text.append", hotkey: .summarize)) }
            if s.screen.scanCode {
                screenItems.append(action("Scan QR Code", #selector(scanCode), symbol: "qrcode.viewfinder", hotkey: .scanCode))
                screenItems.append(action("Scan Clipboard Image", #selector(scanClipboard), symbol: "doc.on.clipboard"))
            }
        }
        if !screenItems.isEmpty {
            separate()
            screenItems.forEach(menu.addItem)
        }

        var more: [NSMenuItem] = []
        if s.audio.enabled && s.audio.micMute {
            let muted = controller.audio.currentInputMuted
            more.append(action(muted ? "Unmute Microphone" : "Mute Microphone", #selector(toggleMic),
                               symbol: muted ? "mic.fill" : "mic.slash", hotkey: .micMute))
        }
        if s.windows.enabled && s.windows.isolate {
            more.append(action("Isolate Window", #selector(isolate), symbol: "macwindow", hotkey: .isolate))
        }
        if s.utilities.enabled {
            if s.utilities.cleaning { more.append(action("Cleaning Mode", #selector(cleaning), symbol: "display", hotkey: .cleaning)) }
            if s.utilities.toggles {
                more.append(action(SystemToggles.isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode", #selector(darkMode),
                                   symbol: SystemToggles.isDarkMode ? "sun.max" : "moon", hotkey: .darkMode))
                more.append(action(SystemToggles.desktopIconsShown ? "Hide Desktop Icons" : "Show Desktop Icons", #selector(desktopIcons),
                                   symbol: "menubar.dock.rectangle"))
            }
            if s.utilities.notifications {
                more.append(action("Clear Notifications", #selector(clearNotifications), symbol: "bell.slash", hotkey: .clearNotifications))
            }
        }
        if s.links.enabled {
            if s.links.mailLink { more.append(action("Copy Mail Message Link", #selector(mailLink), symbol: "envelope", hotkey: .mailLink)) }
            if s.links.noteLink { more.append(action("Copy Note Link", #selector(noteLink), symbol: "note.text", hotkey: .noteLink)) }
        }
        if !more.isEmpty {
            separate()
            more.forEach(menu.addItem)
        }

        separate()
        let modules = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        decorate(modules, symbol: "square.grid.2x2")
        let sub = NSMenu()
        for module in Module.allCases {
            let entry = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = module.rawValue
            entry.state = s.isEnabled(module) ? .on : .off
            decorate(entry, symbol: module.symbol)
            sub.addItem(entry)
        }
        modules.submenu = sub
        menu.addItem(modules)
        if controller.tapUnavailable {
            let warning = action("Allow Accessibility…", #selector(openAccessibility), symbol: "exclamationmark.triangle")
            menu.addItem(warning)
        }
        menu.addItem(action("Settings…", #selector(showSettings(_:)), symbol: "gearshape", key: ","))
        menu.addItem(action("About Toolchest", #selector(showAbout(_:)), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(action("Quit Toolchest", #selector(quit), symbol: "power", key: "q"))
    }

    /// Off and the durations, with a checkmark on the current choice. The running countdown sits
    /// under the checked duration as its subtitle.
    func keepAwakeMenu() -> NSMenu {
        let keepAwake = controller.keepAwake
        let sub = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(keepAwakeOff), keyEquivalent: "")
        off.target = self
        off.state = keepAwake.isActive ? .off : .on
        sub.addItem(off)
        sub.addItem(.separator())
        let current = keepAwake.chosenDurationIndex
        for (index, duration) in KeepAwake.durations.enumerated() {
            let entry = NSMenuItem(title: duration.title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            if keepAwake.isActive, current == index {
                entry.state = .on
                entry.subtitle = keepAwake.statusText
            }
            sub.addItem(entry)
        }
        if keepAwake.isActive, current == nil {
            // Started by a Shortcut or a Focus with a length the menu doesn't list.
            sub.addItem(.separator())
            let status = NSMenuItem(title: keepAwake.statusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            sub.addItem(status)
        }
        return sub
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Sets a menu item's symbol. macOS 27 hides menu item images unless an item asks for them.
    private func decorate(_ item: NSMenuItem, symbol name: String) {
        item.image = symbol(name)
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private func action(_ title: String, _ selector: Selector, symbol name: String? = nil, key: String = "",
                        hotkey: HotkeyAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let name { decorate(item, symbol: name) }
        if let hotkey, let combo = controller.settings.hotkeys[hotkey.rawValue],
           let character = Self.keyEquivalent(for: combo) {
            item.keyEquivalent = character
            item.keyEquivalentModifierMask = combo.flags
        }
        return item
    }

    /// Lets the menu show a hotkey next to its item (display only: the menu isn't the one firing it).
    private static func keyEquivalent(for combo: KeyCombo) -> String? {
        let name = KeyCombo.keyName(combo.keyCode)
        return name.count == 1 ? name.lowercased() : nil
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        guard KeepAwake.durations.indices.contains(sender.tag) else { return }
        if !controller.keepAwake.start(for: KeepAwake.durations[sender.tag].seconds) {
            HUD.shared.error("macOS refused to keep the Mac awake")
        }
    }

    @objc private func keepAwakeOff() { controller.keepAwake.stop() }
    @objc private func pickColor() { controller.screen.pickColor() }
    @objc private func captureText() { controller.screen.captureText() }
    @objc private func translate() { controller.screen.captureAndTranslate() }
    @objc private func summarize() { controller.screen.captureAndSummarize() }
    @objc private func scanCode() { controller.screen.scanRegion() }
    @objc private func scanClipboard() { controller.screen.scanClipboard() }
    @objc private func toggleMic() { controller.audio.toggleMicMute() }
    @objc private func isolate() { controller.windows.isolate() }
    @objc private func cleaning() { controller.cleaning.start() }
    @objc private func darkMode() { SystemToggles.toggleDarkMode() }
    @objc private func desktopIcons() { SystemToggles.toggleDesktopIcons() }
    @objc private func clearNotifications() { NotificationsAX.clearAll() }
    @objc private func mailLink() { Links.copyMailLink() }
    @objc private func noteLink() { Links.copyNoteLink() }
    @objc private func openAccessibility() { NeedsAccess.shared.present(.accessibility, for: "Some features") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let module = Module(rawValue: raw) else { return }
        controller.prefs.settings.setEnabled(module, !controller.settings.isEnabled(module))
    }

    // MARK: Settings window

    /// The Settings window exactly as the app shows it.
    static func makeSettingsWindow(controller: AppController) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(controller: controller))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "info.gabrimatic.toolchest.settings")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(settingsSize)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Brand.ground.nsColor
        return window
    }

    private static let settingsFrameName = "ToolchestSettings"

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = Self.makeSettingsWindow(controller: controller)
            window.delegate = self
            // Size and position come back as the user left them; the first time the window is centred.
            let restored = window.setFrameUsingName(Self.settingsFrameName)
            window.setFrameAutosaveName(Self.settingsFrameName)
            if !restored { Self.place(window, size: Self.settingsSize) }
            settingsWindow = window
        }
        reveal(settingsWindow)
    }

    /// Puts `window` in the middle of the screen the pointer is on. The window is given its size
    /// first: a window made from a hosting controller is still 0 x 0 until something sizes it, and
    /// centring that puts its top-left corner at the middle of the screen.
    /// A window as big as its content has laid out.
    static func fittingSize(of window: NSWindow) -> CGSize {
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        return window.contentViewController?.view.fittingSize ?? .zero
    }

    static func place(_ window: NSWindow, size: CGSize) {
        window.setContentSize(size)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let frame = window.frame
        // Slightly above the middle, where macOS puts a centred window.
        window.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2,
                                      y: min(visible.midY - frame.height / 2 + visible.height * 0.06, visible.maxY - frame.height)))
    }

    static let settingsSize = CGSize(width: 820, height: 600)

    static func makeAboutWindow(onClose: @escaping () -> Void = {}) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView(onClose: onClose)))
        window.title = "About Toolchest"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }

    static func makeOnboardingWindow(controller: AppController, onDone: @escaping () -> Void = {}) -> NSWindow {
        let view = OnboardingView(controller: controller, onDone: onDone)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Toolchest"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }

    @objc func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            let window = Self.makeAboutWindow(onClose: { [weak self] in self?.aboutWindow?.close() })
            window.delegate = self
            Self.place(window, size: Self.fittingSize(of: window))
            aboutWindow = window
        }
        reveal(aboutWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = Self.makeOnboardingWindow(controller: controller) { [weak self] in self?.onboardingWindow?.close() }
            window.delegate = self
            Self.place(window, size: Self.fittingSize(of: window))
            onboardingWindow = window
        }
        reveal(onboardingWindow)
    }

    /// Help is the About page: what Toolchest does and how to use it.
    @objc func showHelp(_ sender: Any?) {
        controller.settingsPage = .about
        showSettings(nil)
    }

    /// Toolchest stays a menu bar app with no Dock icon; its menus show while one of its windows is in front.
    private func reveal(_ window: NSWindow?, activate: Bool = true) {
        NSApp.mainMenu = mainMenu
        if activate {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    private func settleActivationPolicy() {
        let open = [settingsWindow, onboardingWindow, aboutWindow].contains { $0?.isVisible == true || $0?.isMiniaturized == true }
        guard !open else { return }
        NSApp.mainMenu = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // SwiftUI puts the keyboard focus on the first switch when a window becomes key; the
        // window holds it until the user tabs in, so nothing opens with a focus ring.
        guard let window = notification.object as? NSWindow, window === settingsWindow, !focusCleared.contains(ObjectIdentifier(window)) else { return }
        focusCleared.insert(ObjectIdentifier(window))
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Seeing the welcome window once is enough, however it was closed.
        if closing === onboardingWindow { Onboarding.markDone() }
        // Free the SwiftUI trees while the windows are closed; Toolchest is a menu bar app.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if closing === self.settingsWindow { self.focusCleared.remove(ObjectIdentifier(closing)); self.settingsWindow = nil }
            if closing === self.onboardingWindow { self.onboardingWindow = nil }
            if closing === self.aboutWindow { self.aboutWindow = nil }
            Self.release(closing)
            self.settleActivationPolicy()
        }
    }

    /// Lets go of a closed window's hosting controller and delegate, so the SwiftUI graph under it
    /// (about 15 MB for Settings) is torn down now and not whenever the window object happens to
    /// go away; a closed Toolchest is a menu bar item and holds nothing a window needed. The frame
    /// autosave is switched off first: the saved size and position stay as the user left them,
    /// and emptying the window cannot overwrite them.
    private static func release(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.delegate = nil
        window.contentViewController = nil
        // SwiftUI finishes tearing the tree down over the next moments.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
