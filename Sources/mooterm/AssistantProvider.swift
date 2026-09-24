import Foundation

/// A model service that can turn plain language into shell commands.
enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, deepseek, minimax

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "fish"
        case .minimax: return "waveform"
        }
    }

    /// How requests are made, shown in Settings.
    var backendDescription: String {
        switch self {
        case .claude: return "Uses your installed Claude Code CLI (`claude`), with tools disabled."
        case .codex: return "Uses your installed Codex CLI (`codex exec`) in a read-only sandbox. Codex may run read-only commands to look around, so it is slower."
        case .deepseek: return "Calls the DeepSeek API directly (OpenAI-compatible, JSON mode)."
        case .minimax: return "Calls the MiniMax API directly (OpenAI-compatible). MiniMax Code's app login can't be reused, so it needs an API key from the MiniMax platform."
        }
    }

    /// "" means the tool's own default (e.g. Codex's config.toml model).
    var defaultModel: String {
        switch self {
        case .claude: return "haiku"
        case .codex: return ""
        case .deepseek: return "deepseek-chat"
        case .minimax: return "MiniMax-M2.7-highspeed"
        }
    }

    var modelSuggestions: [String] {
        switch self {
        case .claude: return ["haiku", "sonnet", "opus"]
        case .codex: return []
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .minimax: return ["MiniMax-M2.7-highspeed", "MiniMax-M2.7", "MiniMax-M3"]
        }
    }

    var usesAPIKey: Bool { apiKeyVariable != nil }

    var apiKeyVariable: String? {
        switch self {
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .minimax: return "MINIMAX_API_KEY"
        case .claude, .codex: return nil
        }
    }

    /// Selectable API endpoints (first is the default).
    var baseURLChoices: [(url: String, label: String)] {
        switch self {
        case .deepseek: return [("https://api.deepseek.com", "api.deepseek.com")]
        case .minimax: return [("https://api.minimaxi.com/v1", "China — api.minimaxi.com"),
                               ("https://api.minimax.io/v1", "Global — api.minimax.io")]
        case .claude, .codex: return []
        }
    }

    func makeTranslator() -> CommandTranslator {
        switch self {
        case .claude: return ClaudeCLI()
        case .codex: return CodexCLI()
        case .deepseek, .minimax:
            return ChatCompletionsClient(providerName: title, keyVariable: apiKeyVariable ?? "")
        }
    }
}

/// API keys for HTTP providers. Keys typed in Settings live in a 0600 file
/// in Application Support (the Keychain would re-prompt after every ad-hoc
/// rebuild); otherwise the provider's variable from mooTerm's environment or
/// the user's login shell (e.g. `export DEEPSEEK_API_KEY=…` in ~/.zshrc).
enum APIKeyStore {
    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("mooTerm/credentials.json")
    }

    static func savedKey(for provider: AssistantProvider, file: URL = fileURL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String: String].self, from: data),
              let key = keys[provider.rawValue], !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String?, for provider: AssistantProvider, file: URL = fileURL) {
        var keys = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        keys[provider.rawValue] = trimmed.isEmpty ? nil : trimmed
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(keys).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            AppDelegate.log("[mooTerm] APIKeyStore.save failed: \(error)")
        }
    }

    /// Where the key will come from, for Settings. Doesn't spawn a shell.
    static func source(for provider: AssistantProvider) -> String? {
        if savedKey(for: provider) != nil { return "saved in mooTerm" }
        if let variable = provider.apiKeyVariable,
           ProcessInfo.processInfo.environment[variable]?.isEmpty == false {
            return "$\(variable) (mooTerm's environment)"
        }
        return nil
    }

    /// Full lookup, including the login shell. Blocking; call off the main thread.
    static func resolve(for provider: AssistantProvider) -> String? {
        if let saved = savedKey(for: provider) { return saved }
        guard let variable = provider.apiKeyVariable else { return nil }
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty { return value }
        return loginShellVariable(variable)
    }

    /// Prefix that tells the value apart from anything rc files print.
    static let marker = "MOOTERM_ENV_VALUE="

    static func parseMarkedValue(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var shellCache: [String: String] = [:]

    /// `printenv VAR` in an interactive login shell, cached per launch.
    static func loginShellVariable(_ name: String) -> String? {
        cacheLock.lock()
        if let cached = shellCache[name] { cacheLock.unlock(); return cached.isEmpty ? nil : cached }
        cacheLock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TerminalHostView.resolveLoginShell())
        process.arguments = ["-l", "-i", "-c", #"printf '\n%s%s\n' "$2" "$(printenv "$1")""#, "mooterm-env", name, marker]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var value = ""
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            value = parseMarkedValue(String(decoding: data, as: UTF8.self)) ?? ""
        }
        cacheLock.lock(); shellCache[name] = value; cacheLock.unlock()
        return value.isEmpty ? nil : value
    }
}
