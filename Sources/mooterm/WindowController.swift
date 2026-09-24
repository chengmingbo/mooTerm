import AppKit
import Combine
import SwiftUI

/// App-wide stores every window shares (settings, themes, assistants…).
@MainActor
struct SharedStores {
    let schemeStore: ColorSchemeStore
    let fontSizeStore: FontSizeStore
    let layoutStore: LayoutStore
    let windowStore: WindowStore
    let preferences: TerminalPreferences
    let assistantHub: AssistantHub
    let customStore: CustomAssistantStore
}

/// Per-window UI state. The sidebar selection is remembered so new windows
/// open with the panel you used last, but each window can differ.
@MainActor
final class WindowState: ObservableObject {
    @Published var sidebarSelection: String {
        didSet { UserDefaults.standard.set(sidebarSelection, forKey: UserDefaults.sidebarSelectionKey) }
    }

    init(sidebarSelection: String? = nil) {
        self.sidebarSelection = sidebarSelection
            ?? UserDefaults.standard.string(forKey: UserDefaults.sidebarSelectionKey) ?? ""
    }

    var selectedItem: SidebarItem? {
        get { SidebarItem(rawValue: sidebarSelection) }
        set { sidebarSelection = newValue?.rawValue ?? "" }
    }
}

/// One mooTerm window: its own tabs, panes, and sidebar state.
@MainActor
final class MooTermWindowController: NSObject, NSWindowDelegate {
    let sessionStore: SessionStore
    let windowState: WindowState
    let window: NSWindow
    /// Called once the window has closed, so the app can forget it.
    var onClose: ((MooTermWindowController) -> Void)?

    private var firstResponderObservation: NSKeyValueObservation?
    private var storeObservation: AnyCancellable?
    private var tabObservation: AnyCancellable?
    private var observedTabID: UUID?

    init(sessionStore: SessionStore, shared: SharedStores, windowState: WindowState? = nil) {
        self.sessionStore = sessionStore
        let windowState = windowState ?? WindowState()
        self.windowState = windowState

        let contentView = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(windowState)
            .environmentObject(shared.schemeStore)
            .environmentObject(shared.fontSizeStore)
            .environmentObject(shared.layoutStore)
            .environmentObject(shared.windowStore)
            .environmentObject(shared.preferences)
            .environmentObject(shared.assistantHub)
            .environmentObject(shared.customStore)
            .frame(minWidth: 720, idealWidth: 900, maxWidth: .infinity,
                   minHeight: 480, idealHeight: 600, maxHeight: .infinity)
        let hosting = NSHostingController(rootView: contentView)
        // Only let SwiftUI impose the minimum size. By default the window
        // also tracks the content's ideal size (900×600), which snapped it
        // back whenever it was zoomed — so double-clicking the title bar
        // or tab bar did nothing.
        hosting.sizingOptions = [.minSize]

        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        // The controller owns the window; AppKit must not free it on close.
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.title = "mooTerm"
        window.setContentSize(NSSize(width: 900, height: 600))
        window.tabbingMode = .disallowed  // mooTerm has its own tabs
        super.init()
        window.delegate = self
        shared.windowStore.apply(to: window)

        // Clicking into a terminal makes its pane the active one, so menu
        // commands (split, close, find) target what the user is looking at.
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                (window.firstResponder as? MooTermTerminalView)?.onBecomeFirstResponder?()
            }
        }
        // Closing the last tab closes the window, as in Terminal and iTerm2.
        sessionStore.onBecameEmpty = { [weak self] in self?.window.close() }
        storeObservation = sessionStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTitle() }
        }
        refreshTitle()
    }

    func show(cascadingFrom previous: NSWindow?) {
        if let previous {
            let origin = previous.frame.origin
            window.setFrame(NSRect(origin: origin, size: previous.frame.size), display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: origin.x, y: previous.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Title follows the active tab, so the Window menu can tell windows apart.
    private func refreshTitle() {
        let tab = sessionStore.activeTab
        window.title = tab.map { "\($0.title) — mooTerm" } ?? "mooTerm"
        if tab?.id != observedTabID {
            observedTabID = tab?.id
            tabObservation = tab?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTitle() }
            }
        }
    }

    // MARK: NSWindowDelegate

    /// Red close button / ⇧⌘W: confirm if programs are still running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        CloseConfirmation.confirm(closing: "this window", running: sessionStore.runningProcessNames)
    }

    func windowWillClose(_ notification: Notification) {
        sessionStore.onBecameEmpty = nil
        sessionStore.tabs.forEach { $0.terminate() }
        firstResponderObservation = nil
        storeObservation = nil
        tabObservation = nil
        onClose?(self)
    }
}
