import Foundation
import Combine

enum SplitDirection { case horizontal, vertical }

/// Direction for keyboard pane navigation (⌘⌥ + arrow).
enum PaneNavigation { case left, right, up, down }

/// Class-based split node. (Indirect recursive enums with class payloads trigger
/// a Swift 6.1 IRGen crash, so we use a flat class hierarchy instead.)
/// Observable so dragging a divider re-lays out just this split.
@MainActor
final class SplitNode: ObservableObject, Identifiable {
    let id = UUID()
    /// Fraction of the split given to `first`.
    @Published var ratio: CGFloat
    var direction: SplitDirection
    var first: SplitNode?
    var second: SplitNode?
    var pane: Pane?

    static let ratioRange: ClosedRange<CGFloat> = 0.1...0.9

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
        self.ratio = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
        self.pane = nil
    }

    var isSplit: Bool { first != nil && second != nil }
    func sibling(of paneID: UUID) -> SplitNode? {
        if first?.pane?.id == paneID { return second }
        if second?.pane?.id == paneID { return first }
        return nil
    }
}
