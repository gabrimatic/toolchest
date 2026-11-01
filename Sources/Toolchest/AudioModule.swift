import AppKit
import CoreAudio
import CoreGraphics

/// Decides whether a fresh Music.app launch was a side effect rather than the user's choice.
///
/// macOS starts Music when a play/pause media key (or a headphone play command, which reaches the
/// system without any key event) arrives and no other app holds the media session. A launch the
/// user wanted comes right after a click (Dock, Finder, Launchpad) or a key press (Spotlight, a
/// terminal). So: terminate the new Music process if a media key came within the last
/// `mediaKeyWindow` seconds, or if there was no click and no key press within `inputWindow`.
enum MusicGuardPolicy {
    static let mediaKeyWindow: TimeInterval = 1.5
    static let inputWindow: TimeInterval = 2.0

    static func shouldTerminate(sinceMediaKey: TimeInterval, sinceKeyDown: TimeInterval, sinceClick: TimeInterval) -> Bool {
        if sinceMediaKey < mediaKeyWindow { return true }
        return sinceKeyDown > inputWindow && sinceClick > inputWindow
    }
}

@MainActor
final class AudioModule {
    private var settings = AudioSettings()
    private var observers: [NSObjectProtocol] = []
    private var inputListener: AudioListener?
    private var muteListener: AudioListener?
    private var indicator: NSStatusItem?
    /// The user's own mute choice, kept across default-device changes.
    private(set) var userMuted = false
    private var autoMuted = false
    private var autoUnmute: DispatchWorkItem?
    var onChange: (() -> Void)?

    func apply(_ settings: AudioSettings) {
        self.settings = settings
        removeObservers()
        guard settings.enabled else {
            if autoMuted { restoreAfterAutoMute() }
            removeIndicator()
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        if settings.musicGuard {
            observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated { self.musicLaunched(bundleID: bundleID, pid: pid) }
            })
        }
        if settings.volumeCap {
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                // Give Bluetooth and USB devices a moment to come back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated { self.capVolume() }
                }
            })
        }
        if settings.micMute {
            userMuted = currentInputMuted
            inputListener = CoreAudioHAL.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) {
                MainActor.assumeIsolated { self.defaultInputChanged() }
            }
            watchMute()
            showIndicator()
        } else {
            removeIndicator()
        }
    }

    private func removeObservers() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        inputListener?.remove()
        inputListener = nil
        muteListener?.remove()
        muteListener = nil
    }

    // MARK: Music stays shut

    private func musicLaunched(bundleID: String?, pid: pid_t?) {
        guard bundleID == "com.apple.Music", let pid else { return }
        let mediaKeyType = CGEventType(rawValue: 14) ?? .null // NX_SYSDEFINED: media keys
        let sinceMediaKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: mediaKeyType)
        let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let sinceClick = min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
                             CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown))
        guard MusicGuardPolicy.shouldTerminate(sinceMediaKey: sinceMediaKey, sinceKeyDown: sinceKey, sinceClick: sinceClick),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
        // A Music that was only just launched holds no user work; make sure this instance goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let again = NSRunningApplication(processIdentifier: pid), !again.isTerminated,
               again.bundleIdentifier == "com.apple.Music" {
                again.forceTerminate()
            }
        }
        HUD.shared.show("music.note", "Kept Music closed", detail: "It was opened by a media key or headphones.")
    }

    // MARK: Mic mute

    var currentInputMuted: Bool {
        guard let device = CoreAudioHAL.defaultDevice(input: true) else { return false }
        return CoreAudioHAL.isMuted(device, input: true) ?? false
    }

    func toggleMicMute() {
        setMicMuted(!currentInputMuted, byUser: true)
    }

    func setMicMuted(_ muted: Bool) {
        setMicMuted(muted, byUser: true)
    }

    private func setMicMuted(_ muted: Bool, byUser: Bool) {
        guard let device = CoreAudioHAL.defaultDevice(input: true) else {
            HUD.shared.error("No microphone found")
            return
        }
        guard CoreAudioHAL.setMuted(device, input: true, muted) else {
            HUD.shared.error("This microphone can’t be muted", "It has no mute control macOS can set.")
            return
        }
        if byUser {
            userMuted = muted
            autoMuted = false
            HUD.shared.show(muted ? "mic.slash.fill" : "mic.fill", muted ? "Microphone muted" : "Microphone on")
        }
        updateIndicator()
        onChange?()
    }

    private func defaultInputChanged() {
        watchMute()
        // Carry the user's mute choice to the new device.
        if userMuted, let device = CoreAudioHAL.defaultDevice(input: true) {
            CoreAudioHAL.setMuted(device, input: true, true)
        }
        updateIndicator()
    }

    private func watchMute() {
        muteListener?.remove()
        muteListener = nil
        guard let device = CoreAudioHAL.defaultDevice(input: true) else { return }
        muteListener = CoreAudioHAL.listen(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) {
            MainActor.assumeIsolated { self.updateIndicator() }
        }
    }

    /// Typing during a call: mute until typing stops, unless the user muted on purpose.
    func noteTyping() {
        guard settings.enabled, settings.micMute, settings.autoMuteTyping, !userMuted,
              let device = CoreAudioHAL.defaultDevice(input: true), CoreAudioHAL.isRunningSomewhere(device) else { return }
        if !autoMuted {
            guard CoreAudioHAL.setMuted(device, input: true, true) else { return }
            autoMuted = true
            updateIndicator()
        }
        autoUnmute?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreAfterAutoMute() }
        autoUnmute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func restoreAfterAutoMute() {
        guard autoMuted else { return }
        autoMuted = false
        if !userMuted, let device = CoreAudioHAL.defaultDevice(input: true) {
            CoreAudioHAL.setMuted(device, input: true, false)
        }
        updateIndicator()
    }

    private func showIndicator() {
        if indicator == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(indicatorClicked)
            indicator = item
        }
        updateIndicator()
    }

    private func removeIndicator() {
        if let indicator { NSStatusBar.system.removeStatusItem(indicator) }
        indicator = nil
    }

    private func updateIndicator() {
        guard let button = indicator?.button else { return }
        let muted = currentInputMuted
        let image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill",
                            accessibilityDescription: muted ? "Microphone muted" : "Microphone on")
        image?.isTemplate = true
        button.image = image
        button.toolTip = muted ? "Microphone muted. Click to unmute." : "Microphone on. Click to mute."
        button.setAccessibilityLabel(muted ? "Microphone muted" : "Microphone on")
    }

    @objc private func indicatorClicked() { toggleMicMute() }

    // MARK: Device switching

    func cycle(input: Bool) {
        let devices = CoreAudioHAL.devices().filter { input ? $0.hasInput : $0.hasOutput }
        guard devices.count > 1 else {
            HUD.shared.show(input ? "mic" : "speaker.wave.2", devices.first?.name ?? "No other device",
                            detail: devices.count == 1 ? "It’s the only \(input ? "input" : "output")." : nil)
            return
        }
        guard let next = CoreAudioHAL.next(after: CoreAudioHAL.defaultDevice(input: input), in: devices) else { return }
        if CoreAudioHAL.setDefaultDevice(next.id, input: input) {
            HUD.shared.show(next.symbol, next.name, detail: input ? "Input" : "Output")
        } else {
            HUD.shared.error("Couldn’t switch to \(next.name)")
        }
    }

    // MARK: Volume cap

    func capVolume() {
        guard settings.enabled, settings.volumeCap, let device = CoreAudioHAL.defaultDevice(input: false),
              let volume = CoreAudioHAL.volume(device, input: false) else { return }
        let cap = Float(min(max(settings.volumeCapLevel, 0.05), 1))
        guard volume > cap + 0.005 else { return }
        if CoreAudioHAL.setVolume(device, input: false, cap) {
            HUD.shared.show("speaker.wave.1.fill", "Volume capped at \(Int((cap * 100).rounded()))%")
        }
    }
}
