import AppKit
import Combine
import Foundation

/// How much damage a command could do. The panel shows it as a badge;
/// `.danger` always needs confirmation and is never auto-run.
enum CommandRisk: String, Codable, Comparable, Sendable {
    case safe, caution, danger

    static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    private var order: Int { self == .safe ? 0 : self == .caution ? 1 : 2 }

    /// Local, model-independent check. The final risk is the higher of this
    /// and the model's own rating, so a mislabelled command can't slip by.
    static func assess(_ command: String) -> CommandRisk {
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        let danger = [
            #"\brm\s+(-\S*[rRf]|--recursive|--force)"#, #"\bsudo\b"#, #"\bdd\b\s"#, #"\bmkfs"#,
            #"\bdiskutil\s+(erase|partition|zero|secureErase)"#, #">\s*/dev/(disk|rdisk|sd)"#,
            #"\b(chmod|chown)\s+-\S*R"#, #"\bgit\s+push\b.*(--force|\s-f\b)"#, #"\bgit\s+reset\s+--hard"#,
            #"\bgit\s+clean\s+-\S*f"#, #"(curl|wget)\b.*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#, #":\(\)\s*\{"#,
            #"\b(shutdown|reboot|halt)\b"#, #"\bkillall\b"#, #"\bkill\s+-9"#, #"-delete\b"#,
            #"-exec\s+rm\b"#, #"\bxargs\b.*\brm\b"#, #"\bsrm\b"#, #"\blaunchctl\s+(unload|remove|bootout)"#,
            #"\btruncate\b"#,
        ]
        if matches(danger) { return .danger }
        let caution = [
            #"\brm\b"#, #"\bmv\b"#, #"\bcp\b"#, #"(^|[^>&0-9])>\s*[^>&\s]"#, #"\bsed\s+(-\S+\s+)*-i"#,
            #"\bgit\s+(commit|push|pull|checkout|switch|rebase|merge|stash|reset|branch\s+-[dD])"#,
            #"\b(brew|pip3?|npm|pnpm|yarn|gem|cargo)\s+(install|uninstall|remove|upgrade|update)"#,
            #"\b(chmod|chown|kill|pkill|ln)\b"#, #"\bmkdir\b"#, #"\btouch\b"#, #"\btee\b"#,
            #"\bcurl\b.*\s-(o|O)\b"#, #"\bopen\b"#,
        ]
        return matches(caution) ? .caution : .safe
    }
}

/// One line in the panel's transcript.
struct AssistantEntry: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, note }
    enum Status: String, Codable, Sendable { case proposed, ran, inserted }

    var id = UUID()
    let role: Role
    /// User request, assistant explanation, or a note (errors, "ran in …").
    var text: String
    /// Proposed command line (assistant entries only; nil for plain answers).
    var command: String?
    var risk: CommandRisk?
    var status: Status?
}

/// What Claude knows about the pane it is writing commands for.
struct TerminalContext: Sendable, Equatable {
    var cwd: String
    var shell: String
    /// A program running in the foreground (vim, top…) — commands can't run.
    var foregroundProgram: String?
    /// Last lines of the pane's screen/scrollback, so "why did that fail?"
    /// and "now sort that by size" work.
    var recentOutput: String
    /// Panes that will receive the command because broadcast is on.
    var broadcastPaneCount: Int

    var promptSection: String {
        """
        <terminal>
        os: macOS \(ProcessInfo.processInfo.operatingSystemVersionString) — BSD userland (no GNU-only flags unless installed)
        shell: \(shell)
        cwd: \(cwd)
        foreground program: \(foregroundProgram ?? "none (shell prompt)")
        </terminal>
        <recent_output>
        \(recentOutput.isEmpty ? "(empty)" : recentOutput)
        </recent_output>
        """
    }
}

/// The Claude panel's brain: turns requests into shell command proposals
/// and runs accepted ones in a pane. Knows nothing about SwiftUI.
@MainActor
final class CommandAssistant: ObservableObject {
    static let autoRunKey = "mTerm.assistant.autoRunSafe"
    static let entriesKey = "mTerm.assistant.entries"
    static let maxStoredEntries = 60

    @Published private(set) var entries: [AssistantEntry] = []
    @Published private(set) var isThinking = false
    @Published private(set) var thinkingSince: Date?
    /// Run `.safe` proposals immediately, like typing them yourself.
    @Published var autoRunSafe: Bool {
        didSet { defaults.set(autoRunSafe, forKey: Self.autoRunKey) }
    }

    private let defaults: UserDefaults
    private var cli: ClaudeCLI?
    /// Swappable for tests.
    var translate: (_ prompt: String, _ model: String, _ cwd: URL, _ cli: ClaudeCLI) async -> Result<[String: Any], ClaudeCLI.Failure> = { prompt, model, cwd, cli in
        await Task.detached(priority: .userInitiated) {
            cli.run(prompt: prompt, systemPrompt: CommandAssistant.systemPrompt,
                    schema: CommandAssistant.schema, model: model, workingDirectory: cwd)
        }.value
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoRunSafe = defaults.bool(forKey: Self.autoRunKey)
        if let data = defaults.data(forKey: Self.entriesKey),
           let saved = try? JSONDecoder().decode([AssistantEntry].self, from: data) {
            entries = saved
        }
    }

    // MARK: - Asking

    /// Handle what the user typed. `!cmd` runs `cmd` verbatim (no Claude).
    /// Returns the proposal entry to auto-run, if any, so the caller can run
    /// it against the current pane.
    func submit(_ raw: String, context: TerminalContext, model: String) async -> AssistantEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return nil }

        if text.hasPrefix("!") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            append(AssistantEntry(role: .user, text: text))
            let entry = AssistantEntry(role: .assistant, text: "Run as typed.", command: command,
                                       risk: CommandRisk.assess(command), status: .proposed)
            append(entry)
            return entry.risk == .danger ? nil : entry
        }

        let history = Self.historySection(entries)
        append(AssistantEntry(role: .user, text: text))
        let prompt = Self.prompt(request: text, context: context, history: history)

        isThinking = true
        thinkingSince = Date()
        let cli = ClaudeCLI()
        self.cli = cli
        let result = await translate(prompt, model, URL(fileURLWithPath: context.cwd), cli)
        self.cli = nil
        isThinking = false
        thinkingSince = nil

        switch result {
        case .success(let object):
            let entry = Self.entry(from: object)
            append(entry)
            if autoRunSafe, entry.command != nil, entry.risk == .safe { return entry }
        case .failure(.cancelled):
            append(AssistantEntry(role: .note, text: "Cancelled."))
        case .failure(let failure):
            append(AssistantEntry(role: .note, text: failure.message))
        }
        return nil
    }

    func cancel() { cli?.cancel() }

    func clear() {
        guard !isThinking else { return }
        entries = []
        persist()
    }

    // MARK: - Running

    enum RunError: Error, Equatable {
        case noPane
        case busy(String)
        var message: String {
            switch self {
            case .noPane: return "No terminal pane to run in."
            case .busy(let program): return "“\(program)” is running in the pane. Quit it first, or use Insert."
            }
        }
    }

    /// Type the command at the pane's prompt and press Return. Goes through
    /// the pane's normal input path, so broadcast groups receive it too.
    func run(_ entryID: UUID, command: String, in pane: Pane?) -> RunError? {
        guard let host = pane?.host else { return .noPane }
        if let program = host.foregroundProcessName { return .busy(program) }
        host.typeCommand(command, execute: true)
        mark(entryID, command: command, status: .ran)
        return nil
    }

    /// Put the command on the prompt without running it, for editing.
    func insert(_ entryID: UUID, command: String, in pane: Pane?) -> RunError? {
        guard let host = pane?.host else { return .noPane }
        if let program = host.foregroundProcessName { return .busy(program) }
        host.typeCommand(command, execute: false)
        mark(entryID, command: command, status: .inserted)
        return nil
    }

    func note(_ text: String) { append(AssistantEntry(role: .note, text: text)) }

    // MARK: - Prompt

    nonisolated static let systemPrompt = """
    You are the command assistant inside mTerm, a macOS terminal. Turn the user's \
    natural-language request into ONE shell command line for their shell. Prefer a \
    single pipeline (cmd | cmd | cmd) over multiple statements; use && only when steps \
    depend on each other. Use tools that ship with macOS (BSD find/sed/stat/date, awk, \
    sort, xargs, grep -E, du, lsof, ps, git) unless the context shows others installed. \
    Quote paths safely. Never use sudo unless explicitly asked. Prefer read-only \
    commands; if the request is destructive, still answer but rate it "danger".
    Rate risk: "safe" = read-only; "caution" = modifies files, git state, or installs; \
    "danger" = deletes data, force-pushes, needs sudo, or is hard to undo.
    If the user asks a question (e.g. about the recent output) rather than for an \
    action, set command to null and answer in explanation. Keep explanation to one or \
    two short sentences; mention what each pipeline stage does only when it is non-obvious.
    """

    nonisolated static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "command":{"type":["string","null"],"description":"Single shell command line, or null"},\
    "explanation":{"type":"string"},\
    "risk":{"type":"string","enum":["safe","caution","danger"]}},\
    "required":["command","explanation","risk"]}
    """

    nonisolated static func prompt(request: String, context: TerminalContext, history: String) -> String {
        var parts = [context.promptSection]
        if !history.isEmpty { parts.append("<conversation>\n\(history)\n</conversation>") }
        parts.append("<request>\n\(request)\n</request>")
        return parts.joined(separator: "\n\n")
    }

    /// Recent exchanges, so follow-ups like "only .swift files" work.
    nonisolated static func historySection(_ entries: [AssistantEntry], limit: Int = 8) -> String {
        entries.filter { $0.role != .note }.suffix(limit).map { entry in
            switch entry.role {
            case .user: return "user: \(entry.text)"
            case .assistant:
                let command = entry.command.map { "`\($0)`" } ?? "(no command)"
                let status = entry.status.map { " [\($0.rawValue)]" } ?? ""
                return "assistant: \(command)\(status) — \(entry.text)"
            case .note: return ""
            }
        }.joined(separator: "\n")
    }

    nonisolated static func entry(from object: [String: Any]) -> AssistantEntry {
        let raw = (object["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (raw?.isEmpty == false) ? raw : nil
        let explanation = (object["explanation"] as? String) ?? ""
        let modelRisk = (object["risk"] as? String).flatMap(CommandRisk.init(rawValue:)) ?? .caution
        let risk = command.map { max(modelRisk, CommandRisk.assess($0)) }
        return AssistantEntry(role: .assistant, text: explanation, command: command,
                              risk: risk, status: command == nil ? nil : .proposed)
    }

    // MARK: - Storage

    private func append(_ entry: AssistantEntry) {
        entries.append(entry)
        persist()
    }

    private func mark(_ id: UUID, command: String, status: AssistantEntry.Status) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].command = command
        entries[index].risk = max(entries[index].risk ?? .safe, CommandRisk.assess(command))
        entries[index].status = status
        persist()
    }

    private func persist() {
        let retained = Array(entries.suffix(Self.maxStoredEntries))
        if let data = try? JSONEncoder().encode(retained) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }
}

extension TerminalContext {
    /// Snapshot of `pane` for the prompt.
    @MainActor
    static func of(_ pane: Pane?, broadcastPaneCount: Int, outputLines: Int = 40) -> TerminalContext {
        let cwd = pane?.currentDirectory ?? NSHomeDirectory()
        return TerminalContext(
            cwd: cwd,
            shell: URL(fileURLWithPath: TerminalHostView.resolveLoginShell()).lastPathComponent,
            foregroundProgram: pane?.runningProcessName,
            recentOutput: pane?.host?.recentOutput(lines: outputLines) ?? "",
            broadcastPaneCount: broadcastPaneCount)
    }
}
