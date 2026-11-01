import AppKit

/// The standard menu bar Toolchest shows while one of its windows is open: App, Edit, Window and Help.
/// (Toolchest is a menu bar app otherwise, so this menu only appears while a window is up.)
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Toolchest")
        app.addItem(item("About Toolchest", #selector(AppDelegate.showAbout(_:)), target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide Toolchest", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Toolchest", #selector(NSApplication.terminate(_:)), key: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        // Edit menu: copy, paste and undo work in every text field.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        let redo = item("Redo", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        // Window menu: macOS fills in the open windows.
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // Help menu
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("Toolchest Help", #selector(AppDelegate.showHelp(_:)), key: "?", target: target))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target
        return entry
    }
}
