import SwiftUI
import AppKit

// SwiftPM-built executables don't synthesise an NSApplicationMain symbol, so
// macOS launches the .app bundle but never starts the AppKit run loop.
// Drive the loop explicitly with a manual @main entry point. The delegate
// must outlive `app.run()` (NSApp.delegate is weak), so it lives in a
// top-level static.
private var appDelegateStrongRef: AppDelegate?

@main
enum mTermMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        appDelegateStrongRef = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var sessionStore: SessionStore!
    var focus: FocusStore!
    var schemeStore: ColorSchemeStore!
    var fontSizeStore: FontSizeStore!
    var layoutStore: LayoutStore!
    var windowStore: WindowStore!
    weak var themeMenu: NSMenu?
    weak var layoutsMenu: NSMenu?
    weak var windowMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyAppIcon()
        sessionStore = SessionStore()
        focus = FocusStore()
        schemeStore = ColorSchemeStore()
        fontSizeStore = FontSizeStore()
        layoutStore = LayoutStore()
        windowStore = WindowStore()

        let contentView = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(focus)
            .environmentObject(schemeStore)
            .environmentObject(fontSizeStore)
            .environmentObject(layoutStore)
            .environmentObject(windowStore)
            .frame(minWidth: 720, idealWidth: 900, maxWidth: .infinity,
                   minHeight: 480, idealHeight: 600, maxHeight: .infinity)

        let hosting = NSHostingController(rootView: contentView)
        hosting.preferredContentSize = NSSize(width: 900, height: 600)
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "mTerm"
        win.setContentSize(NSSize(width: 900, height: 600))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        // Apply persisted window-level preferences before the user sees the
        // window, so borders/always-on-top reflect the saved state.
        windowStore.apply(to: win)

        installMenu()

        NotificationCenter.default.addObserver(self,
            selector: #selector(handleNewTab),
            name: .mtermNewTab, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleCloseTab),
            name: .mtermCloseTab, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleFindInPane(_:)),
            name: .mtermFindInPane, object: nil)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focus.focusedPaneID = self.sessionStore.activeTab?.activePaneID ?? self.sessionStore.activeTab?.root.pane?.id
        }
    }

    @objc func handleNewTab() { sessionStore.newTab() }
    @objc func handleCloseTab() { sessionStore.closeActiveTab() }

    @objc func handleFindInPane(_ note: Notification) {
        guard let info = note.userInfo,
              let paneID = info["paneID"] as? UUID else { return }
        let term = (info["term"] as? String) ?? ""
        focus.findRequest = FindRequest(paneID: paneID, term: term)
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        // App menu (replaces the default "Process" or app-named one)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About mTerm", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit mTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTabAction), keyEquivalent: "t")
        newTab.target = self
        fileMenu.addItem(newTab)
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(closeTabAction), keyEquivalent: "w")
        closeTab.target = self
        fileMenu.addItem(closeTab)
        fileMenu.addItem(NSMenuItem.separator())
        let saveLayout = NSMenuItem(title: "Save Layout As…", action: #selector(saveLayoutAction), keyEquivalent: "s")
        saveLayout.keyEquivalentModifierMask = [.command, .shift]
        saveLayout.target = self
        fileMenu.addItem(saveLayout)

        // Edit (standard responder chain)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(findAction), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command, .shift]
        findItem.target = self
        editMenu.addItem(findItem)

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let splitH = NSMenuItem(title: "Split Horizontally", action: #selector(splitHAction), keyEquivalent: "d")
        splitH.keyEquivalentModifierMask = [.command, .shift]
        splitH.target = self
        viewMenu.addItem(splitH)
        let splitV = NSMenuItem(title: "Split Vertically", action: #selector(splitVAction), keyEquivalent: "e")
        splitV.keyEquivalentModifierMask = [.command, .shift]
        splitV.target = self
        viewMenu.addItem(splitV)
        viewMenu.addItem(NSMenuItem.separator())
        let closePane = NSMenuItem(title: "Close Pane", action: #selector(closePaneAction), keyEquivalent: "w")
        closePane.keyEquivalentModifierMask = [.command, .option]
        closePane.target = self
        viewMenu.addItem(closePane)
        let broadcast = NSMenuItem(title: "Toggle Broadcast Group", action: #selector(broadcastAction), keyEquivalent: "g")
        broadcast.keyEquivalentModifierMask = [.command, .shift]
        broadcast.target = self
        viewMenu.addItem(broadcast)
        viewMenu.addItem(NSMenuItem.separator())

        // Zoom & Maximise — Terminator semantics. Zoom bumps the font size
        // by +2pt while zoomed; Maximise keeps the font.
        let zoom = NSMenuItem(title: "Zoom Pane", action: #selector(zoomAction), keyEquivalent: "z")
        zoom.keyEquivalentModifierMask = [.command, .shift]
        zoom.target = self
        viewMenu.addItem(zoom)
        let maxItem = NSMenuItem(title: "Maximise Pane", action: #selector(maximiseAction), keyEquivalent: "x")
        maxItem.keyEquivalentModifierMask = [.command, .shift]
        maxItem.target = self
        viewMenu.addItem(maxItem)
        let unzoom = NSMenuItem(title: "Restore All Panes", action: #selector(unzoomAction), keyEquivalent: "")
        unzoom.target = self
        viewMenu.addItem(unzoom)
        viewMenu.addItem(NSMenuItem.separator())

        // Font size — ⌘= (the conventional ⌘+), ⌘- to shrink, ⌘0 to reset.
        let bigger = NSMenuItem(title: "Bigger Font", action: #selector(biggerFontAction), keyEquivalent: "=")
        bigger.keyEquivalentModifierMask = [.command]
        bigger.target = self
        viewMenu.addItem(bigger)
        let biggerAlias = NSMenuItem(title: "Bigger Font", action: #selector(biggerFontAction), keyEquivalent: "+")
        biggerAlias.keyEquivalentModifierMask = [.command]
        biggerAlias.target = self
        biggerAlias.isHidden = true
        biggerAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(biggerAlias)
        let smaller = NSMenuItem(title: "Smaller Font", action: #selector(smallerFontAction), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.command]
        smaller.target = self
        viewMenu.addItem(smaller)
        let resetFont = NSMenuItem(title: "Reset Font Size", action: #selector(resetFontAction), keyEquivalent: "0")
        resetFont.keyEquivalentModifierMask = [.command]
        resetFont.target = self
        viewMenu.addItem(resetFont)

        // Layouts menu — dynamic contents; rebuilt when the store changes.
        let layoutsItem = NSMenuItem()
        mainMenu.addItem(layoutsItem)
        let layoutsMenu = NSMenu(title: "Layouts")
        layoutsItem.submenu = layoutsMenu
        self.layoutsMenu = layoutsMenu
        rebuildLayoutsMenu()

        // Theme — one entry per ColorScheme.
        let themeItem = NSMenuItem()
        mainMenu.addItem(themeItem)
        let themeMenu = NSMenu(title: "Theme")
        themeItem.submenu = themeMenu
        for scheme in ColorScheme.all {
            let item = NSMenuItem(
                title: scheme.displayName,
                action: #selector(selectScheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = scheme.id
            item.state = (scheme.id == schemeStore.current.id) ? .on : .off
            themeMenu.addItem(item)
        }
        self.themeMenu = themeMenu

        // Window — toggle window chrome.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        let borders = NSMenuItem(title: "Show Window Borders",
                                action: #selector(toggleBordersAction),
                                keyEquivalent: "b")
        borders.keyEquivalentModifierMask = [.command, .option]
        borders.target = self
        borders.state = windowStore.borders ? .on : .off
        windowMenu.addItem(borders)
        let aot = NSMenuItem(title: "Always on Top",
                             action: #selector(toggleAlwaysOnTopAction),
                             keyEquivalent: "t")
        aot.keyEquivalentModifierMask = [.command, .option]
        aot.target = self
        aot.state = windowStore.alwaysOnTop ? .on : .off
        windowMenu.addItem(aot)
        self.windowMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc func newTabAction() { sessionStore.newTab() }
    @objc func closeTabAction() { sessionStore.closeActiveTab() }
    @objc func splitHAction() { sessionStore.activeTab?.split(.horizontal) }
    @objc func splitVAction() { sessionStore.activeTab?.split(.vertical) }
    @objc func closePaneAction() { sessionStore.activeTab?.closeActivePane() }
    @objc func broadcastAction() { sessionStore.activeTab?.toggleBroadcast() }

    @objc func zoomAction() {
        if let tab = sessionStore.activeTab, tab.zoomedPaneID != nil {
            tab.unzoom()
        } else {
            sessionStore.activeTab?.zoomActive(bumpFont: true)
        }
    }
    @objc func maximiseAction() {
        if let tab = sessionStore.activeTab, tab.zoomedPaneID != nil {
            tab.unzoom()
        } else {
            sessionStore.activeTab?.zoomActive(bumpFont: false)
        }
    }
    @objc func unzoomAction() { sessionStore.activeTab?.unzoom() }

    @objc func findAction() {
        guard let paneID = sessionStore.activeTab?.activePaneID else { return }
        focus.findRequest = FindRequest(paneID: paneID, term: "")
    }

    @objc func selectScheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let scheme = ColorScheme.all.first(where: { $0.id == id }) else { return }
        schemeStore.select(scheme)
        refreshThemeMenuCheckmarks()
    }

    @objc func biggerFontAction() {
        fontSizeStore.increase()
    }
    @objc func smallerFontAction() {
        fontSizeStore.decrease()
    }
    @objc func resetFontAction() {
        fontSizeStore.reset()
    }

    @objc func toggleBordersAction() {
        windowStore.borders.toggle()
        if let window { windowStore.apply(to: window) }
        refreshWindowMenuCheckmarks()
    }
    @objc func toggleAlwaysOnTopAction() {
        windowStore.alwaysOnTop.toggle()
        if let window { windowStore.apply(to: window) }
        refreshWindowMenuCheckmarks()
    }

    // MARK: - Layouts

    @objc func saveLayoutAction() {
        promptForLayoutName { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            let layout = LayoutStore.snapshot(of: self.sessionStore, name: name)
            self.layoutStore.save(layout)
            self.rebuildLayoutsMenu()
        }
    }

    @objc func restoreLayoutAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = layoutStore.layouts.first(where: { $0.id == id }) else { return }
        layoutStore.restore(layout, into: sessionStore)
    }

    @objc func deleteLayoutAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        layoutStore.delete(id: id)
        rebuildLayoutsMenu()
    }

    @objc func renameLayoutAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = layoutStore.layouts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Layout"
        alert.informativeText = "Choose a new name for \(layout.name)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = layout.name
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                layoutStore.rename(id: id, to: trimmed)
                rebuildLayoutsMenu()
            }
        }
    }

    private func rebuildLayoutsMenu() {
        guard let layoutsMenu else { return }
        layoutsMenu.removeAllItems()
        if layoutStore.layouts.isEmpty {
            let placeholder = NSMenuItem(title: "No Saved Layouts", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            layoutsMenu.addItem(placeholder)
        } else {
            for layout in layoutStore.layouts.sorted(by: { $0.createdAt < $1.createdAt }) {
                let item = NSMenuItem(title: layout.name,
                                       action: #selector(restoreLayoutAction(_:)),
                                       keyEquivalent: "")
                item.target = self
                item.representedObject = layout.id
                layoutsMenu.addItem(item)
                let del = NSMenuItem(title: "Delete \(layout.name)",
                                     action: #selector(deleteLayoutAction(_:)),
                                     keyEquivalent: "")
                del.target = self
                del.representedObject = layout.id
                layoutsMenu.addItem(del)
            }
        }
    }

    private func promptForLayoutName(completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Give this layout a name. Tabs, panes, custom titles, accents, and broadcast settings are captured."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Layout name"
        alert.accessoryView = input
        let result = alert.runModal()
        completion(result == .alertFirstButtonReturn ? input.stringValue : nil)
    }

    private func refreshThemeMenuCheckmarks() {
        guard let themeMenu else { return }
        for item in themeMenu.items {
            let active = (item.representedObject as? String) == schemeStore.current.id
            item.state = active ? .on : .off
        }
    }

    private func refreshWindowMenuCheckmarks() {
        guard let windowMenu else { return }
        for item in windowMenu.items {
            switch item.action {
            case #selector(toggleBordersAction):
                item.state = windowStore.borders ? .on : .off
            case #selector(toggleAlwaysOnTopAction):
                item.state = windowStore.alwaysOnTop ? .on : .off
            default: break
            }
        }
    }

    /// Append a line to ~/Library/Logs/mTerm.log. Used for ad-hoc debugging; the
    /// menu / theme / font subsystems no longer call it during normal flow.
    static let logURL: URL = {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Logs/mTerm.log")
    }()

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// Inside the packaged .app, macOS reads the icon from CFBundleIconFile.
    /// `swift run` has no bundle, so without this the Dock shows a generic
    /// executable icon. Look the icon up manually rather than via
    /// `Bundle.module`, whose generated accessor traps when the SwiftPM
    /// resource bundle is not where it expects (e.g. inside the .app).
    private static func applyAppIcon() {
        guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil else { return }
        let resourceBundle = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("mterm_mterm.bundle")
        guard let bundle = resourceBundle.flatMap(Bundle.init(url:)),
              let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}