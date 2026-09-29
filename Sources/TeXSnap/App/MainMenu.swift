import AppKit

/// The menu bar shown while a TeXSnap window is open. Without an Edit menu, ⌘C/⌘V/⌘Z would not
/// reach text views.
@MainActor
enum MainMenu {
    private static weak var snipItem: NSMenuItem?

    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "TeXSnap")
        app.addItem(withTitle: "About TeXSnap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings), ",", target: delegate))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide TeXSnap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit TeXSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        let snip = item("Snip Screen Region", #selector(AppDelegate.snipScreenRegion), "", target: delegate)
        file.addItem(snip)
        snipItem = snip
        let clipboard = item("Convert Clipboard Image", #selector(AppDelegate.convertClipboard), "v", target: delegate)
        clipboard.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(clipboard)
        file.addItem(item("Open Image…", #selector(AppDelegate.openImage), "o", target: delegate))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let copyLatex = item("Copy Snip in Default Format", #selector(AppDelegate.copySelection), "c", target: delegate)
        copyLatex.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(copyLatex)

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(item("TeXSnap", #selector(AppDelegate.showMainWindow), "0", target: delegate))
        NSApp.windowsMenu = window

        return main
    }

    /// Shows the global shortcut next to File › Snip Screen Region.
    static func updateSnipShortcut(_ combo: HotKeyCombo) {
        guard let snipItem else { return }
        snipItem.keyEquivalent = combo.keyEquivalent ?? ""
        snipItem.keyEquivalentModifierMask = combo.keyEquivalent == nil ? [] : combo.modifierFlags
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let holder = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
