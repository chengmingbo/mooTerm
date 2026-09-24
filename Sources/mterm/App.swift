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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow?
    var sessionStore: SessionStore!
    var schemeStore: ColorSchemeStore!
    var fontSizeStore: FontSizeStore!
    var layoutStore: LayoutStore!
    var windowStore: WindowStore!
    var preferences: TerminalPreferences!
    var assistant: CommandAssistant!
    private var settingsWindow: NSWindow?
    weak var themeMenu: NSMenu?
    weak var layoutsMenu: NSMenu?
    weak var windowMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyAppIcon()
        // 0.2: the Claude panel's own visibility flag became the sidebar
        // selection when the activity bar arrived.
        if UserDefaults.standard.object(forKey: "mTerm.assistant.visible") != nil {
            if UserDefaults.standard.bool(forKey: "mTerm.assistant.visible") {
                UserDefaults.selectedSidebarItem = .claude
            }
            UserDefaults.standard.removeObject(forKey: "mTerm.assistant.visible")
        }
        sessionStore = SessionStore()
        schemeStore = ColorSchemeStore()
        fontSizeStore = FontSizeStore()
        layoutStore = LayoutStore()
        windowStore = WindowStore()
        preferences = TerminalPreferences()
        assistant = CommandAssistant()

        let contentView = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(schemeStore)
            .environmentObject(fontSizeStore)
            .environmentObject(layoutStore)
            .environmentObject(windowStore)
            .environmentObject(preferences)
            .environmentObject(assistant)
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

        // Clicking into a terminal makes its pane the active one, so menu
        // commands (split, close, find) target what the user is looking at.
        firstResponderObservation = win.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                (window.firstResponder as? MTermTerminalView)?.onBecomeFirstResponder?()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { NaturalTextEditing.handle(event) } ? nil : event
        }
    }

    private var firstResponderObservation: NSKeyValueObservation?
    private var keyMonitor: Any?

    /// Quitting kills every shell, so confirm when programs are running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CloseConfirmation.confirm(closing: "mTerm", running: sessionStore.runningProcessNames)
            ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionStore.tabs.forEach { $0.terminate() }
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        // App menu (replaces the default "Process" or app-named one)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = NSMenuItem(title: "About mTerm", action: #selector(aboutAction), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
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
        let clear = NSMenuItem(title: "Clear Buffer", action: #selector(clearBufferAction), keyEquivalent: "k")
        clear.target = self
        fileMenu.addItem(clear)
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
        // Find uses SwiftTerm's built-in find bar via the standard text
        // finder actions; nil target routes to the focused terminal.
        let finderItems: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", [.command], .showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
        ]
        for (title, key, mods, action) in finderItems {
            let item = NSMenuItem(title: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = action.rawValue
            editMenu.addItem(item)
        }

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
        // iTerm2 alias: ⌘D splits side by side.
        let splitVAlias = NSMenuItem(title: "Split Vertically", action: #selector(splitVAction), keyEquivalent: "d")
        splitVAlias.keyEquivalentModifierMask = [.command]
        splitVAlias.target = self
        splitVAlias.isHidden = true
        splitVAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(splitVAlias)
        viewMenu.addItem(NSMenuItem.separator())

        // Pane navigation (iTerm2): ⌘⌥ + arrows moves spatially, ⌘] / ⌘[ cycles.
        let arrows: [(String, Int, PaneNavigation)] = [
            ("Select Pane Left", NSLeftArrowFunctionKey, .left),
            ("Select Pane Right", NSRightArrowFunctionKey, .right),
            ("Select Pane Above", NSUpArrowFunctionKey, .up),
            ("Select Pane Below", NSDownArrowFunctionKey, .down),
        ]
        for (title, key, direction) in arrows {
            let item = NSMenuItem(title: title, action: #selector(selectPaneAction(_:)),
                                  keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = direction
            viewMenu.addItem(item)
        }
        let nextPane = NSMenuItem(title: "Next Pane", action: #selector(nextPaneAction), keyEquivalent: "]")
        nextPane.target = self
        viewMenu.addItem(nextPane)
        let prevPane = NSMenuItem(title: "Previous Pane", action: #selector(previousPaneAction), keyEquivalent: "[")
        prevPane.target = self
        viewMenu.addItem(prevPane)
        let claude = NSMenuItem(title: "Claude Panel", action: #selector(toggleAssistantAction), keyEquivalent: "a")
        claude.keyEquivalentModifierMask = [.command, .shift]
        claude.target = self
        viewMenu.addItem(claude)
        let dim = NSMenuItem(title: "Dim Inactive Panes", action: #selector(toggleDimAction(_:)), keyEquivalent: "")
        dim.target = self
        dim.state = Self.dimInactivePanes ? .on : .off
        viewMenu.addItem(dim)
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
        windowMenu.addItem(NSMenuItem.separator())
        let nextTab = NSMenuItem(title: "Show Next Tab", action: #selector(nextTabAction), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = self
        windowMenu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Show Previous Tab", action: #selector(previousTabAction), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = self
        windowMenu.addItem(prevTab)
        for number in 1...9 {
            let item = NSMenuItem(title: number == 9 ? "Select Last Tab" : "Select Tab \(number)",
                                  action: #selector(selectTabAction(_:)), keyEquivalent: "\(number)")
            item.target = self
            item.tag = number
            windowMenu.addItem(item)
        }
        self.windowMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc func newTabAction() { sessionStore.newTab() }
    @objc func closeTabAction() { sessionStore.requestCloseTab() }
    @objc func splitHAction() { sessionStore.activeTab?.split(.horizontal) }
    @objc func splitVAction() { sessionStore.activeTab?.split(.vertical) }
    @objc func closePaneAction() { sessionStore.requestClosePane() }
    @objc func clearBufferAction() { sessionStore.activeTab?.activePane?.host?.clearBuffer() }
    @objc func selectPaneAction(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? PaneNavigation else { return }
        sessionStore.activeTab?.focusNeighbor(direction)
    }
    @objc func nextPaneAction() { sessionStore.activeTab?.cyclePane(by: 1) }
    @objc func previousPaneAction() { sessionStore.activeTab?.cyclePane(by: -1) }
    @objc func nextTabAction() { sessionStore.cycleTab(by: 1) }
    @objc func previousTabAction() { sessionStore.cycleTab(by: -1) }
    @objc func selectTabAction(_ sender: NSMenuItem) { sessionStore.selectTab(number: sender.tag) }

    static var dimInactivePanes: Bool {
        UserDefaults.standard.object(forKey: UserDefaults.dimInactivePanesKey) as? Bool ?? true
    }
    @objc func toggleDimAction(_ sender: NSMenuItem) {
        let newValue = !Self.dimInactivePanes
        UserDefaults.standard.set(newValue, forKey: UserDefaults.dimInactivePanesKey)
        sender.state = newValue ? .on : .off
    }

    /// Checkmarks are computed when a menu opens, so they stay right when
    /// the same setting is changed from the Settings window.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectScheme(_:)):
            item.state = (item.representedObject as? String) == schemeStore.current.id ? .on : .off
        case #selector(toggleAssistantAction):
            item.state = UserDefaults.selectedSidebarItem == .claude ? .on : .off
        case #selector(toggleDimAction(_:)):
            item.state = Self.dimInactivePanes ? .on : .off
        default:
            break
        }
        return true
    }

    /// ⇧⌘A: open the Claude panel and focus it; if it's open and focused,
    /// close it and return to the terminal.
    @objc func toggleAssistantAction() {
        let visible = UserDefaults.selectedSidebarItem == .claude
        let terminalFocused = window?.firstResponder is MTermTerminalView
        if visible && terminalFocused {
            NotificationCenter.default.post(name: .mtermFocusAssistant, object: nil)
        } else {
            UserDefaults.selectedSidebarItem = visible ? nil : .claude
            if visible, let view = sessionStore.activeTab?.activePane?.host?.view {
                window?.makeFirstResponder(view)
            }
        }
    }

    @objc func showSettingsAction() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(preferences)
                .environmentObject(fontSizeStore)
                .environmentObject(schemeStore)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "mTerm Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func aboutAction() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? Self.version
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "mTerm",
            .applicationVersion: version,
            .version: info?["CFBundleVersion"] as? String ?? "dev",
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// Fallback shown by About when running outside the .app (`swift run`).
    /// Keep in sync with Packaging/mterm.app/Contents/Info.plist.
    static let version = "0.2.0"
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