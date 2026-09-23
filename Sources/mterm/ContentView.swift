import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let tab = store.activeTab {
                TabContentView(tab: tab)
                    .id(tab.id)
            } else {
                Text("No tab").foregroundStyle(.secondary)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                Button {
                    store.setActive(tab.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(tab.broadcast ? Color.accentColor : Color.gray.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(tab.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        if store.tabs.count > 1 {
                            Button {
                                store.closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.id == store.activeTabID ? Color.gray.opacity(0.25) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Button { store.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain).padding(.horizontal, 6)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

struct TabContentView: View {
    @ObservedObject var tab: TabSession

    var body: some View {
        SplitTreeView(node: tab.root, tab: tab)
    }
}

struct SplitTreeView: View {
    let node: SplitNode
    @ObservedObject var tab: TabSession

    var body: some View {
        if let pane = node.pane {
            PaneView(pane: pane, tab: tab)
        } else {
            splitContainer
        }
    }

    @ViewBuilder
    private var splitContainer: some View {
        let isHorizontal = (node.direction == .horizontal)
        let dividerColor = Color.gray.opacity(0.3)
        Group {
            if isHorizontal {
                HStack(spacing: 0) {
                    if let f = node.first { SplitTreeView(node: f, tab: tab).frame(maxWidth: .infinity) }
                    Rectangle().fill(dividerColor).frame(width: 4)
                    if let s = node.second { SplitTreeView(node: s, tab: tab).frame(maxWidth: .infinity) }
                }
            } else {
                VStack(spacing: 0) {
                    if let f = node.first { SplitTreeView(node: f, tab: tab).frame(maxHeight: .infinity) }
                    Rectangle().fill(dividerColor).frame(height: 4)
                    if let s = node.second { SplitTreeView(node: s, tab: tab).frame(maxHeight: .infinity) }
                }
            }
        }
    }
}

extension TabSession {
    var title: String {
        if let dir = root.pane?.cwd {
            return (dir as NSString).lastPathComponent
        }
        return "shell"
    }
}