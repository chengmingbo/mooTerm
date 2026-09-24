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
        TabButton(tab: tab, isActive: tab.id == store.activeTabID, canClose: store.tabs.count > 1,
                  onSelect: { store.setActive(tab.id) },
                  onClose: { store.requestCloseTab(tab.id) })
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
                Button("Close Tab", action: { store.requestCloseTab(tab.id) })
            }
        }
    }
}

/// One tab in the tab bar. Observes the tab so title, activity, and bell
/// indicators update live.
private struct TabButton: View {
    @ObservedObject var tab: TabSession
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        let dotColor: Color = {
            if tab.broadcast { return .accentColor }
            if let c = tab.accent.nsColor { return Color(nsColor: c) }
            return Color.gray.opacity(0.4)
        }()
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle().fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !isActive && tab.bellRang {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Bell rang in this tab")
                } else if !isActive && tab.hasUnseenOutput {
                    Circle().fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .help("New output in this tab")
                }
                if canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.gray.opacity(0.25) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct TabContentView: View {
    @ObservedObject var tab: TabSession

    var body: some View {
        SplitTreeView(node: tab.root, tab: tab)
    }
}

struct SplitTreeView: View {
    @ObservedObject var node: SplitNode
    @ObservedObject var tab: TabSession

    var body: some View {
        // When zoomed, only render the focused pane and ignore the rest of
        // the split tree. The original tree is preserved in tab.root, so
        // unzoom restores the full layout without any work.
        if let zoomID = tab.zoomedPaneID, let pane = tab.findPane(id: zoomID, in: node) {
            PaneView(pane: pane, tab: tab)
        } else if let pane = node.pane {
            PaneView(pane: pane, tab: tab)
        } else if let first = node.first, let second = node.second {
            SplitContainer(node: node, first: first, second: second, tab: tab)
        }
    }
}

/// Two children with a draggable divider between them. Convention:
/// "horizontal split" = the divider runs horizontally, panes are stacked;
/// "vertical split" = the divider runs vertically, panes are side by side.
private struct SplitContainer: View {
    @ObservedObject var node: SplitNode
    let first: SplitNode
    let second: SplitNode
    @ObservedObject var tab: TabSession
    @State private var dragStartRatio: CGFloat?

    private static let dividerThickness: CGFloat = 4
    private var stacked: Bool { node.direction == .horizontal }

    var body: some View {
        GeometryReader { geo in
            let total = (stacked ? geo.size.height : geo.size.width) - Self.dividerThickness
            let firstLength = max(0, total * node.ratio)
            if stacked {
                VStack(spacing: 0) {
                    SplitTreeView(node: first, tab: tab).frame(height: firstLength)
                    divider(total: total)
                    SplitTreeView(node: second, tab: tab).frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    SplitTreeView(node: first, tab: tab).frame(width: firstLength)
                    divider(total: total)
                    SplitTreeView(node: second, tab: tab).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: stacked ? nil : Self.dividerThickness,
                   height: stacked ? Self.dividerThickness : nil)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside {
                    (stacked ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        let start = dragStartRatio ?? node.ratio
                        dragStartRatio = start
                        let delta = (stacked ? value.translation.height : value.translation.width) / total
                        let range = SplitNode.ratioRange
                        node.ratio = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartRatio = nil }
            )
            .onTapGesture(count: 2) { node.ratio = 0.5 }
            .help("Drag to resize · double-click to equalize")
    }
}

extension TabSession {
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let dir = activePane?.cwd {
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