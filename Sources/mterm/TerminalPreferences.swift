import Foundation
import Combine

/// Terminal behaviour preferences shown in the Settings window. Persisted
/// to UserDefaults; every open pane picks up changes immediately.
@MainActor
final class TerminalPreferences: ObservableObject {
    static let scrollbackKey = "mTerm.scrollbackLines"

    /// Lines of history kept above the screen, per pane. 0 disables
    /// scrollback. SwiftTerm stores history in a buffer sized to this limit,
    /// so there's a ceiling rather than an "unlimited" option.
    static let defaultScrollback = 10_000
    static let scrollbackRange = 0...1_000_000
    static let scrollbackPresets = [1_000, 5_000, 10_000, 50_000, 100_000]

    @Published var scrollbackLines: Int {
        didSet {
            let clamped = Self.clampScrollback(scrollbackLines)
            if clamped != scrollbackLines { scrollbackLines = clamped; return }
            defaults.set(clamped, forKey: Self.scrollbackKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.scrollbackKey) as? Int
        self.scrollbackLines = Self.clampScrollback(stored ?? Self.defaultScrollback)
    }

    static func clampScrollback(_ lines: Int) -> Int {
        min(max(lines, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }
}
