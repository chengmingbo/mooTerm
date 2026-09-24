import Foundation

/// What a backend returns for one request: a proposed command line (or
/// nil for a plain answer), an explanation, and the model's risk rating.
struct CommandReply: Equatable, Sendable {
    var command: String?
    var explanation: String
    var risk: String

    init(command: String?, explanation: String, risk: String) {
        self.command = command
        self.explanation = explanation
        self.risk = risk
    }

    init?(json object: [String: Any]) {
        guard object["command"] != nil || object["explanation"] != nil else { return nil }
        self.command = object["command"] as? String
        self.explanation = (object["explanation"] as? String) ?? ""
        self.risk = (object["risk"] as? String) ?? "caution"
    }

    /// Find the answer in arbitrary tool output: strips ANSI colour codes and
    /// <think> blocks, then tries every balanced {...} object (last first),
    /// unwrapping CLI envelopes like {"response": "..."}; falls back to a
    /// fenced code block as the command.
    static func extract(from raw: String) -> CommandReply? {
        var text = raw.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        for candidate in jsonObjects(in: text).reversed() {
            if let reply = CommandReply(json: candidate) { return reply }
            for key in ["response", "result", "text", "content", "output", "message"] {
                if let inner = candidate[key] as? String, let reply = extract(from: inner) { return reply }
            }
        }
        // No JSON: accept a fenced code block as the command.
        if let block = text.range(of: #"```[a-zA-Z]*\n([\s\S]*?)```"#, options: .regularExpression) {
            let body = text[block].split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let explanation = text.replacingCharacters(in: block, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return CommandReply(command: body, explanation: explanation, risk: "caution")
            }
        }
        return nil
    }

    /// Every top-level balanced JSON object in `text`, in order.
    static func jsonObjects(in text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        let chars = Array(text.utf8)
        var i = 0
        while i < chars.count {
            guard chars[i] == UInt8(ascii: "{") else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            var end: Int?
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == UInt8(ascii: "\\") { escaped = true }
                    else if c == UInt8(ascii: "\"") { inString = false }
                } else if c == UInt8(ascii: "\"") { inString = true }
                else if c == UInt8(ascii: "{") { depth += 1 }
                else if c == UInt8(ascii: "}") { depth -= 1; if depth == 0 { end = j; break } }
                j += 1
            }
            if let end, let object = try? JSONSerialization.jsonObject(with: Data(chars[i...end])) as? [String: Any] {
                objects.append(object)
                i = end + 1
            } else {
                i += 1
            }
        }
        return objects
    }

    /// Parse model text that should be a JSON object but may be wrapped in
    /// ```json fences or preceded by <think>…</think> reasoning.
    init?(text: String) {
        var body = text
        if let end = body.range(of: "</think>") { body = String(body[end.upperBound...]) }
        guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close,
              let data = String(body[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(json: object)
    }
}

enum AssistantFailure: Error, Equatable, Sendable {
    case notInstalled(tool: String, hint: String)
    case missingAPIKey(provider: String, variable: String)
    case cancelled
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled(let tool, let hint):
            return "\(tool) was not found. \(hint)"
        case .missingAPIKey(let provider, let variable):
            return "No \(provider) API key. Add one in Settings (⌘,) → \(provider), or export \(variable) in your shell profile."
        case .cancelled: return "Cancelled."
        case .timedOut: return "No answer within the time limit. Try again."
        case .failed(let message):
            if message.localizedCaseInsensitiveContains("not logged in") {
                return "\(message)\n\nLog in from a terminal pane (e.g. `claude auth login` or `codex login`), then try again."
            }
            if message.contains("403") || message.localizedCaseInsensitiveContains("reconnecting") {
                return "\(message)\n\nThe request was refused or couldn't connect. If you reach this service through a proxy or VPN, check Settings → Network → Proxy."
            }
            if message.contains("401") {
                return "\(message)\n\nThe API key was rejected. Check it in Settings (⌘,)."
            }
            return message
        }
    }
}

/// One in-flight request to a model. Each backend gets a fresh instance so
/// `cancel()` only affects the request it belongs to.
protocol CommandTranslator: AnyObject, Sendable {
    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure>
    func cancel()
}

enum APIProxy: Equatable, Sendable {
    /// URLSession's default, which follows the macOS system proxy.
    case system
    case custom(ProxyConfiguration)
    case none
}

struct TranslationRequest: Sendable {
    var prompt: String
    var systemPrompt: String
    var schema: String
    var model: String
    var workingDirectory: URL
    /// Extra variables for CLI backends (proxy); "" removes a variable.
    var environment: [String: String]
    /// Proxy for HTTP backends.
    var apiProxy: APIProxy
    var apiKey: String?
    var baseURL: String?
}

// MARK: - Process runner (CLI backends)

/// Runs a CLI through the user's interactive login shell, invoked *by
/// name* so aliases/functions/wrappers the user set up apply (e.g.
/// `alias claude='https_proxy=… claude'`), and so the Dock-launched app
/// gets the same PATH and environment as Terminal. Arguments are passed
/// positionally and never interpolated into shell source.
final class LoginShellProcess: @unchecked Sendable {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false
    private var didTimeOut = false

    static func launchScript(for tool: String) -> String {
        #"if type \#(tool) >/dev/null 2>&1; then \#(tool) "$@"; elif [ -n "$MOOTERM_TOOL_BIN" ]; then "$MOOTERM_TOOL_BIN" "$@"; else exit 127; fi"#
    }

    static func launch(tool: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        let shell = TerminalHostView.resolveLoginShell()
        return (shell, ["-l", "-i", "-c", launchScript(for: tool), "mooterm-\(tool)"] + arguments)
    }

    func run(tool: String, fallbackPaths: [String], arguments: [String], stdin: String,
             workingDirectory: URL, environment extra: [String: String],
             timeout: TimeInterval) -> Result<Output, AssistantFailure> {
        var environment = extra
        if let fallback = fallbackPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            environment["MOOTERM_TOOL_BIN"] = fallback
        }
        return execute(Self.launch(tool: tool, arguments: arguments), stdin: stdin,
                       workingDirectory: workingDirectory, environment: environment, timeout: timeout)
    }

    /// Run a user-written command line (custom assistants) the same way.
    func runScript(_ script: String, stdin: String, workingDirectory: URL,
                   environment extra: [String: String], timeout: TimeInterval) -> Result<Output, AssistantFailure> {
        let shell = TerminalHostView.resolveLoginShell()
        return execute((shell, ["-l", "-i", "-c", script, "mooterm-custom"]), stdin: stdin,
                       workingDirectory: workingDirectory, environment: extra, timeout: timeout)
    }

    private func execute(_ launch: (executable: String, arguments: [String]), stdin: String,
                         workingDirectory: URL, environment extra: [String: String],
                         timeout: TimeInterval) -> Result<Output, AssistantFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        for (key, value) in extra { environment[key] = value.isEmpty ? nil : value }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        lock.lock()
        if wasCancelled { lock.unlock(); return .failure(.cancelled) }
        self.process = process
        lock.unlock()
        defer { lock.lock(); self.process = nil; lock.unlock() }

        do { try process.run() } catch { return .failure(.failed(error.localizedDescription)) }

        let timer = DispatchWorkItem { [weak self, weak process] in
            self?.lock.lock(); self?.didTimeOut = true; self?.lock.unlock()
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        // Drain stderr concurrently so a chatty tool can't fill the pipe
        // and deadlock us while we wait on stdout.
        var errorData = Data()
        let errorReader = DispatchWorkItem { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: errorReader)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorReader.wait()
        timer.cancel()

        lock.lock(); let cancelled = wasCancelled, timedOut = didTimeOut; lock.unlock()
        if cancelled { return .failure(.cancelled) }
        if timedOut { return .failure(.timedOut) }
        return .success(Output(status: process.terminationStatus, stdout: outputData, stderr: errorData))
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    /// Interactive shell startup can print banners before a tool's JSON, so
    /// accept the whole payload or else the last line that parses.
    static func lastJSONObject(in data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let lineData = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    static func lastLines(_ data: Data, count: Int = 3) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude Code CLI

/// `claude -p` as a tool-less translator with structured JSON output.
final class ClaudeCLI: CommandTranslator, @unchecked Sendable {
    private let runner = LoginShellProcess()

    static var fallbackPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static func arguments(for request: TranslationRequest) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "json",
            "--tools", "",                   // translate only; mooTerm runs the command
            "--no-session-persistence",
            "--setting-sources", "project",  // skip user hooks/plugins: ~10x cheaper
            "--strict-mcp-config",
            "--system-prompt", request.systemPrompt,
            "--json-schema", request.schema,
        ]
        if !request.model.isEmpty { arguments += ["--model", request.model] }
        return arguments
    }

    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure> {
        let runner = self.runner
        return await Task.detached(priority: .userInitiated) {
            let result = runner.run(tool: "claude", fallbackPaths: Self.fallbackPaths,
                                    arguments: Self.arguments(for: request), stdin: request.prompt,
                                    workingDirectory: request.workingDirectory,
                                    environment: request.environment, timeout: 180)
            return result.flatMap(Self.parse)
        }.value
    }

    func cancel() { runner.cancel() }

    static func parse(_ output: LoginShellProcess.Output) -> Result<CommandReply, AssistantFailure> {
        if output.status == 127 {
            return .failure(.notInstalled(tool: "Claude Code CLI", hint: "Install it from https://claude.com/claude-code."))
        }
        let object = LoginShellProcess.lastJSONObject(in: output.stdout)
        if let object, object["is_error"] as? Bool != true {
            if let structured = object["structured_output"] as? [String: Any],
               let reply = CommandReply(json: structured) {
                return .success(reply)
            }
            // Older CLIs put the JSON text in `result`.
            if let result = object["result"] as? String, let reply = CommandReply(text: result) {
                return .success(reply)
            }
        }
        let message = (object?["result"] as? String)
            ?? LoginShellProcess.lastLines(output.stderr).nilIfEmpty
        return .failure(.failed(message ?? (output.status == 0
            ? "Claude returned an unreadable response."
            : "Claude Code exited with status \(output.status).")))
    }
}

// MARK: - Codex CLI

/// `codex exec` in a read-only sandbox with an output schema. Codex is an
/// agent, so it may run read-only commands to look around before answering.
final class CodexCLI: CommandTranslator, @unchecked Sendable {
    private let runner = LoginShellProcess()

    static let fallbackPaths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]

    static func arguments(for request: TranslationRequest, schemaFile: URL, outputFile: URL) -> [String] {
        var arguments = [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "-c", #"model_reasoning_effort="low""#,
            "--cd", request.workingDirectory.path,
            "--output-schema", schemaFile.path,
            "--output-last-message", outputFile.path,
        ]
        if !request.model.isEmpty { arguments += ["--model", request.model] }
        arguments.append("-")  // prompt from stdin
        return arguments
    }

    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure> {
        let runner = self.runner
        return await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mooterm-codex-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let schemaFile = dir.appendingPathComponent("schema.json")
            let outputFile = dir.appendingPathComponent("last.txt")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(request.schema.utf8).write(to: schemaFile)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
            // Codex has no system-prompt flag in exec mode; prepend it.
            let stdin = "\(request.systemPrompt)\n\n\(request.prompt)"
            let result = runner.run(tool: "codex", fallbackPaths: Self.fallbackPaths,
                                    arguments: Self.arguments(for: request, schemaFile: schemaFile, outputFile: outputFile),
                                    stdin: stdin, workingDirectory: request.workingDirectory,
                                    environment: request.environment, timeout: 600)
            return result.flatMap { output in
                if output.status == 127 {
                    return .failure(.notInstalled(tool: "Codex CLI", hint: "Install it with `brew install codex`."))
                }
                let text = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
                if let reply = CommandReply(text: text) { return .success(reply) }
                let detail = LoginShellProcess.lastLines(output.stderr).nilIfEmpty
                    ?? LoginShellProcess.lastLines(output.stdout).nilIfEmpty
                return .failure(.failed(detail ?? "Codex exited with status \(output.status)."))
            }
        }.value
    }

    func cancel() { runner.cancel() }
}

// MARK: - OpenAI-compatible chat APIs (DeepSeek, MiniMax)

/// Direct HTTPS call to a `/chat/completions` endpoint in JSON mode.
/// Much faster than an agent CLI for one-line translations.
final class ChatCompletionsClient: CommandTranslator, @unchecked Sendable {
    let providerName: String
    let keyVariable: String
    /// False for servers that need no auth (e.g. local Ollama).
    let requiresKey: Bool
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var wasCancelled = false

    init(providerName: String, keyVariable: String, requiresKey: Bool = true) {
        self.providerName = providerName
        self.keyVariable = keyVariable
        self.requiresKey = requiresKey
    }

    static func body(for request: TranslationRequest, jsonMode: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": request.systemPrompt
                    + "\n\nRespond with only a JSON object matching this schema:\n" + request.schema],
                ["role": "user", "content": request.prompt],
            ],
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return body
    }

    /// Session honouring mooTerm's proxy setting. Automatic uses URLSession's
    /// own default, which already follows the macOS system proxy.
    static func session(proxy: APIProxy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        switch proxy {
        case .system:
            break
        case .none:
            configuration.connectionProxyDictionary = [:]
        case .custom(let custom):
            guard let url = (custom.https ?? custom.http).flatMap(URL.init(string:)), let host = url.host else { break }
            let port = url.port ?? 80
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                "HTTPSEnable": true,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        }
        return URLSession(configuration: configuration)
    }

    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure> {
        let key = request.apiKey ?? ""
        if key.isEmpty && requiresKey {
            return .failure(.missingAPIKey(provider: providerName, variable: keyVariable))
        }
        guard let base = request.baseURL, let url = URL(string: base.trimmingSuffix("/") + "/chat/completions") else {
            return .failure(.failed("Invalid \(providerName) API address."))
        }
        let first = await send(request, url: url, key: key, jsonMode: true)
        // Some models/endpoints reject response_format; retry without it.
        if case .failure(.failed(let message)) = first, message.contains("response_format") {
            return await send(request, url: url, key: key, jsonMode: false)
        }
        return first
    }

    private func send(_ request: TranslationRequest, url: URL, key: String, jsonMode: Bool) async -> Result<CommandReply, AssistantFailure> {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request, jsonMode: jsonMode))
        let session = Self.session(proxy: request.apiProxy)

        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                continuation.resume(returning: Self.parse(data: data, response: response, error: error,
                                                          provider: self.providerName))
            }
            lock.lock()
            if wasCancelled {
                lock.unlock()
                continuation.resume(returning: .failure(.cancelled))
                return
            }
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    static func parse(data: Data?, response: URLResponse?, error: Error?, provider: String) -> Result<CommandReply, AssistantFailure> {
        if let error = error as? URLError, error.code == .cancelled { return .failure(.cancelled) }
        if let error = error as? URLError, error.code == .timedOut { return .failure(.timedOut) }
        if let error { return .failure(.failed(error.localizedDescription)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard (200..<300).contains(status) else {
            let apiMessage = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? ((object?["base_resp"] as? [String: Any])?["status_msg"] as? String)
            return .failure(.failed("\(provider) API error \(status)" + (apiMessage.map { ": \($0)" } ?? "")))
        }
        // MiniMax reports some errors with HTTP 200 and base_resp.status_code ≠ 0.
        if let base = object?["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, code != 0 {
            return .failure(.failed("\(provider) API error \(code): \(base["status_msg"] as? String ?? "")"))
        }
        let content = ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let content, let reply = CommandReply.extract(from: content) else {
            return .failure(.failed("\(provider) returned an unreadable response."))
        }
        return .success(reply)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
