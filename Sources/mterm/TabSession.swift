import Foundation
import Combine

/// One window-tab. Owns a tree of `SplitNode`s and a broadcast flag.
@MainActor
final class TabSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var root: SplitNode {
        didSet { wirePanes() }
    }
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
    @Published private var _activePaneID: UUID?

    /// Called when the last pane's shell exits, so the store can close
    /// the tab.
    var onLastPaneExited: (() -> Void)?

    private var paneSubscriptions: [UUID: AnyCancellable] = [:]

    init(id: UUID = UUID(), cwd: String? = nil) {
        self.id = id
        self.root = SplitNode(pane: Pane(cwd: cwd))
        wirePanes()
    }

    var activePaneID: UUID? {
        get { _activePaneID ?? collectPanes(root).first?.id }
        set { _activePaneID = newValue }
    }

    var activePane: Pane? { activePaneID.flatMap { findPane(id: $0, in: root) } }
    var panes: [Pane] { collectPanes(root) }

    /// Split `paneID` (default: the active pane). The new pane starts in
    /// the same directory as the one being split, like iTerm2.
    func split(_ direction: SplitDirection, pane paneID: UUID? = nil) {
        guard let targetID = paneID ?? activePaneID,
              let target = findPane(id: targetID, in: root) else { return }
        let newPane = Pane(cwd: target.currentDirectory)
        newPane.shellID = target.shellID
        let replacement = SplitNode(
            direction: direction,
            first: SplitNode(pane: target),
            second: SplitNode(pane: newPane))
        zoomedPaneID = nil
        root = replaceNode(node: root, with: replacement) { $0.pane?.id == targetID }
        _activePaneID = newPane.id
    }

    /// Close `paneID` (default: the active pane) and end its shell. Returns
    /// false when it is the tab's only pane — the caller closes the tab.
    @discardableResult
    func closePane(_ paneID: UUID? = nil) -> Bool {
        guard let targetID = paneID ?? activePaneID,
              let parent = findParent(of: targetID, in: root),
              let survivor = parent.sibling(of: targetID) else { return false }
        findPane(id: targetID, in: root)?.terminate()
        if zoomedPaneID == targetID { zoomedPaneID = nil }
        root = replaceNode(node: root, with: survivor) { $0.id == parent.id }
        if activePaneID == targetID || findPane(id: activePaneID ?? UUID(), in: root) == nil {
            _activePaneID = collectPanes(survivor).first?.id
        }
        return true
    }

    func closeActivePane() { closePane() }

    func toggleBroadcast() { broadcast.toggle() }
    func setActive(paneID: UUID) {
        if _activePaneID != paneID { _activePaneID = paneID }
    }

    /// Move focus to the pane cycling `offset` places in reading order.
    func cyclePane(by offset: Int) {
        let all = panes
        guard all.count > 1, let current = all.firstIndex(where: { $0.id == activePaneID }) else { return }
        _activePaneID = all[(current + offset % all.count + all.count) % all.count].id
    }

    /// Move focus to the nearest pane in `direction`, using the layout's
    /// actual geometry (ratios included).
    func focusNeighbor(_ direction: PaneNavigation) {
        guard let id = activePaneID,
              let next = neighbor(of: id, direction) else { return }
        zoomedPaneID = nil
        _activePaneID = next
    }

    func neighbor(of paneID: UUID, _ direction: PaneNavigation) -> UUID? {
        let frames = paneFrames()
        guard let current = frames.first(where: { $0.id == paneID })?.frame else { return nil }
        let eps: CGFloat = 0.0001
        func overlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }
        let candidates = frames.compactMap { entry -> (id: UUID, distance: CGFloat, overlap: CGFloat)? in
            let f = entry.frame
            guard entry.id != paneID else { return nil }
            switch direction {
            case .left:
                guard f.maxX <= current.minX + eps else { return nil }
                return (entry.id, current.minX - f.maxX, overlap(f.minY...f.maxY, current.minY...current.maxY))
            case .right:
                guard f.minX >= current.maxX - eps else { return nil }
                return (entry.id, f.minX - current.maxX, overlap(f.minY...f.maxY, current.minY...current.maxY))
            case .up:
                guard f.maxY <= current.minY + eps else { return nil }
                return (entry.id, current.minY - f.maxY, overlap(f.minX...f.maxX, current.minX...current.maxX))
            case .down:
                guard f.minY >= current.maxY - eps else { return nil }
                return (entry.id, f.minY - current.maxY, overlap(f.minX...f.maxX, current.minX...current.maxX))
            }
        }
        return candidates
            .filter { $0.overlap > eps }
            .min { ($0.distance, -$0.overlap) < ($1.distance, -$1.overlap) }?
            .id
    }

    /// Each pane's frame in a unit square (origin top-left).
    func paneFrames() -> [(id: UUID, frame: CGRect)] {
        var result: [(UUID, CGRect)] = []
        func walk(_ node: SplitNode?, _ rect: CGRect) {
            guard let node else { return }
            if let pane = node.pane { result.append((pane.id, rect)); return }
            switch node.direction {
            case .horizontal: // stacked
                let h = rect.height * node.ratio
                walk(node.first, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h))
                walk(node.second, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
            case .vertical: // side by side
                let w = rect.width * node.ratio
                walk(node.first, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
                walk(node.second, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
            }
        }
        walk(root, CGRect(x: 0, y: 0, width: 1, height: 1))
        return result
    }

    /// Zoom into the active pane (Terminator semantics: hide other panes,
    /// also bump the font size by +2 until unzoom).
    func zoomActive(bumpFont: Bool) {
        guard let id = activePaneID else { return }
        _zoomBumpFont = bumpFont
        zoomedPaneID = id
    }

    /// Double-clicking a pane header: fill the tab with that pane, or
    /// restore the layout if it already does.
    func toggleMaximise(paneID: UUID) {
        if zoomedPaneID == paneID {
            unzoom()
        } else {
            _activePaneID = paneID
            zoomActive(bumpFont: false)
        }
    }

    /// Restore the original split tree view.
    func unzoom() {
        _zoomBumpFont = false
        zoomedPaneID = nil
    }

    /// True only while zoomed in with a +2 font bump. Set by `zoomActive`.
    var zoomBumpsFont: Bool { _zoomBumpFont }
    private var _zoomBumpFont: Bool = false

    /// Panes that receive `pane`'s keystrokes while broadcast is on: every
    /// pane in the same group, or every pane in the tab when ungrouped.
    func broadcastTargets(for pane: Pane) -> [Pane] {
        guard broadcast else { return [pane] }
        return collectPanes(root).filter { $0.shellID == pane.shellID || $0.id == pane.id }
    }

    /// Foreground programs that closing this tab would kill.
    var runningProcessNames: [String] { panes.compactMap(\.runningProcessName) }

    var hasUnseenOutput: Bool { panes.contains(where: \.hasUnseenOutput) }
    var bellRang: Bool { panes.contains(where: \.bellRang) }
    func clearIndicators() { panes.forEach { $0.clearIndicators() } }

    func terminate() { for p in collectPanes(root) { p.terminate() } }

    func collectPanes(_ node: SplitNode?) -> [Pane] {
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

    /// Hook every pane in the tree up to this tab: focus, exit, and
    /// forwarding pane changes (cwd, title, activity) so the tab bar
    /// refreshes.
    private func wirePanes() {
        let current = panes
        let ids = Set(current.map(\.id))
        paneSubscriptions = paneSubscriptions.filter { ids.contains($0.key) }
        for pane in current {
            let paneID = pane.id
            pane.onFocus = { [weak self] in self?.setActive(paneID: paneID) }
            pane.onExit = { [weak self] in self?.paneExited(paneID) }
            pane.onInput = { [weak self, weak pane] data in
                guard let self, let pane, self.broadcast else { return }
                for target in self.broadcastTargets(for: pane) where target.id != paneID {
                    target.host?.view.sendToProcess(data)
                }
            }
            if paneSubscriptions[paneID] == nil {
                paneSubscriptions[paneID] = pane.objectWillChange
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            }
        }
    }

    private func paneExited(_ paneID: UUID) {
        if !closePane(paneID) { onLastPaneExited?() }
    }
}
