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
                tabButton(tab)
            }
            Spacer(minLength: 4)
            Button { store.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain).padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .sheet(item: $renamingTab) { context in
            RenameTabSheet(tab: context.tab, original: context.original) { newName in
                if let newName, !newName.isEmpty {
                    context.tab.customTitle = newName
                } else {
                    context.tab.customTitle = nil
                }
                renamingTab = nil
            }
        }
    }

    @State private var renamingTab: RenameContext?

    private struct RenameContext: Identifiable {
        let id = UUID()
        let tab: TabSession
        let original: String
    }

    @ViewBuilder
    private func tabButton(_ tab: TabSession) -> some View {
        let dotColor: Color = {
            if tab.broadcast { return .accentColor }
            if let c = tab.accent.nsColor { return Color(nsColor: c) }
            return Color.gray.opacity(0.4)
        }()
        Button {
            store.setActive(tab.id)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor)
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
        .contextMenu {
            Button("Rename…") {
                renamingTab = RenameContext(tab: tab, original: tab.title)
            }
            Menu("Color") {
                ForEach(AccentColor.allCases, id: \.id) { color in
                    Button {
                        tab.accent = color
                    } label: {
                        if tab.accent == color {
                            Text(color.displayName + " ✓")
                        } else {
                            Text(color.displayName)
                        }
                    }
                }
            }
            Divider()
            Button("Reset to Default", action: { tab.customTitle = nil })
            if store.tabs.count > 1 {
                Divider()
                Button("Close Tab", action: { store.closeTab(tab.id) })
            }
        }
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
        // When zoomed, only render the focused pane and ignore the rest of
        // the split tree. The original tree is preserved in tab.root, so
        // unzoom restores the full layout without any work.
        if let zoomID = tab.zoomedPaneID {
            if let pane = findPane(id: zoomID, in: node) {
                PaneView(pane: pane, tab: tab)
            } else {
                splitContainer
            }
        } else if let pane = node.pane {
            PaneView(pane: pane, tab: tab)
        } else {
            splitContainer
        }
    }

    private func findPane(id: UUID, in node: SplitNode?) -> Pane? {
        guard let n = node else { return nil }
        if let p = n.pane { return p.id == id ? p : nil }
        if let p = findPane(id: id, in: n.first) { return p }
        return findPane(id: id, in: n.second)
    }

    @ViewBuilder
    private var splitContainer: some View {
        let isHorizontal = (node.direction == .horizontal)
        let dividerColor = Color.gray.opacity(0.3)
        Group {
            // Convention here: "horizontal split" = the divider runs
            // horizontally across the screen, so the two panes are stacked
            // vertically (VStack). "vertical split" = the divider runs
            // vertically, panes are side by side (HStack).
            if isHorizontal {
                VStack(spacing: 0) {
                    if let f = node.first { SplitTreeView(node: f, tab: tab).frame(maxHeight: .infinity) }
                    Rectangle().fill(dividerColor).frame(height: 4)
                    if let s = node.second { SplitTreeView(node: s, tab: tab).frame(maxHeight: .infinity) }
                }
            } else {
                HStack(spacing: 0) {
                    if let f = node.first { SplitTreeView(node: f, tab: tab).frame(maxWidth: .infinity) }
                    Rectangle().fill(dividerColor).frame(width: 4)
                    if let s = node.second { SplitTreeView(node: s, tab: tab).frame(maxWidth: .infinity) }
                }
            }
        }
    }
}

extension TabSession {
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let dir = root.pane?.cwd {
            return (dir as NSString).lastPathComponent
        }
        return "shell"
    }
}

/// Modal rename prompt. The `onCommit` closure receives `nil` for "Reset to
/// default" (clears the custom title), or the entered string otherwise.
struct RenameTabSheet: View {
    let tab: TabSession
    let original: String
    let onCommit: (String?) -> Void
    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Tab").font(.headline)
            Text("Leave blank or press Reset to revert to the directory name.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Tab name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit { commit() }
            HStack {
                Button("Reset to Default") {
                    onCommit(nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && original == tab.title)
            }
        }
        .padding(20)
        .onAppear { name = original }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == original {
            onCommit(trimmed.isEmpty ? nil : trimmed)
        } else {
            onCommit(trimmed)
        }
        dismiss()
    }
}