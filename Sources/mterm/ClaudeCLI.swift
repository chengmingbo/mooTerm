import Foundation

/// Runs the Claude Code CLI (`claude -p`) as a one-shot, tool-less
/// translator with structured JSON output.
///
/// A Dock-launched app doesn't inherit the interactive shell's environment,
/// so the CLI runs through the user's interactive login shell — and is
/// invoked *by name*, so an alias, function, or wrapper the user set up for
/// `claude` applies (e.g. `alias claude='https_proxy=… claude'`; running the
/// binary by path skipped that and got "403 Request not allowed").
/// Arguments are passed positionally and never interpolated into shell source.
final class ClaudeCLI: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case notInstalled
        case cancelled
        case timedOut
        case failed(String)

        var message: String {
            switch self {
            case .notInstalled:
                return "Claude Code CLI was not found. Install it (https://claude.com/claude-code) or put it at ~/.local/bin/claude."
            case .cancelled: return "Cancelled."
            case .timedOut: return "Claude didn't answer within the time limit. Try again."
            case .failed(let message):
                if message.localizedCaseInsensitiveContains("not logged in") {
                    return "\(message)\n\nRun `claude auth login` in a terminal pane, then try again."
                }
                if message.contains("403") {
                    return "\(message)\n\nThe request was refused. If you normally reach Claude through a proxy or VPN, make sure `claude` works when typed in a new terminal pane (mTerm runs it the same way), or run `claude auth login`."
                }
                return message
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false
    private var didTimeOut = false

    /// Run one request. Blocks the calling thread; call from a detached task.
    /// Returns the `structured_output` object.
    func run(prompt: String,
             systemPrompt: String,
             schema: String,
             model: String,
             workingDirectory: URL,
             environment extra: [String: String] = [:],
             timeout: TimeInterval = 120) -> Result<[String: Any], Failure> {
        var arguments = [
            "--print",
            "--output-format", "json",
            "--tools", "",                 // translate only; mTerm runs the command
            "--no-session-persistence",
            "--setting-sources", "project",  // skip user hooks/plugins: ~10x cheaper
            "--strict-mcp-config",
            "--system-prompt", systemPrompt,
            "--json-schema", schema,
        ]
        if !model.isEmpty { arguments += ["--model", model] }

        let launch = Self.loginShellLaunch(arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if let fallback = Self.executablePath() { environment["MTERM_CLAUDE_BIN"] = fallback }
        // Proxy etc. An empty value removes the variable.
        for (key, value) in extra {
            environment[key] = value.isEmpty ? nil : value
        }
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

        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let timer = DispatchWorkItem { [weak self, weak process] in
            self?.lock.lock(); self?.didTimeOut = true; self?.lock.unlock()
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        // Read stderr concurrently so a chatty shell can't fill the pipe and
        // deadlock us while we wait on stdout.
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
        if process.terminationStatus == 127 { return .failure(.notInstalled) }
        return Self.parse(output: outputData, errorOutput: errorData, status: process.terminationStatus)
    }

    /// Stop an in-flight `run`. Safe from any thread.
    func cancel() {
        lock.lock()
        wasCancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    // MARK: - Parsing

    static func parse(output: Data, errorOutput: Data, status: Int32) -> Result<[String: Any], Failure> {
        let object = lastJSONObject(in: output)
        if let object, object["is_error"] as? Bool != true,
           let structured = object["structured_output"] as? [String: Any] {
            return .success(structured)
        }
        // Older CLIs put the JSON text in `result`.
        if let object, object["is_error"] as? Bool != true,
           let result = object["result"] as? String,
           let data = result.data(using: .utf8),
           let structured = lastJSONObject(in: data) {
            return .success(structured)
        }
        let message = (object?["result"] as? String)
            ?? String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return .failure(.failed(message)) }
        return .failure(.failed(status == 0
            ? "Claude returned an unreadable response."
            : "Claude Code exited with status \(status)."))
    }

    /// Interactive shell startup can print banners before the CLI's JSON,
    /// so accept the whole payload or else the last line that parses.
    static func lastJSONObject(in data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let lineData = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    // MARK: - Launch

    /// Runs `claude "$@"` in an interactive login shell. Aliases are
    /// expanded because the -c string is parsed after rc files load; if the
    /// shell can't find `claude`, fall back to the binary we located.
    static let launchScript = #"if type claude >/dev/null 2>&1; then claude "$@"; elif [ -n "$MTERM_CLAUDE_BIN" ]; then "$MTERM_CLAUDE_BIN" "$@"; else exit 127; fi"#

    static func loginShellLaunch(arguments: [String]) -> (executable: String, arguments: [String]) {
        let shell = TerminalHostView.resolveLoginShell()
        return (shell, ["-l", "-i", "-c", launchScript, "mterm-claude"] + arguments)
    }

    static func executablePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
