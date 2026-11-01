import AppKit
import ApplicationServices
import FinderSync

/// Finder keyboard features (cut and paste, new file, paste as file, reopen closed windows) and
/// the actions behind the right-click extras.
@MainActor
final class FinderModule {
    var settings = FinderSettings()
    private var history = ClosedFolderHistory()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var windowPaths: [AXElement: String] = [:]
    private var refreshWork: DispatchWorkItem?
    private var automationDeniedShown = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var finder: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    let ipc = IPCServer(portName: FinderIPC.portName, secretURL: FinderIPC.secretURL)

    func apply(_ settings: FinderSettings) {
        self.settings = settings
        ipc.onRequest = { [weak self] data in
            guard let self, let message = try? JSONDecoder().decode(FinderIPC.Message.self, from: data),
                  self.handle(message) else { return IPCServer.rejection }
            return Data([FinderIPC.Reply.accepted.rawValue])
        }
        if settings.enabled && settings.rightClickExtras {
            // The extension's own switch can flip at any time, so handle(_:) checks it per request.
            ipc.start()
        } else {
            ipc.stop()
        }
        if settings.enabled && settings.reopenClosed && AXIsProcessTrusted() {
            observeFinder()
        } else {
            stopObserving()
        }
    }

    // MARK: Finder scripting

    /// The folder shown in the front Finder window; with `desktopFallback`, the Desktop when no
    /// window is open. nil when the front window isn't a folder (Recents, AirDrop, search).
    func frontFolder(desktopFallback: Bool, timeout: Int = 2) -> URL? {
        guard AppleScript.isRunning("com.apple.finder") else { return nil }
        let fallback = desktopFallback ? "return POSIX path of (desktop as alias)" : "return \"\""
        // A hung Finder must not hold Toolchest's main thread for the system's two-minute Apple Event timeout.
        let result = AppleScript.run("""
        with timeout of \(max(timeout, 1)) seconds
            tell application "Finder"
                if (count of Finder windows) is 0 then
                    \(fallback)
                end if
                try
                    return POSIX path of (target of front Finder window as alias)
                on error
                    return ""
                end try
            end tell
        end timeout
        """)
        switch result {
        case .success(let path) where !path.isEmpty:
            return URL(fileURLWithPath: path, isDirectory: true)
        case .failure(.notPermitted):
            // Once per launch: this runs on every Finder window switch while reopen tracking is on.
            if !automationDeniedShown {
                automationDeniedShown = true
                NeedsAccess.shared.present(.automationFinder, for: "Finder shortcuts")
            }
            return nil
        default:
            return nil
        }
    }

    private func select(_ url: URL, rename: Bool) {
        _ = AppleScript.run("tell application \"Finder\" to select (POSIX file \(AppleScript.quoted(url.path)) as alias)")
        guard rename, let pid = finder?.processIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Synth.postKey(36, flags: [], toPID: pid) // Return: Finder's rename
        }
    }

    // MARK: Keyboard features

    func cut(changeCountBefore: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let count = NSPasteboard.general.changeCount
            guard count != changeCountBefore, Pasteboard.kind() == .files else { return }
            EventTap.shared.setCutChangeCount(count)
            HUD.shared.show("scissors", "Cut", detail: "Press ⌘V in a folder to move here.")
        }
    }

    func pasteMoved() {
        EventTap.shared.setCutChangeCount(nil)
    }

    func newTextFile() {
        guard let folder = frontFolder(desktopFallback: true) else {
            HUD.shared.error("No folder here", "Open a folder window first.")
            return
        }
        guard let url = FileNaming.createNew("untitled.txt", in: folder, data: Data()) else {
            HUD.shared.error("Couldn’t create the file", "You may not have permission to write in \(folder.lastPathComponent).")
            return
        }
        select(url, rename: true)
    }

    func pasteAsFile() {
        guard let folder = frontFolder(desktopFallback: true) else {
            HUD.shared.error("No folder here", "Open a folder window first.")
            return
        }
        let pasteboard = NSPasteboard.general
        let stamp = FileNaming.timestamp()
        var written: URL?
        if let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            written = FileNaming.createNew("Pasted Image \(stamp).png", in: folder, data: png)
        } else if let text = pasteboard.string(forType: .string) {
            written = FileNaming.createNew("Pasted Text \(stamp).txt", in: folder, data: Data(text.utf8))
        }
        guard let written else {
            HUD.shared.error("Couldn’t paste as a file", "Nothing usable on the clipboard, or the folder is read-only.")
            return
        }
        select(written, rename: false)
        HUD.shared.show("doc.badge.plus", "Pasted as \(written.lastPathComponent)")
    }

    /// ⌘W in Finder: remember the folder, then let Finder close the window or tab. The key was held
    /// back by the tap, so it is always handed on, even when Finder doesn't answer within a second
    /// (the tracked folder of the focused window stands in then).
    func close() {
        defer {
            if let pid = finder?.processIdentifier { Synth.postKey(13, flags: .maskCommand, toPID: pid) }
        }
        if let path = frontFolder(desktopFallback: false, timeout: 1)?.path {
            history.push(path, now: now)
        } else if let pid = finder?.processIdentifier,
                  let window = AXElement.application(pid, timeout: 0.15).element(kAXFocusedWindowAttribute),
                  window.subrole == "AXStandardWindow", let path = windowPaths[window] {
            history.push(path, now: now)
        }
    }

    func reopen() {
        guard let path = history.pop(exists: { FileManager.default.fileExists(atPath: $0) }) else {
            HUD.shared.show("arrow.uturn.backward", "No closed Finder window to reopen")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: Watching window closes (the red button)

    func finderRelaunched() {
        stopObserving()
        apply(settings)
    }

    private func observeFinder() {
        guard let finder, observer == nil || observedPID != finder.processIdentifier else { return }
        stopObserving()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let module = Unmanaged<FinderModule>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            let wrapped = AXElement(element)
            MainActor.assumeIsolated { module.axNotification(name, element: wrapped) }
        }
        guard AXObserverCreate(finder.processIdentifier, callback, &created) == .success, let created else { return }
        observer = created
        observedPID = finder.processIdentifier
        let app = AXElement.application(finder.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, app.ref, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(created, app.ref, kAXTitleChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        scheduleRefresh()
    }

    private func stopObserving() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedPID = 0
        windowPaths.removeAll()
    }

    private func axNotification(_ name: String, element: AXElement) {
        if name == kAXUIElementDestroyedNotification as String {
            if let path = windowPaths.removeValue(forKey: element) { history.push(path, now: now) }
        } else {
            scheduleRefresh()
        }
    }

    /// Remembers which folder the focused Finder window shows, coalescing bursts of notifications.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFocusedWindow() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refreshFocusedWindow() {
        guard let observer, observedPID > 0 else { return }
        let app = AXElement.application(observedPID)
        guard let window = app.element(kAXFocusedWindowAttribute), window.subrole == "AXStandardWindow",
              let path = frontFolder(desktopFallback: false)?.path else { return }
        if windowPaths[window] == nil {
            AXObserverAddNotification(observer, window.ref, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        windowPaths[window] = path
        if windowPaths.count > 100 { windowPaths.removeAll() }
    }

    // MARK: Right-click extras

    static var extensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func manageExtension() { FIFinderSyncController.showExtensionManagementInterface() }

    /// Whether the extension's requests may be served at all: module on, right-click extras on,
    /// and the extension switched on in System Settings. Fails closed.
    var acceptsExtensionRequests: Bool {
        settings.enabled && settings.rightClickExtras && Self.extensionEnabled
    }

    /// Handles a request from the Finder extension that already carried the right secret.
    ///
    /// On top of the secret, requests are checked again here: the module, its right-click extras and
    /// the extension must all be on, Finder must be the frontmost app, the paths must exist, and
    /// every path must be in Finder's current selection or the folder it shows. Terminal and
    /// templates also require real folders (symlinks resolved). Every action is read-only,
    /// clipboard-only, sets a color tag, writes a new file without overwriting, or goes through a
    /// folder picker or a review the user confirms.
    /// Returns false when the request is refused.
    func handle(_ message: FinderIPC.Message) -> Bool {
        guard acceptsExtensionRequests,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              let request = FinderRequest(message) else { return false }
        // Finder answers through Apple Events, so check membership on the next turn and reply now.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let allowed = self.finderSelectionAndTargets(),
                  FinderRequest.allPathsAllowed(request.urls.map(\.path), allowed: allowed) else {
                HUD.shared.error("Request refused", "The items aren’t selected in Finder.")
                return
            }
            self.perform(request)
        }
        return true
    }

    private func perform(_ request: FinderRequest) {
        switch request.action {
        case .terminal: openIn(KeyboardModule.terminalBundleID, request.urls)
        case .vscode: openIn("com.microsoft.VSCode", request.urls)
        case .template: chooseTemplate(for: request.urls.first)
        case .move: transfer(request.urls, move: true)
        case .copy: transfer(request.urls, move: false)
        case .tag: tag(request.urls, label: request.label ?? 0)
        case .sha256: checksum(request.urls)
        case .stripLocation: stripLocation(request.urls)
        case .nameContent: NamingPanel.shared.start(request.urls)
        }
    }

    /// Paths of Finder's selection, its insertion location and the front window's folder.
    /// nil when Finder can't be asked (no Automation permission): the request is then refused.
    func finderSelectionAndTargets() -> Set<String>? {
        let result = AppleScript.run("""
        tell application "Finder"
            set out to {}
            repeat with anItem in (get selection)
                try
                    set end of out to POSIX path of (anItem as alias)
                end try
            end repeat
            try
                set end of out to POSIX path of (insertion location as alias)
            end try
            try
                set end of out to POSIX path of (target of front Finder window as alias)
            end try
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """)
        guard case .success(let text) = result else {
            if case .failure(.notPermitted) = result {
                NeedsAccess.shared.present(.automationFinder, for: "Right-click extras")
            }
            return nil
        }
        return Set(text.split(separator: "\n").map { FinderRequest.normalize(String($0)) })
    }

    private func openIn(_ bundleID: String, _ urls: [URL]) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            HUD.shared.error("App not installed", bundleID)
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static var templatesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolchest/Templates", isDirectory: true)
    }

    static let starterTemplates: [(String, String)] = [
        ("Text File.txt", ""),
        ("Markdown.md", "# Title\n\n"),
        ("Shell Script.sh", "#!/bin/zsh\nset -euo pipefail\n\n"),
        ("Python Script.py", "#!/usr/bin/env python3\n\n\ndef main() -> None:\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n"),
        ("Web Page.html", "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>Untitled</title>\n</head>\n<body>\n</body>\n</html>\n"),
        ("Data.json", "{}\n"),
    ]

    /// Creates the templates folder with a few starters the first time it's needed.
    static func ensureTemplates() -> [URL] {
        let folder = templatesFolder
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, body) in starterTemplates {
                manager.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(body.utf8))
            }
        }
        let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var templateTarget: URL?

    private func chooseTemplate(for folder: URL?) {
        guard let folder else { return }
        templateTarget = folder
        let menu = NSMenu(title: "New File from Template")
        for template in Self.ensureTemplates() {
            let item = NSMenuItem(title: template.lastPathComponent, action: #selector(TemplateTarget.pick(_:)), keyEquivalent: "")
            item.representedObject = template
            item.target = TemplateTarget.shared
            item.image = NSWorkspace.shared.icon(forFile: template.path)
            item.image?.size = CGSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Templates Folder", action: #selector(TemplateTarget.openFolder(_:)), keyEquivalent: "")
        open.target = TemplateTarget.shared
        menu.addItem(open)
        TemplateTarget.shared.onPick = { [weak self] template in self?.create(from: template) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func create(from template: URL) {
        guard let folder = templateTarget else { return }
        let destination = FileNaming.unique(template.lastPathComponent, in: folder)
        do {
            try FileManager.default.copyItem(at: template, to: destination)
            select(destination, rename: true)
        } catch {
            HUD.shared.error("Couldn’t create the file", error.localizedDescription)
        }
    }

    private func transfer(_ urls: [URL], move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = move ? "Move \(Self.describe(urls)) to:" : "Copy \(Self.describe(urls)) to:"
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var failures: [String] = []
        var done = 0
        for url in urls {
            let target = FileNaming.unique(url.lastPathComponent, in: destination)
            do {
                if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
                done += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if failures.isEmpty {
            HUD.shared.show(move ? "folder.fill" : "plus.square.on.square", "\(move ? "Moved" : "Copied") \(Self.describe(urls))",
                            detail: "to \(destination.lastPathComponent)")
        } else {
            HUD.shared.error("\(done) of \(urls.count) done", "Couldn’t \(move ? "move" : "copy"): " + failures.prefix(3).joined(separator: ", "))
        }
    }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    private func tag(_ urls: [URL], label: Int) {
        guard (0...7).contains(label) else { return }
        var failed = 0
        for var url in urls {
            var values = URLResourceValues()
            values.labelNumber = label
            do { try url.setResourceValues(values) } catch { failed += 1 }
        }
        if failed > 0 { HUD.shared.error("Couldn’t tag \(failed) item\(failed == 1 ? "" : "s")") }
    }

    private func checksum(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        HUD.shared.show("number", "Computing SHA-256…", duration: 30)
        Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            var failure: String?
            for file in files {
                do {
                    let hash = try FileNaming.sha256(of: file)
                    lines.append(files.count == 1 ? hash : "\(hash)  \(file.lastPathComponent)")
                } catch {
                    failure = error.localizedDescription
                }
            }
            let text = lines.joined(separator: "\n")
            await MainActor.run {
                if let failure, lines.isEmpty {
                    HUD.shared.error("Couldn’t read the file", failure)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                HUD.shared.show("number", "SHA-256 copied", detail: files.count == 1 ? String(text.prefix(16)) + "…" : "\(lines.count) files")
            }
        }
    }

    private func stripLocation(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            var written: [URL] = []
            var none = 0
            var problems: [String] = []
            for url in urls {
                switch FileNaming.stripLocation(url) {
                case .written(let output): written.append(output)
                case .noLocation: none += 1
                case .unsupported: problems.append("\(url.lastPathComponent) isn’t a supported image")
                case .failed(let message): problems.append(message)
                }
            }
            let summary = (written, none, problems)
            await MainActor.run {
                let (written, none, problems) = summary
                if let problem = problems.first {
                    HUD.shared.error("Location not removed", problem)
                } else if written.isEmpty {
                    HUD.shared.show("location.slash", none == 1 ? "This photo has no location" : "No location found")
                } else {
                    HUD.shared.show("location.slash.fill", written.count == 1 ? "Saved a copy without location" : "Saved \(written.count) copies without location",
                                    detail: written.count == 1 ? written[0].lastPathComponent : "The originals are unchanged.")
                    _ = AppleScript.run("tell application \"Finder\" to select (POSIX file \(AppleScript.quoted(written[0].path)) as alias)")
                }
            }
        }
    }
}

/// A parsed, validated request from the Finder extension.
struct FinderRequest: Equatable {
    enum Action: String { case terminal, vscode, template, move, copy, tag, sha256, stripLocation = "strip-location", nameContent = "name-content" }

    let action: Action
    let urls: [URL]
    let label: Int?

    /// Validates paths: absolute, no "..", existing (a dangling symlink counts as existing but is
    /// refused where a folder is needed). Folder-only actions resolve symlinks first and require a
    /// real directory.
    init?(_ message: FinderIPC.Message) {
        guard let action = Action(rawValue: message.action), !message.paths.isEmpty, message.paths.count <= 500 else { return nil }
        var urls: [URL] = []
        for path in message.paths {
            guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), FileNaming.lexists(path) else { return nil }
            let needsFolder = action == .terminal || action == .template
            if needsFolder {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard FileNaming.isRealDirectory(resolved.path) else { return nil }
                urls.append(URL(fileURLWithPath: resolved.path, isDirectory: true))
            } else {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                urls.append(URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue))
            }
        }
        if action == .tag, !(0...7).contains(message.label ?? -1) { return nil }
        self.action = action
        self.urls = urls
        self.label = message.label
    }

    /// One comparable form for a path: symlinks resolved, no trailing slash.
    static func normalize(_ path: String) -> String {
        var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// Every path must be one Finder reports as selected or shown.
    static func allPathsAllowed(_ paths: [String], allowed: Set<String>) -> Bool {
        !paths.isEmpty && paths.allSatisfy { allowed.contains(normalize($0)) }
    }
}

@MainActor
final class TemplateTarget: NSObject {
    static let shared = TemplateTarget()
    var onPick: ((URL) -> Void)?

    @objc func pick(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onPick?(url) }
    }

    @objc func openFolder(_ sender: NSMenuItem) {
        _ = FinderModule.ensureTemplates()
        NSWorkspace.shared.open(FinderModule.templatesFolder)
    }
}
