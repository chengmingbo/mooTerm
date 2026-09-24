import CFNetwork
import Foundation

/// Proxy environment for child processes. Command-line tools (claude, curl,
/// git, npm…) ignore the macOS system proxy and only read `http_proxy`-style
/// variables, which a Dock-launched app doesn't have. mTerm bridges the two.
struct ProxyConfiguration: Equatable, Sendable {
    var http: String?
    var https: String?
    var all: String?
    var noProxy: String?

    var isEmpty: Bool { http == nil && https == nil && all == nil }

    static let variableNames = ["http_proxy", "https_proxy", "all_proxy", "no_proxy",
                                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]

    /// Short description for Settings, e.g. "http://127.0.0.1:7890".
    var summary: String {
        https ?? http ?? all ?? "none"
    }

    /// Both spellings, since tools disagree on case.
    var environment: [String: String] {
        var env: [String: String] = [:]
        func set(_ key: String, _ value: String?) {
            guard let value else { return }
            env[key] = value
            env[key.uppercased()] = value
        }
        set("http_proxy", http)
        set("https_proxy", https)
        set("all_proxy", all)
        set("no_proxy", noProxy)
        return env
    }

    /// A single proxy URL used for everything (Settings → Custom).
    static func custom(_ url: String) -> ProxyConfiguration? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return ProxyConfiguration(http: value, https: value, all: value,
                                  noProxy: "localhost,127.0.0.1,::1")
    }

    /// Proxy variables already present in an environment (e.g. mTerm was
    /// launched from a shell that exported them).
    static func fromEnvironment(_ env: [String: String]) -> ProxyConfiguration? {
        func value(_ key: String) -> String? {
            (env[key] ?? env[key.uppercased()]).flatMap { $0.isEmpty ? nil : $0 }
        }
        let config = ProxyConfiguration(http: value("http_proxy"), https: value("https_proxy"),
                                        all: value("all_proxy"), noProxy: value("no_proxy"))
        return config.isEmpty ? nil : config
    }

    /// Translate the macOS system proxy dictionary (System Settings →
    /// Network → Proxies, as set by Clash/Surge/etc.).
    static func fromSystemSettings(_ settings: [String: Any]) -> ProxyConfiguration? {
        func endpoint(_ enable: String, _ host: String, _ port: String, scheme: String) -> String? {
            guard (settings[enable] as? NSNumber)?.boolValue == true,
                  let h = settings[host] as? String, !h.isEmpty else { return nil }
            let p = (settings[port] as? NSNumber)?.intValue
            return "\(scheme)://\(h)" + (p.map { ":\($0)" } ?? "")
        }
        let http = endpoint("HTTPEnable", "HTTPProxy", "HTTPPort", scheme: "http")
        let https = endpoint("HTTPSEnable", "HTTPSProxy", "HTTPSPort", scheme: "http")
        let socks = endpoint("SOCKSEnable", "SOCKSProxy", "SOCKSPort", scheme: "socks5")
        var exceptions = (settings["ExceptionsList"] as? [String]) ?? []
        for local in ["localhost", "127.0.0.1", "::1"] where !exceptions.contains(local) {
            exceptions.append(local)
        }
        let config = ProxyConfiguration(
            http: http ?? https,
            https: https ?? http,
            all: https ?? http ?? socks,
            noProxy: exceptions.map { $0.replacingOccurrences(of: "*.", with: ".") }.joined(separator: ","))
        return config.isEmpty ? nil : config
    }

    static func system() -> ProxyConfiguration? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return fromSystemSettings(settings)
    }

    /// Automatic mode: mTerm's own environment first (explicit wins), then
    /// the macOS system proxy.
    static func automatic(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyConfiguration? {
        fromEnvironment(environment) ?? system()
    }
}
