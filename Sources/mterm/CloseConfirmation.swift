import AppKit

/// iTerm2-style guard: closing a pane, tab, or the app while a program is
/// running in the foreground asks first. Idle shells close silently.
@MainActor
enum CloseConfirmation {
    /// Returns true when it's OK to close. `what` is e.g. "this pane".
    static func confirm(closing what: String, running names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        let alert = NSAlert()
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        alert.messageText = "Close \(what)?"
        alert.informativeText = unique.count == 1
            ? "“\(unique[0])” is still running and will be terminated."
            : "These programs are still running and will be terminated: \(unique.joined(separator: ", "))."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension SessionStore {
    /// User-initiated pane close (menu, header button): confirms if busy,
    /// closes the tab when it's the last pane.
    func requestClosePane(_ paneID: UUID? = nil) {
        guard let tab = activeTab,
              let pane = (paneID ?? tab.activePaneID).flatMap({ tab.findPane(id: $0, in: tab.root) }) else { return }
        guard CloseConfirmation.confirm(closing: "this pane", running: pane.runningProcessName.map { [$0] } ?? []) else { return }
        if !tab.closePane(pane.id) { closeTab(tab.id) }
    }

    func requestCloseTab(_ id: UUID? = nil) {
        guard let tab = tabs.first(where: { $0.id == (id ?? activeTabID) }) else { return }
        guard CloseConfirmation.confirm(closing: "this tab", running: tab.runningProcessNames) else { return }
        closeTab(tab.id)
    }
}
