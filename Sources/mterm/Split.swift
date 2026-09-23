import Foundation

enum SplitDirection { case horizontal, vertical }

/// Class-based split node. (Indirect recursive enums with class payloads trigger
/// a Swift 6.1 IRGen crash, so we use a flat class hierarchy instead.)
class SplitNode: Identifiable {
    let id = UUID()
    var ratio: CGFloat
    var direction: SplitDirection
    var first: SplitNode?
    var second: SplitNode?
    var pane: Pane?

    init(pane: Pane) {
        self.pane = pane
        self.direction = .horizontal
        self.ratio = 0.5
        self.first = nil
        self.second = nil
    }

    init(direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat = 0.5) {
        self.direction = direction
        self.first = first
        self.second = second
        self.ratio = ratio
        self.pane = nil
    }

    var isSplit: Bool { first != nil && second != nil }
    func sibling(of paneID: UUID) -> SplitNode? {
        if first?.pane?.id == paneID { return second }
        if second?.pane?.id == paneID { return first }
        return nil
    }
}