import AppKit
import ApplicationServices

enum WindowFill {
    /// The visible frame (AX coordinates) of the screen that holds most of `window`.
    static func targetFrame(for window: CGRect, screens: [CGRect]) -> CGRect? {
        screens.max { a, b in
            let ia = a.intersection(window), ib = b.intersection(window)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }
}

/// Quit guard, Isolate Window, Dock clicks and the green window button.
@MainActor
final class WindowsModule {
    var settings = WindowSettings()
    private var holdGuard = HoldGuard(hold: 0.6)
    private var pendingDock: (pid: pid_t, point: CGPoint, at: TimeInterval)?
    private var savedFrames: [AXElement: CGRect] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func apply(_ settings: WindowSettings) {
        self.settings = settings
        holdGuard.hold = min(max(settings.holdDuration, 0.2), 3)
        if !settings.enabled { _ = holdGuard.cancel(); HoldRing.shared.hide(completed: false) }
    }

    // MARK: Quit guard

    func guardKey(_ key: HoldGuard.Key, down: Bool, pid: pid_t) {
        let actions = down ? holdGuard.press(.key(key, pid: pid), now: now) : holdGuard.release(now: now)
        run(actions)
    }

    private func run(_ actions: [HoldGuard.Action]) {
        for action in actions {
            switch action {
            case .showRing:
                HoldRing.shared.show(duration: holdGuard.hold, symbol: "power")
            case .hideRing(let completed):
                HoldRing.shared.hide(completed: completed)
            case .scheduleCheck(let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
                    guard let self else { return }
                    self.run(self.holdGuard.check(now: self.now))
                }
            case .hint(let target):
                switch target {
                case .key(.quit, _): HUD.shared.show("command", "Hold ⌘Q to quit", detail: "Or press it twice.")
                case .key(.close, _): HUD.shared.show("command", "Hold ⌘W to close", detail: "Or press it twice.")
                case .dockQuit: HUD.shared.show("computermouse", "Hold the middle button to quit", detail: "Or click twice.")
                }
            case .fire(let target):
                fire(target)
            }
        }
    }

    private func fire(_ target: HoldGuard.Target) {
        Haptics.play(.commit)
        switch target {
        case .key(.quit, let pid), .dockQuit(let pid):
            guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
            app.terminate()
        case .key(.close, let pid):
            Synth.postKey(13, flags: .maskCommand, toPID: pid) // ⌘W, tagged so the tap lets it through
        }
    }

    // MARK: Isolate

    func isolate() {
        let front = NSWorkspace.shared.frontmostApplication
        var hidden = 0
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app != front && app.processIdentifier != ownPID && !app.isHidden {
            if app.hide() { hidden += 1 }
        }
        HUD.shared.show("macwindow", hidden == 0 ? "Nothing else to hide" : "Isolated \(front?.localizedName ?? "window")")
    }

    // MARK: Dock

    /// The running app whose Dock icon is at `point` (global top-left coordinates).
    private func dockApp(at point: CGPoint) -> NSRunningApplication? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let item = AXElement.application(dock.processIdentifier, timeout: 0.15).hitTest(point),
              item.subrole == "AXApplicationDockItem" else { return nil }
        let urlValue = item.value(kAXURLAttribute)
        let url = (urlValue as? URL) ?? (urlValue as? NSURL).map { $0 as URL }
        guard let bundleURL = url?.standardizedFileURL else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == bundleURL }
    }

    func dockLeftDown(_ point: CGPoint, frontPID: pid_t) {
        pendingDock = nil
        guard settings.enabled, settings.dockClick, AXIsProcessTrusted(),
              let app = dockApp(at: point), app.processIdentifier == frontPID, app.processIdentifier != ownPID else { return }
        pendingDock = (app.processIdentifier, point, now)
    }

    func dockLeftUp(_ point: CGPoint) {
        guard let pending = pendingDock else { return }
        pendingDock = nil
        // A drag (rearranging the Dock) or a long press (the Dock menu) is not a click.
        guard hypot(point.x - pending.point.x, point.y - pending.point.y) < 6, now - pending.at < 0.6,
              let app = NSRunningApplication(processIdentifier: pending.pid) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.dockAction(on: app)
        }
    }

    private func dockAction(on app: NSRunningApplication) {
        switch settings.dockClickAction {
        case .hide:
            app.hide()
        case .minimize:
            let element = AXElement.application(app.processIdentifier)
            for window in element.elements(kAXWindowsAttribute) where window.subrole == "AXStandardWindow" {
                window.set(kAXMinimizedAttribute, kCFBooleanTrue)
            }
        case .cycle:
            let element = AXElement.application(app.processIdentifier)
            let windows = element.elements(kAXWindowsAttribute).filter {
                $0.subrole == "AXStandardWindow" && $0.bool(kAXMinimizedAttribute) != true
            }
            if windows.count > 1, let back = windows.last {
                back.perform(kAXRaiseAction)
                back.set(kAXMainAttribute, kCFBooleanTrue)
            }
        }
    }

    func middleDown(_ point: CGPoint) {
        guard settings.enabled, settings.dockMiddleQuit, AXIsProcessTrusted(), let app = dockApp(at: point),
              app.bundleIdentifier != "com.apple.finder", app.processIdentifier != ownPID else { return }
        run(holdGuard.press(.dockQuit(pid: app.processIdentifier), now: now))
    }

    func middleUp() { run(holdGuard.release(now: now)) }

    // MARK: Green button

    func greenButton(_ window: AXElement, fullScreen: Bool) {
        if fullScreen {
            window.set("AXFullScreen", kCFBooleanTrue)
            return
        }
        guard let frame = window.frame else { return }
        let primaryHeight = Geometry.primaryHeight
        let screens = NSScreen.screens.map { Geometry.axRect(fromCocoa: $0.visibleFrame, primaryHeight: primaryHeight) }
        guard let target = WindowFill.targetFrame(for: frame, screens: screens) else { return }
        if Geometry.roughlyEqual(frame, target) {
            // Already filling: go back to where it was.
            guard let saved = savedFrames.removeValue(forKey: window) else { return }
            setFrame(window, saved)
        } else {
            savedFrames[window] = frame
            if savedFrames.count > 64 { savedFrames.removeAll() }
            setFrame(window, target)
        }
    }

    private func setFrame(_ window: AXElement, _ frame: CGRect) {
        // Position, size, then position again: apps clamp size to what fits at the current position.
        window.setPosition(frame.origin)
        window.setSize(frame.size)
        window.setPosition(frame.origin)
    }
}
