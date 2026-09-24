import Foundation
import Combine

/// Top-level session store: one window, many tabs. Tabs own a split tree of panes.
@MainActor
final class SessionStore: ObservableObject {
    @Published var tabs: [TabSession] = [] {
        didSet { tabs.forEach(wire) }
    }
    @Published var activeTabID: UUID

    var activeTab: TabSession? {
        tabs.first(where: { $0.id == activeTabID })
    }

    /// Called when the last tab closes; the window closes itself. Without
    /// it (e.g. in tests) a fresh tab replaces the last one.
    var onBecameEmpty: (() -> Void)?

    init(cwd: String? = nil) {
        let first = TabSession(cwd: cwd)
        self.activeTabID = first.id
        self.tabs = [first]
        wire(first)
    }

    /// A store holding an existing tab (Move Tab to New Window).
    init(adopting tab: TabSession) {
        self.activeTabID = tab.id
        self.tabs = [tab]
        wire(tab)
    }

    /// Remove a tab without ending its shells, to move it to another window.
    func detachTab(_ id: UUID) -> TabSession? {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: idx)
        tab.clearIndicators()
        if activeTabID == id { setActive(tabs[min(idx, tabs.count - 1)].id) }
        return tab
    }

    /// Open a tab in the active pane's directory (iTerm2's "reuse previous
    /// session's directory").
    func newTab() {
        let t = TabSession(cwd: activeTab?.activePane?.currentDirectory)
        tabs.append(t)
        setActive(t.id)
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].terminate()
        tabs.remove(at: idx)
        if tabs.isEmpty, let onBecameEmpty {
            onBecameEmpty()
        } else if tabs.isEmpty {
            let t = TabSession()
            tabs.append(t)
            activeTabID = t.id
        } else if activeTabID == id {
            setActive(tabs[min(idx, tabs.count - 1)].id)
        }
    }

    func closeActiveTab() {
        closeTab(activeTabID)
    }

    /// Switch tabs, clearing activity/bell indicators on both the tab being
    /// left (so it only lights up for output that arrives afterwards) and
    /// the one being shown.
    func setActive(_ id: UUID) {
        activeTab?.clearIndicators()
        activeTabID = id
        activeTab?.clearIndicators()
    }

    /// ⌘1…⌘9: select tab by position; ⌘9 always selects the last tab.
    func selectTab(number: Int) {
        guard !tabs.isEmpty, number >= 1 else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        setActive(tabs[index].id)
    }

    func cycleTab(by offset: Int) {
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        setActive(tabs[(current + offset % tabs.count + tabs.count) % tabs.count].id)
    }

    /// Foreground programs that quitting would kill, across every tab.
    var runningProcessNames: [String] { tabs.flatMap(\.runningProcessNames) }

    private func wire(_ tab: TabSession) {
        tab.onLastPaneExited = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(tab.id)
        }
    }
}
