// Toolchest's Finder Sync extension: adds the right-click extras to Finder.
//
// The extension is sandboxed, so it does as little as possible itself. Copy Path happens here
// (the pasteboard is available to the sandbox); every other action goes to the Toolchest app over
// the private channel in FinderIPC.swift, because the app can read and write the selected files,
// show panels and launch other apps. The app checks every request before acting on it.
import AppKit
import FinderSync

@objc(ToolchestFinderSync)
final class ToolchestFinderSync: FIFinderSync {
    private static let colors: [(name: String, label: Int)] = [
        ("None", 0), ("Red", 6), ("Orange", 7), ("Yellow", 5), ("Green", 2), ("Blue", 4), ("Purple", 3), ("Gray", 1),
    ]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "webp"]

    override init() {
        super.init()
        // Monitoring the whole file system is what makes the menu appear in every folder.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let controller = FIFinderSyncController.default()
        let items = menuKind == .contextualMenuForItems ? (controller.selectedItemURLs() ?? []) : []
        let menu = NSMenu(title: "")

        menu.addItem(item(items.count > 1 ? "Copy Paths" : "Copy Path", #selector(copyPath(_:)), symbol: "doc.on.clipboard"))
        let terminal = Self.isInstalled("dev.warp.Warp-Stable", path: "/Applications/Warp.app") ? "Warp" : "Terminal"
        menu.addItem(item("Open in \(terminal)", #selector(openTerminal(_:)), symbol: "terminal"))
        if Self.isInstalled("com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app") {
            menu.addItem(item("Open in VS Code", #selector(openVSCode(_:)), symbol: "chevron.left.forwardslash.chevron.right"))
        }
        menu.addItem(item("New File from Template…", #selector(newFromTemplate(_:)), symbol: "doc.badge.plus"))

        if !items.isEmpty {
            menu.addItem(item("Move To…", #selector(moveTo(_:)), symbol: "folder"))
            menu.addItem(item("Copy To…", #selector(copyTo(_:)), symbol: "plus.square.on.square"))

            let tagItem = NSMenuItem(title: "Color Tag", action: nil, keyEquivalent: "")
            Self.decorate(tagItem, symbol: "tag")
            let tags = NSMenu(title: "Color Tag")
            for color in Self.colors {
                let entry = item(color.name, #selector(colorTag(_:)), symbol: nil)
                entry.tag = color.label
                tags.addItem(entry)
            }
            tagItem.submenu = tags
            menu.addItem(tagItem)

            if items.contains(where: { !$0.hasDirectoryPath }) {
                menu.addItem(item("Name by Content…", #selector(nameByContent(_:)), symbol: "doc.text.magnifyingglass"))
                menu.addItem(item("Copy SHA-256", #selector(checksum(_:)), symbol: "number"))
            }
            if items.contains(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
                menu.addItem(item("Remove Photo Location", #selector(stripLocation(_:)), symbol: "location.slash"))
            }
        }
        return menu
    }

    /// Gives a menu item its symbol. macOS 27 hides menu item images unless an item asks for them.
    private static func decorate(_ entry: NSMenuItem, symbol: String) {
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }
    }

    /// The sandbox can hide Launch Services answers, so a plain look at /Applications backs them up.
    private static func isInstalled(_ bundleID: String, path: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil || FileManager.default.fileExists(atPath: path)
    }

    private func item(_ title: String, _ action: Selector, symbol: String?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        if let symbol { Self.decorate(entry, symbol: symbol) }
        return entry
    }

    /// The selected items, or the folder the menu was opened in.
    private var targets: [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty { return selected }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private var folder: URL? { FIFinderSyncController.default().targetedURL() }

    @objc private func copyPath(_ sender: NSMenuItem) {
        let paths = targets.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func openTerminal(_ sender: NSMenuItem) { send("terminal", folderTargets) }
    @objc private func openVSCode(_ sender: NSMenuItem) { send("vscode", targets) }
    @objc private func newFromTemplate(_ sender: NSMenuItem) { send("template", folderTargets) }
    @objc private func moveTo(_ sender: NSMenuItem) { send("move", targets) }
    @objc private func copyTo(_ sender: NSMenuItem) { send("copy", targets) }
    @objc private func colorTag(_ sender: NSMenuItem) { send("tag", targets, extra: sender.tag) }
    @objc private func checksum(_ sender: NSMenuItem) { send("sha256", targets) }
    @objc private func stripLocation(_ sender: NSMenuItem) { send("strip-location", targets) }
    @objc private func nameByContent(_ sender: NSMenuItem) { send("name-content", targets) }

    /// Folders among the selection, or the folder the menu was opened in.
    private var folderTargets: [URL] {
        let selectedFolders = (FIFinderSyncController.default().selectedItemURLs() ?? []).filter(\.hasDirectoryPath)
        if !selectedFolders.isEmpty { return selectedFolders }
        return folder.map { [$0] } ?? []
    }

    private func send(_ action: String, _ urls: [URL], extra label: Int? = nil) {
        guard !urls.isEmpty, let secret = ToolchestIPC.readSecret(FinderIPC.secretURL) else { openToolchest(); return }
        let message = FinderIPC.Message(secret: secret, action: action, paths: urls.prefix(500).map(\.path), label: label)
        guard let data = try? JSONEncoder().encode(message) else { return }
        if ToolchestIPC.send(data, to: FinderIPC.portName) == nil { openToolchest() }
    }

    /// Toolchest isn't running: start it, so the next click works.
    private func openToolchest() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "info.gabrimatic.toolchest") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
