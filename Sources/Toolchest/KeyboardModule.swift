import AppKit
import ApplicationServices

/// App hotkeys and the drop-down Finder and terminal.
@MainActor
final class KeyboardModule {
    var settings = KeyboardSettings()
    private let animator = WindowAnimator()

    static let warpID = "dev.warp.Warp-Stable"
    /// "Warp" when it is installed, else "Terminal": the name the UI shows for terminal actions.
    static var terminalName: String { terminalBundleID == warpID ? "Warp" : "Terminal" }
    static var terminalBundleID: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: warpID) != nil ? warpID : "com.apple.Terminal"
    }

    // MARK: App hotkeys

    /// Opens or focuses the app; if it is already in front, hides it.
    func toggleApp(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           app.isActive, !app.isHidden {
            app.hide()
            return
        }
        open(bundleID, then: nil)
    }

    private func open(_ bundleID: String, then: (@MainActor (NSRunningApplication) -> Void)?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            HUD.shared.error("App not found", bundleID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // LaunchServices activation works from a background app, unlike activate(), and it
        // reopens a window when the app has none, just like a Dock click.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let pid = app?.processIdentifier
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let message { HUD.shared.error("Couldn’t open the app", message); return }
                    if let pid, let running = NSRunningApplication(processIdentifier: pid) { then?(running) }
                }
            }
        }
    }

    // MARK: Drop-down windows

    func dropdown(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           app.isActive, !app.isHidden {
            app.hide()
            return
        }
        guard AXIsProcessTrusted() else {
            NeedsAccess.shared.present(.accessibility, for: "Drop-down windows")
            return
        }
        let screen = screenUnderMouse
        open(bundleID) { [weak self] app in
            // Wait for the app to put a window up after activation.
            self?.placeDropdown(app, screen: screen, attempt: 0)
        }
    }

    private func placeDropdown(_ app: NSRunningApplication, screen: NSScreen?, attempt: Int) {
        let element = AXElement.application(app.processIdentifier)
        let window = element.element(kAXFocusedWindowAttribute) ?? element.element(kAXMainWindowAttribute)
        guard let window, let screen else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.placeDropdown(app, screen: screen, attempt: attempt + 1)
                }
            }
            return
        }
        let visible = Geometry.axRect(fromCocoa: screen.visibleFrame, primaryHeight: Geometry.primaryHeight)
        let height = (visible.height * min(max(settings.dropdownHeight, 0.2), 1)).rounded()
        let target = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        if SystemConditions.shared.calmEffects {
            set(window, target)
            return
        }
        // Slide down from under the menu bar: grow from a sliver to full height, one step per
        // display refresh. Windows can't be placed above the menu bar, so the motion is a reveal.
        set(window, CGRect(x: target.minX, y: target.minY, width: target.width, height: 60))
        animator.growHeight(of: window, from: 60, to: height, width: target.width, on: screen)
    }

    private func set(_ window: AXElement, _ frame: CGRect) {
        window.setPosition(frame.origin)
        window.setSize(frame.size)
        window.setPosition(frame.origin)
    }
}

// MARK: Shortcut Inspector

/// Finds which running apps have a menu item bound to a key combination, by reading each app's
/// menu bar through Accessibility.
///
/// Limits: it sees only menu items. Shortcuts handled in code (games, editors' own keymaps, web
/// apps), items an app adds only while a menu is open, and global hotkeys registered by other
/// apps are invisible to it. Apps that don't answer within the timeout are skipped.
enum ShortcutInspector {
    struct Match: Identifiable, Sendable, Equatable {
        let id = UUID()
        let app: String
        let path: String
    }

    /// AX menu modifier mask: Command is implied unless bit 3 is set; 1 = Shift, 2 = Option, 4 = Control.
    static func axModifiers(for combo: KeyCombo) -> Int? {
        let flags = combo.flags
        var mask = 0
        if flags.contains(.shift) { mask |= 1 }
        if flags.contains(.option) { mask |= 2 }
        if flags.contains(.control) { mask |= 4 }
        if !flags.contains(.command) { mask |= 8 }
        return mask
    }

    static func matches(char: String?, virtualKey: Int?, modifiers: Int?, combo: KeyCombo, comboChar: String) -> Bool {
        guard let expected = axModifiers(for: combo), (modifiers ?? 0) == expected else { return false }
        if let char, !char.isEmpty {
            return char.uppercased() == comboChar.uppercased()
        }
        if let virtualKey { return virtualKey == Int(combo.keyCode) }
        return false
    }

    static func inspect(_ combo: KeyCombo) async -> [Match] {
        let comboChar = KeyCombo.keyName(combo.keyCode)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName ?? $0.bundleIdentifier ?? "App") }
        return await Task.detached(priority: .userInitiated) {
            var results: [Match] = []
            for (pid, name) in apps {
                let app = AXElement.application(pid, timeout: 0.3)
                guard let bar = app.element(kAXMenuBarAttribute) else { continue }
                for top in bar.children {
                    let topTitle = top.title ?? ""
                    if topTitle == "Apple" || topTitle.isEmpty { continue }
                    walk(top, path: [topTitle], depth: 0, app: name, combo: combo, comboChar: comboChar, into: &results)
                }
            }
            return results
        }.value
    }

    private static func walk(_ element: AXElement, path: [String], depth: Int, app: String, combo: KeyCombo,
                             comboChar: String, into results: inout [Match]) {
        guard depth < 4 else { return }
        for child in element.children {
            if child.role == kAXMenuRole {
                walk(child, path: path, depth: depth + 1, app: app, combo: combo, comboChar: comboChar, into: &results)
                continue
            }
            guard child.role == kAXMenuItemRole else { continue }
            let title = child.title ?? ""
            if matches(char: child.string(kAXMenuItemCmdCharAttribute), virtualKey: child.int(kAXMenuItemCmdVirtualKeyAttribute),
                       modifiers: child.int(kAXMenuItemCmdModifiersAttribute), combo: combo, comboChar: comboChar),
               !title.isEmpty {
                results.append(Match(app: app, path: (path + [title]).joined(separator: " › ")))
            }
            if !child.children.isEmpty {
                walk(child, path: path + [title], depth: depth + 1, app: app, combo: combo, comboChar: comboChar, into: &results)
            }
        }
    }
}
