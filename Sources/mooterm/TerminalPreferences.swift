import Foundation
import Combine

/// Terminal behaviour preferences shown in the Settings window. Persisted
/// to UserDefaults; every open pane picks up changes immediately.
@MainActor
final class TerminalPreferences: ObservableObject {
    static let scrollbackKey = "mooTerm.scrollbackLines"
    static let claudeModelKey = "mooTerm.claudeModel"
    static let proxyModeKey = "mooTerm.proxy.mode"
    static let customProxyKey = "mooTerm.proxy.custom"
    static let proxyInPanesKey = "mooTerm.proxy.inPanes"

    enum ProxyMode: String, CaseIterable, Identifiable {
        /// mooTerm's launch environment, else the macOS system proxy.
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

    static let providerModelsKey = "mooTerm.provider.models"
    static let providerBaseURLsKey = "mooTerm.provider.baseURLs"

    /// Model per provider (raw value → model id; "" = the tool's default).
    @Published private var providerModels: [String: String] {
        didSet { defaults.set(providerModels, forKey: Self.providerModelsKey) }
    }
    /// API endpoint per HTTP provider.
    @Published private var providerBaseURLs: [String: String] {
        didSet { defaults.set(providerBaseURLs, forKey: Self.providerBaseURLsKey) }
    }

    func model(for provider: AssistantProvider) -> String {
        providerModels[provider.rawValue] ?? provider.defaultModel
    }

    func setModel(_ model: String, for provider: AssistantProvider) {
        providerModels[provider.rawValue] = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func baseURL(for provider: AssistantProvider) -> String? {
        providerBaseURLs[provider.rawValue] ?? provider.baseURLChoices.first?.url
    }

    func setBaseURL(_ url: String, for provider: AssistantProvider) {
        providerBaseURLs[provider.rawValue] = url
    }

    /// Proxy for HTTP providers (URLSession follows the system proxy itself).
    var apiProxy: APIProxy {
        switch proxyMode {
        case .automatic:
            // Explicit variables mooTerm was launched with win over the system proxy.
            if let env = ProxyConfiguration.fromEnvironment(ProcessInfo.processInfo.environment) { return .custom(env) }
            return .system
        case .custom: return ProxyConfiguration.custom(customProxy).map(APIProxy.custom) ?? .system
        case .off: return .none
        }
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

    /// The proxy mooTerm hands to child processes, re-resolved on each call
    /// so a system proxy switched on/off later is picked up.
    func effectiveProxy(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyConfiguration? {
        switch proxyMode {
        case .automatic: return ProxyConfiguration.automatic(environment: environment)
        case .custom: return ProxyConfiguration.custom(customProxy)
        case .off: return nil
        }
    }

    /// Variables for CLI assistants (`claude`, `codex`). With the proxy
    /// off, clear any inherited ones so "None" really means none.
    var cliEnvironment: [String: String] {
        if proxyMode == .off {
            return Dictionary(uniqueKeysWithValues: ProxyConfiguration.variableNames.map { ($0, "") })
        }
        return effectiveProxy()?.environment ?? [:]
    }

    /// Variables for new terminal panes.
    var paneEnvironment: [String: String] {
        proxyInPanes ? (effectiveProxy()?.environment ?? [:]) : [:]
    }

    /// Terminal scrollbar visibility (Settings → Appearance).
    @Published var scrollbarMode: MooTermTerminalView.ScrollbarMode {
        didSet { defaults.set(scrollbarMode.rawValue, forKey: MooTermTerminalView.scrollbarModeKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.scrollbackKey) as? Int
        self.scrollbackLines = Self.clampScrollback(stored ?? Self.defaultScrollback)
        var models = defaults.dictionary(forKey: Self.providerModelsKey) as? [String: String] ?? [:]
        // 0.2: the Claude panel's model used to be a single setting.
        if models[AssistantProvider.claude.rawValue] == nil, let legacy = defaults.string(forKey: Self.claudeModelKey) {
            models[AssistantProvider.claude.rawValue] = legacy
        }
        self.providerModels = models
        self.providerBaseURLs = defaults.dictionary(forKey: Self.providerBaseURLsKey) as? [String: String] ?? [:]
        self.proxyMode = defaults.string(forKey: Self.proxyModeKey).flatMap(ProxyMode.init(rawValue:)) ?? .automatic
        self.customProxy = defaults.string(forKey: Self.customProxyKey) ?? ""
        self.proxyInPanes = defaults.bool(forKey: Self.proxyInPanesKey)
        self.scrollbarMode = defaults.string(forKey: MooTermTerminalView.scrollbarModeKey)
            .flatMap(MooTermTerminalView.ScrollbarMode.init(rawValue:)) ?? .always
    }

    static func clampScrollback(_ lines: Int) -> Int {
        min(max(lines, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }
}
