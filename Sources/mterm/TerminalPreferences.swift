import Foundation
import Combine

/// Terminal behaviour preferences shown in the Settings window. Persisted
/// to UserDefaults; every open pane picks up changes immediately.
@MainActor
final class TerminalPreferences: ObservableObject {
    static let scrollbackKey = "mTerm.scrollbackLines"
    static let claudeModelKey = "mTerm.claudeModel"

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

    /// Model alias passed to `claude --model` for the command panel.
    /// Haiku is fast and plenty for command translation; empty = CLI default.
    static let defaultClaudeModel = "haiku"
    static let claudeModelChoices: [(id: String, label: String)] = [
        ("haiku", "Haiku (fastest)"),
        ("sonnet", "Sonnet"),
        ("opus", "Opus"),
        ("", "Claude Code default"),
    ]

    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Self.claudeModelKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.scrollbackKey) as? Int
        self.scrollbackLines = Self.clampScrollback(stored ?? Self.defaultScrollback)
        self.claudeModel = defaults.string(forKey: Self.claudeModelKey) ?? Self.defaultClaudeModel
    }

    static func clampScrollback(_ lines: Int) -> Int {
        min(max(lines, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }
}
