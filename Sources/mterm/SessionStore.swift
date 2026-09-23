import Foundation
import Combine

/// Top-level session store: one window, many tabs. Tabs own a split tree of panes.
final class SessionStore: ObservableObject {
    @Published var tabs: [TabSession] = [TabSession()]
    @Published var activeTabID: UUID

    var activeTab: TabSession? {
        tabs.first(where: { $0.id == activeTabID })
    }

    init() {
        let first = TabSession()
        self.tabs = [first]
        self.activeTabID = first.id
    }

    func newTab() {
        let t = TabSession()
        tabs.append(t)
        activeTabID = t.id
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].terminate()
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let t = TabSession()
            tabs.append(t)
            activeTabID = t.id
        } else {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
        }
    }

    func closeActiveTab() {
        closeTab(activeTabID)
    }

    func setActive(_ id: UUID) { activeTabID = id }
}