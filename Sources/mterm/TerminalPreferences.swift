import Foundation
import Combine

/// Terminal behaviour preferences shown in the Settings window. Persisted
/// to UserDefaults; every open pane picks up changes immediately.
@MainActor
final class TerminalPreferences: ObservableObject {
    static let scrollbackKey = "mTerm.scrollbackLines"
    static let claudeModelKey = "mTerm.claudeModel"
    static let proxyModeKey = "mTerm.proxy.mode"
    static let customProxyKey = "mTerm.proxy.custom"
    static let proxyInPanesKey = "mTerm.proxy.inPanes"

    enum ProxyMode: String, CaseIterable, Identifiable {
        /// mTerm's launch environment, else the macOS system proxy.
        case automatic
        case custom
        case off
        var id: String { rawValue }
    }

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

    @Published var proxyMode: ProxyMode {
        didSet { defaults.set(proxyMode.rawValue, forKey: Self.proxyModeKey) }
    }
    @Published var customProxy: String {
        didSet { defaults.set(customProxy, forKey: Self.customProxyKey) }
    }
    /// Also export the proxy in new terminal panes (off: shells keep
    /// whatever their rc files set, e.g. a `set_proxy` function).
    @Published var proxyInPanes: Bool {
        didSet { defaults.set(proxyInPanes, forKey: Self.proxyInPanesKey) }
    }

    /// The proxy mTerm hands to child processes, re-resolved on each call
    /// so a system proxy switched on/off later is picked up.
    func effectiveProxy(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyConfiguration? {
        switch proxyMode {
        case .automatic: return ProxyConfiguration.automatic(environment: environment)
        case .custom: return ProxyConfiguration.custom(customProxy)
        case .off: return nil
        }
    }

    /// Variables for the Claude panel's `claude` process. With the proxy
    /// off, clear any inherited ones so "None" really means none.
    var claudeEnvironment: [String: String] {
        if proxyMode == .off {
            return Dictionary(uniqueKeysWithValues: ProxyConfiguration.variableNames.map { ($0, "") })
        }
        return effectiveProxy()?.environment ?? [:]
    }

    /// Variables for new terminal panes.
    var paneEnvironment: [String: String] {
        proxyInPanes ? (effectiveProxy()?.environment ?? [:]) : [:]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.scrollbackKey) as? Int
        self.scrollbackLines = Self.clampScrollback(stored ?? Self.defaultScrollback)
        self.claudeModel = defaults.string(forKey: Self.claudeModelKey) ?? Self.defaultClaudeModel
        self.proxyMode = defaults.string(forKey: Self.proxyModeKey).flatMap(ProxyMode.init(rawValue:)) ?? .automatic
        self.customProxy = defaults.string(forKey: Self.customProxyKey) ?? ""
        self.proxyInPanes = defaults.bool(forKey: Self.proxyInPanesKey)
    }

    static func clampScrollback(_ lines: Int) -> Int {
        min(max(lines, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }
}
