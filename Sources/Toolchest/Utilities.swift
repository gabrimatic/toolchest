import AppKit
import ApplicationServices

// MARK: System toggles

/// Dark Mode and desktop icons. Grayscale, Night Shift, True Tone and Low Power Mode are left
/// out on purpose: macOS has no public API for them (they live in private frameworks or need root).
@MainActor
enum SystemToggles {
    static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    static func toggleDarkMode() {
        let result = AppleScript.run("""
        tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
        """)
        switch result {
        case .success:
            let dark = isDarkMode
            HUD.shared.show(dark ? "moon.fill" : "sun.max.fill", dark ? "Dark Mode" : "Light Mode")
        case .failure(.notPermitted):
            NeedsAccess.shared.present(.automationSystemEvents, for: "Dark Mode")
        case .failure(.failed(let message)):
            HUD.shared.error("Dark Mode didn’t change", message)
        }
    }

    static var desktopIconsShown: Bool {
        let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString)
        return (value as? Bool) ?? ((value as? String).map { $0 != "0" && $0.lowercased() != "false" } ?? true)
    }

    /// Flips Finder's CreateDesktop preference and relaunches Finder, which is how macOS applies it.
    static func toggleDesktopIcons() {
        let show = !desktopIconsShown
        CFPreferencesSetAppValue("CreateDesktop" as CFString, show as CFBoolean, "com.apple.finder" as CFString)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
            }
        }
        HUD.shared.show(show ? "menubar.dock.rectangle" : "rectangle.dashed", show ? "Desktop icons shown" : "Desktop icons hidden")
    }
}

// MARK: Clipboard auto-clear

/// When to clear the clipboard. Toolchest only ever clears an item it saw being copied, identified by
/// the pasteboard change count; it never reads what was copied.
enum ClipboardPolicy {
    enum Decision: Equatable { case clear, wait(TimeInterval), forget }

    static func decide(seenCount: Int, seenAt: TimeInterval, currentCount: Int, now: TimeInterval,
                       age: TimeInterval, lastPasteAt: TimeInterval?, commandHeld: Bool) -> Decision {
        // Something else was copied since: that item is not ours to clear.
        guard currentCount == seenCount else { return .forget }
        let due = seenAt + age
        if now < due { return .wait(due - now) }
        // Mid-paste: Command is down or a paste happened a moment ago.
        if commandHeld { return .wait(2) }
        if let lastPasteAt, now - lastPasteAt < 1.5 { return .wait(2) }
        return .clear
    }
}

@MainActor
final class ClipboardGuard {
    var age: TimeInterval = 60
    private var seen: (count: Int, at: TimeInterval)?
    private var lastPasteAt: TimeInterval?
    private var work: DispatchWorkItem?
    private var lastKnownCount = NSPasteboard.general.changeCount

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A copy (⌘C, ⌘X or a click that may have been a Copy menu item) just happened.
    func noteCopyCandidate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            guard count != self.lastKnownCount else { return }
            self.lastKnownCount = count
            self.seen = (count, self.now)
            self.schedule(after: self.age)
        }
    }

    func notePaste() { lastPasteAt = now }

    /// Sleep or screen lock: clear what Toolchest saw copied, whatever its age.
    func clearSeenNow() {
        guard let seen, NSPasteboard.general.changeCount == seen.count else { return }
        NSPasteboard.general.clearContents()
        lastKnownCount = NSPasteboard.general.changeCount
        self.seen = nil
        work?.cancel()
    }

    func reset() {
        work?.cancel()
        work = nil
        seen = nil
    }

    private func schedule(after delay: TimeInterval) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.evaluate() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.5), execute: item)
    }

    private func evaluate() {
        guard let seen else { return }
        let commandHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        switch ClipboardPolicy.decide(seenCount: seen.count, seenAt: seen.at, currentCount: NSPasteboard.general.changeCount,
                                      now: now, age: age, lastPasteAt: lastPasteAt, commandHeld: commandHeld) {
        case .clear:
            NSPasteboard.general.clearContents()
            lastKnownCount = NSPasteboard.general.changeCount
            self.seen = nil
        case .wait(let delay):
            schedule(after: delay)
        case .forget:
            self.seen = nil
        }
    }
}

// MARK: Notifications

/// Clears or opens notifications through the Accessibility tree of macOS's Notification Center.
/// Best effort: it works on banners and alerts currently on screen (or with Notification Center
/// open), and depends on the action names macOS exposes, which can change between releases.
@MainActor
enum NotificationsAX {
    private static let bundleID = "com.apple.notificationcenterui"

    private static func notificationElements() -> [AXElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let root = AXElement.application(app.processIdentifier, timeout: 0.5)
        var found: [AXElement] = []
        func walk(_ element: AXElement, depth: Int) {
            guard depth < 10, found.count < 60 else { return }
            if let subrole = element.subrole, subrole.hasPrefix("AXNotificationCenter") {
                found.append(element)
                return
            }
            for child in element.children { walk(child, depth: depth + 1) }
        }
        for window in root.elements(kAXWindowsAttribute) { walk(window, depth: 0) }
        return found
    }

    static func clearAll() {
        guard AXIsProcessTrusted() else {
            NeedsAccess.shared.present(.accessibility, for: "Notification shortcuts")
            return
        }
        var cleared = 0
        for element in notificationElements() {
            let actions = element.actionNames
            if let clear = actions.first(where: { $0.contains("Clear All") }) ?? actions.first(where: { $0.contains("Close") || $0.contains("Clear") }) {
                if element.perform(clear) { cleared += 1 }
            }
        }
        if cleared == 0 {
            HUD.shared.show("bell.slash", "No notifications to clear")
        } else {
            HUD.shared.show("bell.badge.slash", "Notifications cleared")
        }
    }

    static func openTop() {
        guard AXIsProcessTrusted() else {
            NeedsAccess.shared.present(.accessibility, for: "Notification shortcuts")
            return
        }
        guard let top = notificationElements().first else {
            HUD.shared.show("bell.slash", "No notification on screen")
            return
        }
        if !top.perform(kAXPressAction) {
            HUD.shared.error("Couldn’t open the notification")
        }
    }
}

// MARK: Mail and Notes links

enum MessageLink {
    /// message://%3C<id>%3E, the form Mail itself opens. The ID is percent-encoded, angle brackets
    /// stripped if the script returned them.
    static func url(forMessageID raw: String) -> String? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        guard !id.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@!$&'()*+,;=")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "message://%3C\(encoded)%3E"
    }
}

@MainActor
enum Links {
    static func copyMailLink() {
        guard AppleScript.isRunning("com.apple.mail") else {
            HUD.shared.show("envelope", "Mail isn’t open", detail: "Select a message in Mail first.")
            return
        }
        let result = AppleScript.run("""
        tell application "Mail"
            set picked to selection
            if picked is {} then return ""
            return message id of item 1 of picked
        end tell
        """)
        switch result {
        case .success(let id):
            guard let link = MessageLink.url(forMessageID: id) else {
                HUD.shared.show("envelope", "No message selected")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(link, forType: .string)
            if let url = URL(string: link) { pasteboard.setString(url.absoluteString, forType: .URL) }
            HUD.shared.show("link", "Message link copied")
        case .failure(.notPermitted):
            NeedsAccess.shared.present(.automationMail, for: "Mail links")
        case .failure(.failed(let message)):
            HUD.shared.error("No link copied", message)
        }
    }

    /// Notes has no scripting property for a note's link, so Toolchest presses Notes' own "Copy Link"
    /// menu command when Notes offers it for the selected note.
    static func copyNoteLink() {
        guard let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else {
            HUD.shared.show("note.text", "Notes isn’t open", detail: "Select a note in Notes first.")
            return
        }
        guard AXIsProcessTrusted() else {
            NeedsAccess.shared.present(.accessibility, for: "Note links")
            return
        }
        let app = AXElement.application(notes.processIdentifier, timeout: 0.5)
        guard let menuBar = app.element(kAXMenuBarAttribute) else {
            HUD.shared.error("Couldn’t read Notes’ menus")
            return
        }
        let before = NSPasteboard.general.changeCount
        guard let item = findMenuItem(in: menuBar, titled: "Copy Link", depth: 0), item.bool(kAXEnabledAttribute) ?? false,
              item.perform(kAXPressAction) else {
            HUD.shared.show("note.text", "Notes has no link for this note", detail: "Select a single note and try again.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSPasteboard.general.changeCount != before {
                HUD.shared.show("link", "Note link copied")
            } else {
                HUD.shared.show("note.text", "Notes didn’t copy a link")
            }
        }
    }

    private static func findMenuItem(in element: AXElement, titled title: String, depth: Int) -> AXElement? {
        guard depth < 5 else { return nil }
        for child in element.children {
            if child.role == kAXMenuItemRole, child.title == title { return child }
            if let found = findMenuItem(in: child, titled: title, depth: depth + 1) { return found }
        }
        return nil
    }
}
