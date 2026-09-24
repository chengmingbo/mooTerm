import Combine
import Foundation
import SwiftUI

/// A user-defined assistant: either any OpenAI-compatible chat API (Kimi,
/// Qwen/DashScope, OpenRouter, Ollama, …) or any command-line tool that
/// reads a prompt and prints an answer (qwen, kimi, gemini, opencode, …).
struct CustomAssistant: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openAICompatible
        case command
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// OpenAI-compatible: e.g. https://api.moonshot.cn/v1
    var baseURL: String = ""
    var model: String = ""
    /// Environment variable to read the key from when none is saved in
    /// mooTerm (e.g. MOONSHOT_API_KEY). Empty with no saved key = no auth
    /// header, for local servers like Ollama.
    var apiKeyVariable: String = ""
    /// Command: shell command line run in the login shell. The full prompt
    /// arrives on stdin and in $MOOTERM_PROMPT; $MOOTERM_MODEL holds `model`.
    var command: String = ""
    /// SF Symbol name; empty shows the name's first letter.
    var symbol: String = ""
    var color: AccentColor = .green

    var keyAccount: String { "custom.\(id.uuidString)" }

    var letter: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// Short summary for lists.
    var summary: String {
        switch kind {
        case .openAICompatible:
            let host = URL(string: baseURL)?.host ?? baseURL
            return [host, model].filter { !$0.isEmpty }.joined(separator: " · ")
        case .command:
            return command
        }
    }
}

extension CustomAssistant {
    /// Starting points offered by the "+" menu. Everything stays editable.
    static let presets: [(label: String, make: () -> CustomAssistant)] = [
        ("Kimi (Moonshot API)", {
            CustomAssistant(name: "Kimi", kind: .openAICompatible, baseURL: "https://api.moonshot.cn/v1",
                            model: "kimi-k2-turbo-preview", apiKeyVariable: "MOONSHOT_API_KEY",
                            symbol: "moon.stars", color: .purple)
        }),
        ("Qwen (DashScope API)", {
            CustomAssistant(name: "Qwen", kind: .openAICompatible,
                            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                            model: "qwen-plus", apiKeyVariable: "DASHSCOPE_API_KEY",
                            symbol: "q.circle", color: .orange)
        }),
        ("OpenRouter", {
            CustomAssistant(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
                            model: "qwen/qwen3-coder", apiKeyVariable: "OPENROUTER_API_KEY",
                            symbol: "arrow.triangle.branch", color: .blue)
        }),
        ("Ollama (local)", {
            CustomAssistant(name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1",
                            model: "qwen2.5-coder", symbol: "desktopcomputer", color: .green)
        }),
        ("Qwen Code CLI", {
            CustomAssistant(name: "Qwen Code", kind: .command,
                            command: #"qwen -p "Follow the instructions above.""#, symbol: "q.circle", color: .orange)
        }),
        ("Kimi CLI", {
            CustomAssistant(name: "Kimi CLI", kind: .command,
                            command: #"kimi --quiet -p "$MOOTERM_PROMPT""#, symbol: "moon.stars", color: .purple)
        }),
        ("Gemini CLI", {
            CustomAssistant(name: "Gemini", kind: .command,
                            command: #"gemini -p "Follow the instructions above.""#, symbol: "diamond", color: .blue)
        }),
        ("opencode", {
            CustomAssistant(name: "opencode", kind: .command,
                            command: #"opencode run "$MOOTERM_PROMPT""#, symbol: "curlybraces", color: .yellow)
        }),
        ("Blank API", {
            CustomAssistant(name: "Custom API", kind: .openAICompatible, baseURL: "https://", color: .green)
        }),
        ("Blank command", {
            CustomAssistant(name: "Custom CLI", kind: .command, command: "", color: .green)
        }),
    ]
}

/// Persisted list of custom assistants (JSON in UserDefaults).
@MainActor
final class CustomAssistantStore: ObservableObject {
    static let storageKey = "mooTerm.customAssistants"

    @Published private(set) var assistants: [CustomAssistant] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([CustomAssistant].self, from: data) {
            assistants = saved
        }
    }

    func assistant(id: UUID) -> CustomAssistant? { assistants.first { $0.id == id } }

    @discardableResult
    func add(_ assistant: CustomAssistant) -> CustomAssistant {
        assistants.append(assistant)
        persist()
        return assistant
    }

    func update(_ assistant: CustomAssistant) {
        guard let index = assistants.firstIndex(where: { $0.id == assistant.id }) else { return }
        assistants[index] = assistant
        persist()
    }

    func remove(id: UUID) {
        assistants.removeAll { $0.id == id }
        APIKeyStore.save(nil, account: "custom.\(id.uuidString)")
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(assistants) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Command backend

/// Runs a user-supplied command line in the login shell (so PATH, aliases,
/// and the tool's own login apply), feeding the prompt on stdin and in
/// $MOOTERM_PROMPT, and pulls the JSON answer out of whatever it prints.
final class CustomCommandTranslator: CommandTranslator, @unchecked Sendable {
    let command: String
    private let runner = LoginShellProcess()

    init(command: String) { self.command = command }

    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure> {
        let command = self.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure(.failed("This assistant has no command. Set one in Settings → Custom Assistants.")) }
        let runner = self.runner
        return await Task.detached(priority: .userInitiated) {
            // CLIs have no system-prompt channel, so it leads the prompt.
            let prompt = "\(request.systemPrompt)\n\nRespond with only a JSON object matching this schema:\n\(request.schema)\n\n\(request.prompt)"
            var environment = request.environment
            environment["MOOTERM_PROMPT"] = prompt
            environment["MOOTERM_MODEL"] = request.model
            let result = runner.runScript(command, stdin: prompt, workingDirectory: request.workingDirectory,
                                          environment: environment, timeout: 300)
            return result.flatMap { output in
                let text = String(decoding: output.stdout, as: UTF8.self)
                if let reply = CommandReply.extract(from: text) { return .success(reply) }
                if output.status == 127 {
                    return .failure(.notInstalled(tool: "The command", hint: "Check it runs in a terminal pane: \(command)"))
                }
                let detail = LoginShellProcess.lastLines(output.stderr).nilIfEmpty
                    ?? LoginShellProcess.lastLines(output.stdout).nilIfEmpty
                return .failure(.failed(detail ?? "The command exited with status \(output.status) and printed no answer."))
            }
        }.value
    }

    func cancel() { runner.cancel() }
}

// MARK: - Sidebar descriptors

/// How an assistant appears in the activity bar and panel header.
struct AssistantDescriptor: Identifiable, Equatable {
    let item: SidebarItem
    let title: String
    let systemImage: String?
    let letter: String
    let tint: Color
    let modelLabel: String

    var id: String { item.rawValue }
}

extension CustomAssistant {
    func makeTranslator() -> CommandTranslator {
        switch kind {
        case .command:
            return CustomCommandTranslator(command: command)
        case .openAICompatible:
            return ChatCompletionsClient(providerName: name,
                                         keyVariable: apiKeyVariable.isEmpty ? "an API key variable" : apiKeyVariable,
                                         requiresKey: !apiKeyVariable.isEmpty)
        }
    }
}

extension AssistantDescriptor {
    /// Activity-bar order: built-ins, then custom assistants as added.
    @MainActor
    static func all(store: CustomAssistantStore, preferences: TerminalPreferences) -> [AssistantDescriptor] {
        let builtIns = AssistantProvider.allCases.map { provider in
            AssistantDescriptor(item: SidebarItem(provider: provider), title: provider.title,
                                systemImage: provider.systemImage, letter: String(provider.title.prefix(1)),
                                tint: provider.tint, modelLabel: preferences.model(for: provider))
        }
        let customs = store.assistants.map { custom in
            AssistantDescriptor(item: SidebarItem(custom: custom.id), title: custom.name,
                                systemImage: custom.symbol.isEmpty ? nil : custom.symbol, letter: custom.letter,
                                tint: custom.color.nsColor.map { Color(nsColor: $0) } ?? .gray,
                                modelLabel: custom.kind == .command
                                    ? String(custom.command.split(separator: " ").first ?? "")
                                    : custom.model)
        }
        return builtIns + customs
    }
}

/// Settings → request options for any sidebar assistant.
@MainActor
func assistantOptions(for item: SidebarItem, preferences: TerminalPreferences,
                      store: CustomAssistantStore) -> AssistantOptions {
    var options = AssistantOptions(model: "")
    options.environment = preferences.cliEnvironment
    options.apiProxy = preferences.apiProxy
    if let provider = item.provider {
        options.model = preferences.model(for: provider)
        options.baseURL = preferences.baseURL(for: provider)
        if provider.usesAPIKey { options.apiKey = keyResolver(account: provider.rawValue, variable: provider.apiKeyVariable) }
    } else if let id = item.customID, let custom = store.assistant(id: id) {
        options.model = custom.model
        options.baseURL = custom.baseURL
        if custom.kind == .openAICompatible {
            options.apiKey = keyResolver(account: custom.keyAccount, variable: custom.apiKeyVariable)
        }
    }
    return options
}

private func keyResolver(account: String, variable: String?) -> @Sendable () -> String? {
    { APIKeyStore.resolve(account: account, variable: variable) }
}
