import Foundation
import Combine

/// One window-tab. Owns a tree of `SplitNode`s and a broadcast flag.
final class TabSession: ObservableObject, Identifiable {
    var id = UUID()
    @Published var root: SplitNode
    @Published var broadcast: Bool = false
    /// User-supplied tab name. When nil, `title` falls back to the active
    /// pane's cwd last path component.
    @Published var customTitle: String?
    /// Per-tab accent colour (used for the tab-bar dot indicator).
    @Published var accent: AccentColor = .none
    /// True when the user zoomed into a single pane via ⌘⇧Z or ⌘⇧X.
    /// Stores the pane ID being zoomed so we can restore the layout on
    /// unzoom (currently we only render the single pane — the original
    /// tree is preserved in `root`, and we simply short-circuit at the
    /// SwiftUI level).
    @Published var zoomedPaneID: UUID?

    init() {
        self.root = SplitNode(pane: Pane())
    }

    var activePaneID: UUID? {
        get { _activePaneID ?? collectPanes(root).first?.id }
        set { _activePaneID = newValue }
    }
    private var _activePaneID: UUID?

    func split(_ direction: SplitDirection) {
        guard let activeID = activePaneID,
              let activePane = findPane(id: activeID, in: root) else { return }
        let newPane = Pane()
        newPane.shellID = activePane.shellID
        let replacement = SplitNode(
            direction: direction,
            first: SplitNode(pane: activePane),
            second: SplitNode(pane: newPane))
        root = replaceNode(node: root, with: replacement) { $0.pane?.id == activeID }
        _activePaneID = newPane.id
    }

    func closeActivePane() {
        guard let activeID = activePaneID,
              let parent = findParent(of: activeID, in: root) else { return }
        guard let survivor = parent.sibling(of: activeID) else { return }
        root = replaceNode(node: root, with: survivor) { $0.id == parent.id }
        _activePaneID = collectPanes(root).first?.id
    }

    func toggleBroadcast() { broadcast.toggle() }
    func setActive(paneID: UUID) { _activePaneID = paneID }

    /// Zoom into the active pane (Terminator semantics: hide other panes,
    /// also bump the font size by +2 until unzoom).
    func zoomActive(bumpFont: Bool) {
        guard let id = activePaneID else { return }
        zoomedPaneID = id
        _zoomBumpFont = bumpFont
    }

    /// Restore the original split tree view.
    func unzoom() {
        zoomedPaneID = nil
        _zoomBumpFont = false
    }

    /// True only while zoomed in with a +2 font bump. Set by `zoomActive`.
    var zoomBumpsFont: Bool { _zoomBumpFont }
    private var _zoomBumpFont: Bool = false

    func broadcastTargets(for pane: Pane) -> [Pane] {
        guard broadcast else { return [pane] }
        return collectPanes(root).filter { $0.shellID == pane.shellID || $0.id == pane.id }
    }

    func terminate() { for p in collectPanes(root) { p.terminate() } }

    nonisolated func collectPanes(_ node: SplitNode?) -> [Pane] {
        guard let n = node else { return [] }
        if let p = n.pane { return [p] }
        return collectPanes(n.first) + collectPanes(n.second)
    }

    func findPane(id: UUID, in node: SplitNode?) -> Pane? {
        guard let n = node else { return nil }
        if let p = n.pane { return p.id == id ? p : nil }
        if let p = findPane(id: id, in: n.first) { return p }
        return findPane(id: id, in: n.second)
    }

    func findParent(of paneID: UUID, in node: SplitNode?) -> SplitNode? {
        guard let n = node, n.isSplit else { return nil }
        if n.first?.pane?.id == paneID || n.second?.pane?.id == paneID { return n }
        if let x = findParent(of: paneID, in: n.first) { return x }
        if let x = findParent(of: paneID, in: n.second) { return x }
        return nil
    }

    func replaceNode(node: SplitNode, with replacement: SplitNode, match: (SplitNode) -> Bool) -> SplitNode {
        if match(node) { return replacement }
        if let f = node.first {
            node.first = replaceNode(node: f, with: replacement, match: match)
        }
        if let s = node.second {
            node.second = replaceNode(node: s, with: replacement, match: match)
        }
        return node
    }
}