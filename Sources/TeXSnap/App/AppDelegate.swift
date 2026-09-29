import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let settings = Settings.shared
    private(set) lazy var store = SnipStore(settings: settings)

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private static let statusItemName = "TeXSnap"
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var capturing = false
    private var hotKeyRegistered = false
    private var subscriptions: Set<AnyCancellable> = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(delegate: self)
        setUpStatusItem()
        HotKeyManager.shared.onPress = { [weak self] in self?.snipScreenRegion() }
        registerHotKey()
        settings.$hotKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &subscriptions)
        ClaudeLocator.shared.prefetch(override: settings.claudePath)
        _ = LatexKit.shared
        _ = store
        if settings.showWindowAtLaunch { showMainWindow() }
    }

    /// Images opened with TeXSnap (Finder's Open With, or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let data = try? Data(contentsOf: url) { add(data) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
        ProcessRegistry.shared.terminateAll()
    }

    private func registerHotKey() {
        hotKeyRegistered = HotKeyManager.shared.register(settings.hotKey)
        MainMenu.updateSnipShortcut(settings.hotKey)
    }

    // MARK: Windows

    private var actions: AppActions {
        AppActions(snip: { [weak self] in self?.snipScreenRegion() },
                   paste: { [weak self] in self?.convertClipboard() },
                   open: { [weak self] in self?.openImage() },
                   settings: { [weak self] in self?.showSettings() },
                   addImageData: { [weak self] data in self?.add(data) })
    }

    @objc func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainView(store: store, settings: settings, actions: actions))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "TeXSnap"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.minSize = NSSize(width: 800, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TeXSnapMainWindow")
            mainWindow = window
        }
        bringToFront(mainWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings,
                                    clearHistory: { [weak self] in self?.store.clearAll() },
                                    pauseHotKey: { [weak self] paused in
                                        if paused { HotKeyManager.shared.unregister() } else { self?.registerHotKey() }
                                    })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "TeXSnap Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 560, height: 700))
            window.center()
            settingsWindow = window
        }
        bringToFront(settingsWindow)
    }

    private func bringToFront(_ window: NSWindow?) {
        guard let window else { return }
        // TeXSnap stays a menu bar app (LSUIElement): no Dock icon, even while a window is open.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    // MARK: Snipping

    @objc func snipScreenRegion() {
        guard !capturing else { return }
        guard ensureScreenRecordingPermission() else { return }
        capturing = true
        let wasVisible = mainWindow?.isVisible == true
        mainWindow?.orderOut(nil)
        Task { @MainActor in
            defer { capturing = false }
            if let data = await ScreenCapture.captureRegion() {
                add(data)
            } else if wasVisible {
                mainWindow?.orderFront(nil)
            }
        }
    }

    @objc func convertClipboard() {
        guard let data = SnipStore.imageData(from: .general) else {
            inform("There is no image on the clipboard.",
                   detail: "Press ⌃⇧⌘4 to copy a screenshot of part of the screen, or copy an image in any app.")
            return
        }
        add(data)
    }

    @objc func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to convert to LaTeX"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = try? Data(contentsOf: url) { add(data) }
        }
    }

    private func add(_ data: Data) {
        guard store.add(imageData: data) != nil else {
            inform("TeXSnap could not read that image.", detail: "Use a PNG, JPEG, HEIC, TIFF, GIF or PDF file.")
            return
        }
        showMainWindow()
    }

    /// Screen Recording permission is required to capture other apps' windows.
    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "askedForScreenRecording") {
            defaults.set(true, forKey: "askedForScreenRecording")
            // Shows the system prompt and adds TeXSnap to the list in System Settings.
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow TeXSnap to capture the screen"
        alert.informativeText = """
        To snip part of the screen, turn on TeXSnap in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen TeXSnap.

        Until then: press ⌃⇧⌘4 to copy a screenshot, then choose Convert Clipboard Image from the TeXSnap menu.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func inform(_ message: String, detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Edit menu fallbacks (when no text field handles them)

    /// ⌘V in the window pastes an image as a new snip.
    @objc func paste(_ sender: Any?) {
        if NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
            || SnipStore.imageData(from: .general) != nil {
            convertClipboard()
        } else {
            NSSound.beep()
        }
    }

    /// ⌘C copies the selected snip in its default format.
    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func copySelection() {
        guard let snip = store.snip(store.selection), snip.status == .done, let value = store.defaultFormatValue(snip) else {
            NSSound.beep()
            return
        }
        store.copy(value, snip: snip.id, format: settings.defaultFormat(for: snip.kind))
    }

    @objc func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let snip = store.snip(id),
              let value = store.defaultFormatValue(snip) else { return }
        store.copy(value, snip: id, format: settings.defaultFormat(for: snip.kind))
    }

    // MARK: Status item

    private func setUpStatusItem() {
        // New menu bar items go leftmost, which on a full menu bar of a Mac with a notch means hidden behind
        // it. Start near the clock instead (points from the right edge); a ⌘-drag by the user overwrites this.
        let positionKey = "NSStatusItem Preferred Position \(Self.statusItemName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(300.0, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.statusItemName
        let image = NSImage(systemSymbolName: "x.squareroot", accessibilityDescription: "TeXSnap")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "TeXSnap — right-click for the menu"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        statusItem = item
    }

    /// Left-click shows or hides the main window; right-click or Control-click opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let item = statusItem, let menu = statusMenu else { return }
            // Attaching the menu only for this click keeps left-clicks going to the action.
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if let window = mainWindow, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.close()
        } else {
            showMainWindow()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()
        let snip = menu.addItem(withTitle: "Snip Screen Region", action: #selector(snipScreenRegion), keyEquivalent: "")
        if let key = settings.hotKey.keyEquivalent {
            snip.keyEquivalent = key
            snip.keyEquivalentModifierMask = settings.hotKey.modifierFlags
        }
        if !hotKeyRegistered {
            let warning = menu.addItem(withTitle: "Shortcut \(settings.hotKey.display) is unavailable; change it in Settings",
                                       action: nil, keyEquivalent: "")
            warning.isEnabled = false
        }
        menu.addItem(withTitle: "Convert Clipboard Image", action: #selector(convertClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Open Image…", action: #selector(openImage), keyEquivalent: "")

        let recent = store.snips.filter { $0.status == .done && $0.kind != .none }.prefix(6)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = menu.addItem(withTitle: "Copy a Recent Snip", action: nil, keyEquivalent: "")
            header.isEnabled = false
            for snip in recent {
                let flat = snip.latex.split(whereSeparator: \.isNewline).joined(separator: " ")
                let title = flat.count > 52 ? String(flat.prefix(51)) + "…" : flat
                let item = menu.addItem(withTitle: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.representedObject = snip.id
                item.toolTip = snip.latex
                item.indentationLevel = 1
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show TeXSnap", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TeXSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }
}
