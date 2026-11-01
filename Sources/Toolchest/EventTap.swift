import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// What the tap needs to decide, published from the main actor whenever settings change.
struct TapConfig: Sendable, Equatable {
    var finder = KeyRules.FinderOptions()
    var quitGuard = false
    var closeGuardApps: Set<String> = []
    var hyper = false
    var hyperEscapeOnTap = false
    var dockClick = false
    var dockMiddle = false
    var greenFill = false
    var watchClipboard = false
    var watchTyping = false

    var wantsKeyboard: Bool {
        finder != KeyRules.FinderOptions() || quitGuard || hyper || watchClipboard || watchTyping
    }
    var wantsMouse: Bool { dockClick || dockMiddle || greenFill || watchClipboard || hyper }
    var isEmpty: Bool { !wantsKeyboard && !wantsMouse }
}

/// Things the tap saw that the main actor acts on.
enum TapSignal: Sendable {
    case guardKey(HoldGuard.Key, down: Bool, pid: pid_t)
    case finderCut(changeCountBefore: Int)
    case finderPasteMove
    case finderPasteAsFile
    case finderReopen
    case finderNewFile
    case finderClose
    case dockLeftDown(CGPoint, frontPID: pid_t)
    case dockLeftUp(CGPoint)
    case middleDown(CGPoint)
    case middleUp
    case greenButton(AXElement, fullScreen: Bool)
    case copyObserved
    case pasteObserved
    case clickObserved
    case typing
    case cleaningEscDown
    case cleaningEscUp
    case cleaningExit
}

/// One shared CGEventTap on its own thread, created only while some feature needs it and torn
/// down when none does. It never logs or stores key contents: it only matches a handful of
/// combinations and passes everything else through untouched.
///
/// An active (modifying) tap needs the Accessibility permission.
final class EventTap: @unchecked Sendable {
    static let shared = EventTap()
    /// Marks events Toolchest posts itself, so the tap lets them through.
    static let syntheticTag: Int64 = 0x4B4E_434B

    private struct State {
        var config = TapConfig()
        var frontBundleID: String?
        var frontPID: pid_t = 0
        var cutChangeCount: Int?
        var remapped: [Int64: (code: Int64, addFlags: UInt64)] = [:]
        var guarding: Int64?
        var swallowLeftUp = false
        var hyper = HyperState()
        var cleaning: CleaningGate?
        var lastTypingSignal: TimeInterval = 0
        var port: PortBox?
    }

    /// The tap's port, shared with the tap thread (a CFMachPort is safe to use from any thread).
    private struct PortBox: @unchecked Sendable { let port: CFMachPort }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "tap")
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "info.gabrimatic.toolchest"

    // Owned by the main actor.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var installedMask: CGEventMask = 0

    /// Delivered on the main thread.
    var onSignal: (@MainActor @Sendable (TapSignal) -> Void)?

    var isRunning: Bool { tap != nil }

    // MARK: Main-actor control

    /// Applies a new config, creating, re-creating or removing the tap as needed.
    /// Returns false when a needed tap could not be created (no Accessibility permission).
    @MainActor @discardableResult
    func update(_ config: TapConfig) -> Bool {
        state.withLock { $0.config = config }
        let cleaning = state.withLock { $0.cleaning != nil }
        let mask = Self.mask(for: config, cleaning: cleaning)
        if mask == 0 { stop(); return true }
        if tap != nil && mask == installedMask { return true }
        stop()
        return start(mask: mask)
    }

    @MainActor
    func setFrontmost(bundleID: String?, pid: pid_t) {
        state.withLock {
            $0.frontBundleID = bundleID
            $0.frontPID = pid
        }
    }

    @MainActor
    func setCutChangeCount(_ count: Int?) { state.withLock { $0.cutChangeCount = count } }

    /// Starts swallowing all input. The caller has already put the overlay on screen.
    @MainActor
    func beginCleaning(duration: TimeInterval) -> Bool {
        let gate = CleaningGate(start: ProcessInfo.processInfo.systemUptime, duration: duration)
        state.withLock { $0.cleaning = gate }
        let config = state.withLock { $0.config }
        stop()
        if start(mask: Self.mask(for: config, cleaning: true)) { return true }
        state.withLock { $0.cleaning = nil }
        _ = update(config)
        return false
    }

    /// Stops swallowing. Safe to call more than once.
    @MainActor
    func endCleaning() {
        let wasCleaning = state.withLock { s -> Bool in
            defer { s.cleaning = nil }
            return s.cleaning != nil
        }
        guard wasCleaning else { return }
        let config = state.withLock { $0.config }
        stop()
        if !config.isEmpty { _ = start(mask: Self.mask(for: config, cleaning: false)) }
    }

    /// For timers: whether the cleaning gate wants to exit now (Esc held or time up).
    @MainActor
    func cleaningTick() -> Bool {
        state.withLock { s in
            guard var gate = s.cleaning else { return true }
            let done = gate.tick(now: ProcessInfo.processInfo.systemUptime)
            s.cleaning = gate
            return done
        }
    }

    @MainActor
    func cleaningEscProgress() -> Double {
        state.withLock { $0.cleaning?.escProgress(now: ProcessInfo.processInfo.systemUptime) ?? 0 }
    }

    static func mask(for config: TapConfig, cleaning: Bool) -> CGEventMask {
        if cleaning {
            // Everything: keys, clicks, movement, scrolling, gestures and media keys.
            return CGEventMask.max
        }
        var mask: CGEventMask = 0
        func add(_ type: CGEventType) { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
        if config.wantsKeyboard {
            add(.keyDown); add(.keyUp); add(.flagsChanged)
        }
        if config.wantsMouse {
            add(.leftMouseDown); add(.leftMouseUp)
            if config.dockMiddle { add(.otherMouseDown); add(.otherMouseUp) }
        }
        return mask
    }

    @MainActor
    private func start(mask: CGEventMask) -> Bool {
        guard tap == nil else { return true }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("event tap refused (Accessibility not granted?)")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        tap = port
        let box = PortBox(port: port)
        state.withLock { $0.port = box }
        installedMask = mask
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let unsafeSource = source
        nonisolated(unsafe) let unsafePort = port
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            self?.runLoop = loop
            CFRunLoopAddSource(loop, unsafeSource, .commonModes)
            CGEvent.tapEnable(tap: unsafePort, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Toolchest event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    @MainActor
    private func stop() {
        guard let port = tap else { return }
        releaseHyperIfHeld()
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        installedMask = 0
        state.withLock {
            $0.port = nil
            $0.remapped.removeAll()
            $0.guarding = nil
            $0.swallowLeftUp = false
        }
    }

    // MARK: Tap thread

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a slow tap off; turn it back on (the cleaning deadline still applies).
            if let box = state.withLock({ $0.port }) { CGEvent.tapEnable(tap: box.port, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return pass }

        let now = ProcessInfo.processInfo.systemUptime
        if let verdict = cleaningVerdict(type, event, now: now) {
            return verdict ? pass : nil
        }

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return handleKey(type, event, now: now)
        case .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp:
            return handleMouse(type, event)
        default:
            return pass
        }
    }

    /// nil when cleaning mode is off; true to pass the event, false to swallow it.
    private func cleaningVerdict(_ type: CGEventType, _ event: CGEvent, now: TimeInterval) -> Bool? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let input: CleaningGate.Input
        if type == .keyDown && keyCode == Int64(kVK_Escape) {
            input = .escDown
        } else if type == .keyUp && keyCode == Int64(kVK_Escape) {
            input = .escUp
        } else {
            input = .other
        }
        let result = state.withLock { s -> (CleaningGate.Verdict, Bool)? in
            guard var gate = s.cleaning else { return nil }
            let firstEscDown = input == .escDown && gate.escDownAt == nil
            let verdict = gate.process(input, now: now)
            s.cleaning = gate
            return (verdict, firstEscDown)
        }
        guard let (verdict, firstEscDown) = result else { return nil }
        switch verdict {
        case .swallow:
            if firstEscDown { send(.cleaningEscDown) }
            if input == .escUp { send(.cleaningEscUp) }
            return false
        case .exit:
            send(.cleaningExit)
            return input == .other
        case .pass:
            return true
        }
    }

    private func handleKey(_ type: CGEventType, _ event: CGEvent, now: TimeInterval) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = KeyRules.Mods(event.flags)
        let snapshot = state.withLock { ($0.config, $0.frontBundleID, $0.frontPID) }
        let (config, frontBundleID, frontPID) = snapshot

        if type == .flagsChanged {
            // Command released while a guarded ⌘Q/⌘W is held counts as letting go.
            let commandDown = event.flags.contains(.maskCommand)
            let released = state.withLock { s -> Bool in
                guard s.guarding != nil, !commandDown else { return false }
                s.guarding = nil
                return true
            }
            if released { send(.guardKey(.quit, down: false, pid: frontPID)) }
            return pass
        }

        let isDown = type == .keyDown
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Hyper key first: it changes what every other key means.
        if config.hyper {
            let output = state.withLock { s -> HyperState.Output in
                isDown ? s.hyper.keyDown(keyCode: Int(keyCode), now: now)
                    : s.hyper.keyUp(keyCode: Int(keyCode), now: now, escapeOnTap: config.hyperEscapeOnTap)
            }
            switch output {
            case .pressModifiers:
                Synth.postHyperModifiers(down: true)
                return nil
            case .swallow:
                return nil
            case .releaseModifiers(let sendEscape):
                Synth.postHyperModifiers(down: false)
                if sendEscape { Synth.postKey(Int64(kVK_Escape), flags: []) }
                return nil
            case .addModifiers:
                event.flags.formUnion(Synth.hyperFlags)
                return pass
            case .pass:
                break
            }
        }

        // Key-ups of keys we rewrote on the way down get the same rewrite.
        if let rule = state.withLock({ s -> (code: Int64, addFlags: UInt64)? in
            guard let rule = s.remapped[keyCode] else { return nil }
            if !isDown { s.remapped[keyCode] = nil }
            return rule
        }) {
            event.setIntegerValueField(.keyboardEventKeycode, value: rule.code)
            event.flags = CGEventFlags(rawValue: event.flags.rawValue | rule.addFlags)
            return pass
        }

        // The quit guard.
        if config.quitGuard {
            let guarding = state.withLock { $0.guarding }
            if let guarding, guarding == keyCode {
                if !isDown {
                    state.withLock { $0.guarding = nil }
                    send(.guardKey(.quit, down: false, pid: frontPID))
                }
                return nil
            }
            if isDown && !isRepeat {
                let key = KeyRules.quitKey(keyCode: Int(keyCode), mods: mods, frontBundleID: frontBundleID,
                                           ownBundleID: ownBundleID, closeGuardApps: config.closeGuardApps)
                if key != .none {
                    state.withLock { $0.guarding = keyCode }
                    send(.guardKey(key == .quit ? .quit : .close, down: true, pid: frontPID))
                    return nil
                }
            }
        }

        if isDown {
            if config.watchClipboard && mods == .command {
                if keyCode == Int64(kVK_ANSI_C) || keyCode == Int64(kVK_ANSI_X) { send(.copyObserved) }
                if keyCode == Int64(kVK_ANSI_V) { send(.pasteObserved) }
            }
            if config.watchTyping && mods.isDisjoint(with: [.command, .control]) {
                let due = state.withLock { s -> Bool in
                    guard now - s.lastTypingSignal > 0.25 else { return false }
                    s.lastTypingSignal = now
                    return true
                }
                if due { send(.typing) }
            }
        }

        // Finder remaps.
        guard isDown, !isRepeat, frontBundleID == "com.apple.finder",
              config.finder != KeyRules.FinderOptions() else { return pass }
        let cutArmed = state.withLock { $0.cutChangeCount } == Pasteboard.changeCount
        let rule = KeyRules.finderRule(
            keyCode: Int(keyCode), mods: mods, options: config.finder, cutArmed: cutArmed,
            focusInFileList: { Self.finderFocusInFileList(pid: frontPID) },
            pasteboard: { Pasteboard.kind() })
        switch rule {
        case .none:
            return pass
        case .cutAsCopy:
            let before = Pasteboard.changeCount
            remap(event, from: keyCode, to: Int64(kVK_ANSI_C), addFlags: 0)
            send(.finderCut(changeCountBefore: before))
            return pass
        case .pasteMove:
            remap(event, from: keyCode, to: keyCode, addFlags: CGEventFlags.maskAlternate.rawValue)
            state.withLock { $0.cutChangeCount = nil }
            send(.finderPasteMove)
            return pass
        case .pasteAsFile:
            send(.finderPasteAsFile)
            return nil
        case .returnOpens:
            remap(event, from: keyCode, to: Int64(kVK_DownArrow), addFlags: CGEventFlags.maskCommand.rawValue)
            return pass
        case .f2Renames:
            remap(event, from: keyCode, to: Int64(kVK_Return), addFlags: 0)
            return pass
        case .reopenClosed:
            send(.finderReopen)
            return nil
        case .newTextFile:
            send(.finderNewFile)
            return nil
        case .noteClose:
            // Held back until Toolchest has read the window's folder; Toolchest re-posts ⌘W right after.
            send(.finderClose)
            return nil
        }
    }

    /// The green button under `point`, if any. A hit test from the tap thread often answers with the
    /// window itself rather than the button, so the window's own button is checked by frame too.
    private static func greenButton(at point: CGPoint) -> AXElement? {
        guard let hit = AXElement.systemWide().hitTest(point) else { return nil }
        if hit.subrole == "AXFullScreenButton" { return hit }
        guard let window = hit.window, let button = window.element("AXFullScreenButton"),
              let frame = button.frame, frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return button
    }

    private func remap(_ event: CGEvent, from original: Int64, to code: Int64, addFlags: UInt64) {
        state.withLock { $0.remapped[original] = (code, addFlags) }
        event.setIntegerValueField(.keyboardEventKeycode, value: code)
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | addFlags)
    }

    private func handleMouse(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let (config, frontPID) = state.withLock { ($0.config, $0.frontPID) }
        let location = event.location
        if config.hyper { state.withLock { $0.hyper.noteOtherInput() } }

        switch type {
        case .leftMouseDown:
            if config.greenFill, let button = Self.greenButton(at: location), let window = button.window {
                state.withLock { $0.swallowLeftUp = true }
                send(.greenButton(window, fullScreen: event.flags.contains(.maskAlternate)))
                return nil
            }
            if config.dockClick { send(.dockLeftDown(location, frontPID: frontPID)) }
            return pass
        case .leftMouseUp:
            let swallow = state.withLock { s -> Bool in
                defer { s.swallowLeftUp = false }
                return s.swallowLeftUp
            }
            if swallow { return nil }
            if config.dockClick { send(.dockLeftUp(location)) }
            if config.watchClipboard { send(.clickObserved) }
            return pass
        case .otherMouseDown:
            if config.dockMiddle && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                send(.middleDown(location))
            }
            return pass
        case .otherMouseUp:
            if config.dockMiddle && event.getIntegerValueField(.mouseEventButtonNumber) == 2 { send(.middleUp) }
            return pass
        default:
            return pass
        }
    }

    private func send(_ signal: TapSignal) {
        guard let onSignal else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onSignal(signal) } }
    }

    @MainActor
    private func releaseHyperIfHeld() {
        let wasDown = state.withLock { $0.hyper.reset() }
        if wasDown { Synth.postHyperModifiers(down: false) }
    }

    /// Whether Finder's keyboard focus is in its file list rather than a text field, button or sheet.
    /// Fails closed: no answer means "leave the key alone".
    static func finderFocusInFileList(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let app = AXElement.application(pid, timeout: 0.08)
        guard let focused = app.element(kAXFocusedUIElementAttribute), let role = focused.role else { return false }
        if focused.subrole == "AXSearchField" { return false }
        return KeyRules.fileListRoles.contains(role)
    }
}

/// The C callback for the tap. It lives at file scope on purpose: a closure written inside a
/// main-actor method is main-actor isolated in Swift 6, and the runtime isolation check then traps
/// on the tap's own thread.
let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue().receive(type, event)
}

extension EventTap {
    /// Entry point for the tap thread.
    nonisolated func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        handle(type, event)
    }
}

/// Posting Toolchest's own key events, tagged so the tap ignores them.
enum Synth {
    static let hyperFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = EventTap.syntheticTag
        return source
    }

    static func postKey(_ code: Int64, flags: CGEventFlags, toPID pid: pid_t? = nil) {
        let source = source()
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticTag)
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
    }

    /// Presses or releases Command, Shift, Option and Control as one Hyper chord.
    static func postHyperModifiers(down: Bool) {
        let source = source()
        let keys: [(CGKeyCode, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), .maskCommand), (CGKeyCode(kVK_Shift), .maskShift),
            (CGKeyCode(kVK_Option), .maskAlternate), (CGKeyCode(kVK_Control), .maskControl),
        ]
        var flags: CGEventFlags = down ? [] : hyperFlags
        for (code, flag) in (down ? keys : keys.reversed()) {
            if down { flags.insert(flag) } else { flags.remove(flag) }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.type = .flagsChanged
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticTag)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Read-only pasteboard probes. Toolchest looks at the change count and the kinds of data present,
/// never at the contents.
enum Pasteboard {
    static var changeCount: Int { NSPasteboard.general.changeCount }

    static func kind() -> KeyRules.PasteboardKind {
        let types = NSPasteboard.general.types ?? []
        if types.contains(.fileURL) { return .files }
        if types.contains(.png) || types.contains(.tiff) || types.contains(.string) { return .imageOrText }
        return .other
    }
}
