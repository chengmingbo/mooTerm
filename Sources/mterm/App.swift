import SwiftUI
import AppKit

// SwiftPM-built executables don't synthesise an NSApplicationMain symbol, so
// macOS launches the .app bundle but never starts the AppKit run loop.
// Drive the loop explicitly with a manual @main entry point. The delegate
// must outlive `app.run()` (NSApp.delegate is weak), so it lives in a
// top-level static.
private var appDelegateStrongRef: AppDelegate?

@main
enum mtermMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        appDelegateStrongRef = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var sessionStore: SessionStore!
    var focus: FocusStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write("[mterm] applicationDidFinishLaunching\n".data(using: .utf8)!)
        sessionStore = SessionStore()
        focus = FocusStore()

        let contentView = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(focus)
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
        win.title = "mterm"
        win.setContentSize(NSSize(width: 900, height: 600))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write("[mterm] window ordered front: \(win.frame)\n".data(using: .utf8)!)
        self.window = win

        installMenu()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focus.focusedPaneID = self.sessionStore.activeTab?.activePaneID ?? self.sessionStore.activeTab?.root.pane?.id
        }
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        // App menu (replaces the default "Process" or app-named one)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About mterm", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit mterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

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

        // Edit (standard responder chain)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

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

        NSApp.mainMenu = mainMenu
    }

    @objc func newTabAction() { sessionStore.newTab() }
    @objc func closeTabAction() { sessionStore.closeActiveTab() }
    @objc func splitHAction() { sessionStore.activeTab?.split(.horizontal) }
    @objc func splitVAction() { sessionStore.activeTab?.split(.vertical) }
    @objc func closePaneAction() { sessionStore.activeTab?.closeActivePane() }
    @objc func broadcastAction() { sessionStore.activeTab?.toggleBroadcast() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}