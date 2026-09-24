import AppKit
import Foundation

/// Persisted terminal font size. Owns the single source of truth that
/// `TerminalHost` reads every `updateNSView` pass. Clamps to a sane range
/// so a stray menu spam can't make the terminal invisible.
final class FontSizeStore: ObservableObject {
    static let storageKey = "mooTerm.fontSize"

    static let minSize: CGFloat = 8
    static let maxSize: CGFloat = 32
    static let step: CGFloat = 1
    static let `default`: CGFloat = 13

    @Published private(set) var size: CGFloat
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.double(forKey: Self.storageKey)
        if raw == 0 {
            self.size = Self.default
        } else {
            self.size = CGFloat(raw).clamped(to: Self.minSize...Self.maxSize)
        }
    }

    func increase() { set(size + Self.step) }
    func decrease() { set(size - Self.step) }
    func reset() { set(Self.default) }

    private func set(_ new: CGFloat) {
        let clamped = new.clamped(to: Self.minSize...Self.maxSize)
        guard clamped != size else { return }
        size = clamped
        defaults.set(Double(clamped), forKey: Self.storageKey)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}