import Testing
import AppKit
import SwiftUI
@testable import mooterm

@MainActor
@Test func splitTreeGrowsOnSplit() {
    let tab = TabSession()
    #expect(tab.collectPanes(tab.root).count == 1)
    tab.split(.horizontal)
    #expect(tab.collectPanes(tab.root).count == 2)
    tab.split(.vertical)
    #expect(tab.collectPanes(tab.root).count == 3)
}

@MainActor
@Test func closePaneReducesTree() {
    let tab = TabSession()
    tab.split(.horizontal)
    tab.split(.horizontal)
    #expect(tab.collectPanes(tab.root).count == 3)
    tab.closeActivePane()
    #expect(tab.collectPanes(tab.root).count == 2)
}

@MainActor
@Test func broadcastTargetsIncludeSameGroup() {
    let tab = TabSession()
    let p1 = tab.collectPanes(tab.root)[0]
    tab.split(.horizontal)
    let p2 = tab.collectPanes(tab.root)[1]
    p2.shellID = "A"
    p1.shellID = "A"
    tab.broadcast = true
    let targets = tab.broadcastTargets(for: p1)
    #expect(targets.count == 2)
}

@MainActor
@Test func sessionStoreClosesAndReopens() {
    let store = SessionStore()
    let first = store.activeTabID
    store.newTab()
    store.newTab()
    #expect(store.tabs.count == 3)
    store.closeTab(first)
    #expect(store.tabs.count == 2)
    #expect(store.activeTabID != first)
}

@Test func allColorSchemesHaveUniqueIDsAndPalettes() {
    let ids = ColorScheme.all.map(\.id)
    #expect(Set(ids).count == ids.count, "scheme ids must be unique")
    for scheme in ColorScheme.all {
        #expect(scheme.palette.count == 16, "\(scheme.id) palette should have 16 entries")
    }
}

@Test func colorSchemeStorePersistsSelection() {
    let defaults = UserDefaults(suiteName: "mooterm-test-\(UUID().uuidString)")!
    defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
    let store = ColorSchemeStore(defaults: defaults)
    #expect(store.current.id == ColorScheme.terminator.id)
    store.select(.solarizedDark)
    #expect(store.current.id == ColorScheme.solarizedDark.id)
    let reloaded = ColorSchemeStore(defaults: defaults)
    #expect(reloaded.current.id == ColorScheme.solarizedDark.id)
}

@Test func nsColorHexParsesRGBAndRRGGBB() {
    let rgb = NSColor(hex: "#f00")
    #expect(rgb != nil)
    let six = NSColor(hex: "#ffcc00")
    #expect(six != nil)
    #expect(NSColor(hex: "not a color") == nil)
}

@Test func fontSizeStoreClampsAndPersists() {
    let defaults = UserDefaults(suiteName: "mooterm-font-test-\(UUID().uuidString)")!
    let store = FontSizeStore(defaults: defaults)
    #expect(store.size == FontSizeStore.default)

    store.increase()
    #expect(store.size == FontSizeStore.default + FontSizeStore.step)

    store.decrease()
    store.decrease()
    #expect(store.size == FontSizeStore.default - FontSizeStore.step)

    store.reset()
    #expect(store.size == FontSizeStore.default)

    // Clamp at the upper bound.
    for _ in 0..<100 { store.increase() }
    #expect(store.size == FontSizeStore.maxSize)

    // Persist across instances.
    let reloaded = FontSizeStore(defaults: defaults)
    #expect(reloaded.size == FontSizeStore.maxSize)
}

@MainActor
@Test func tabTitlePrefersCustomTitleOverCwd() {
    let tab = TabSession()
    tab.root.pane?.cwd = nil
    #expect(tab.title == "shell", "fresh tab with no cwd shows shell")
    tab.root.pane?.cwd = "/tmp/projects/foo"
    #expect(tab.title == "foo")
    tab.customTitle = "Production"
    #expect(tab.title == "Production")
    tab.customTitle = ""
    #expect(tab.title == "foo", "empty custom title falls back to cwd")
    tab.customTitle = nil
    #expect(tab.title == "foo")
}

@Test func accentColorAllCasesHaveUniqueIDs() {
    let ids = AccentColor.allCases.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@MainActor
@Test func layoutStoreSaveAndRestore() throws {
    // Use an isolated temp file so we don't touch the user's real layouts.
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mooTermLayoutTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let fm = FileManager.default
    let storeURL = tmpDir.appendingPathComponent("layouts.json")
    let original = fm.ubiquityIdentityToken
    defer { _ = original }
    // The store uses appSupportDirectory; for this test we skip persistence
    // and exercise the snapshot/restore in-memory by using LayoutStore with
    // a custom URL via reflection. Easier: rely on the public snapshot/restore
    // path that doesn't touch disk.
    let session = SessionStore()
    let tab = session.activeTab!
    tab.customTitle = "production"
    tab.accent = .blue

    let saved = LayoutStore.snapshot(of: session, name: "test")
    #expect(saved.tabs.count == 1)
    #expect(saved.tabs.first?.customTitle == "production")
    #expect(saved.tabs.first?.accent == "blue")

    // Modify the live tab, then undo via restore.
    tab.customTitle = "scratch"
    tab.accent = .green
    LayoutStore.snapshot(of: session, name: "ignored").tabs // ensure no-op
    let store = LayoutStore()
    let fresh = SessionStore()
    store.restore(saved, into: fresh)
    let restored = fresh.activeTab!
    #expect(restored.id == tab.id)
    #expect(restored.customTitle == "production")
    #expect(restored.accent == .blue)
}

@MainActor
@Test func terminalHostViewAppliesFontSizeImmediately() {
    let host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSHomeDirectory()))
    host.configureAppearance(fontSize: 13)
    #expect(host.view.font.pointSize == 13)
    host.configureAppearance(fontSize: 20)
    #expect(host.view.font.pointSize == 20)
    #expect(host.view.font.isFixedPitch)
}

// MARK: - Pane lifecycle and navigation

@MainActor
@Test func paneKeepsItsTerminalAcrossRemounts() {
    // Regression: SwiftUI owned the terminal, so splitting, zooming, or
    // switching tabs destroyed the shell and started a new one.
    let pane = Pane(cwd: NSTemporaryDirectory())
    let first = pane.ensureHost(fontSize: 13, scheme: .terminator, scrollback: 1_000)
    let second = pane.ensureHost(fontSize: 13, scheme: .terminator, scrollback: 1_000)
    #expect(first != nil && first === second)
    pane.terminate()
    #expect(pane.host == nil)
    // Regression: a redraw after closing started a fresh, orphaned shell.
    #expect(pane.ensureHost(fontSize: 13, scheme: .terminator, scrollback: 1_000) == nil)
}

@MainActor
@Test func splitTargetsGivenPaneAndInheritsCwd() {
    let tab = TabSession(cwd: "/tmp")
    let original = tab.panes[0]
    tab.split(.vertical)                 // [original | b], b active
    let b = tab.activePane!
    #expect(b.cwd == "/tmp", "new split starts in the split pane's directory")
    original.cwd = "/usr"
    tab.split(.horizontal, pane: original.id)
    #expect(tab.panes.count == 3)
    #expect(tab.activePane?.cwd == "/usr", "split acted on the given pane, not the active one")
}

@MainActor
@Test func closePaneClosesTheGivenPaneNotTheActiveOne() {
    let tab = TabSession()
    let a = tab.panes[0]
    tab.split(.vertical)
    let b = tab.activePane!
    #expect(tab.closePane(a.id))
    #expect(tab.panes.map(\.id) == [b.id])
    #expect(!tab.closePane(b.id), "last pane can't be closed by the tab")
}

@MainActor
@Test func spatialPaneNavigation() {
    // Layout: [ a | (b over c) ]
    let tab = TabSession()
    let a = tab.panes[0]
    tab.split(.vertical)
    let b = tab.activePane!
    tab.split(.horizontal)
    let c = tab.activePane!
    #expect(tab.neighbor(of: a.id, .right) != nil)
    #expect(tab.neighbor(of: b.id, .left) == a.id)
    #expect(tab.neighbor(of: c.id, .left) == a.id)
    #expect(tab.neighbor(of: b.id, .down) == c.id)
    #expect(tab.neighbor(of: c.id, .up) == b.id)
    #expect(tab.neighbor(of: a.id, .left) == nil)
    tab.setActive(paneID: c.id)
    tab.cyclePane(by: 1)
    #expect(tab.activePaneID == a.id, "cycling wraps around")
}

@MainActor
@Test func tabNumberShortcutsAndCycling() {
    let store = SessionStore()
    store.newTab()
    store.newTab()
    let ids = store.tabs.map(\.id)
    store.selectTab(number: 1)
    #expect(store.activeTabID == ids[0])
    store.selectTab(number: 9)
    #expect(store.activeTabID == ids[2], "⌘9 selects the last tab")
    store.cycleTab(by: 1)
    #expect(store.activeTabID == ids[0])
    store.cycleTab(by: -1)
    #expect(store.activeTabID == ids[2])
}

@MainActor
@Test func switchingTabsClearsActivityIndicators() {
    let store = SessionStore()
    let first = store.activeTab!
    store.newTab()
    first.panes[0].hasUnseenOutput = true
    first.panes[0].bellRang = true
    #expect(first.hasUnseenOutput && first.bellRang)
    store.setActive(first.id)
    #expect(!first.hasUnseenOutput && !first.bellRang)
}

// MARK: - Keyboard

private func keyEvent(_ chars: String, _ ignoring: String, _ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                     windowNumber: 0, context: nil, characters: chars,
                     charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
}

@MainActor
@Test func naturalTextEditingMapsMacShortcutsToReadline() {
    let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    #expect(NaturalTextEditing.bytes(for: keyEvent(left, left, [.command, .function, .numericPad])) == [0x01])
    #expect(NaturalTextEditing.bytes(for: keyEvent(right, right, [.command])) == [0x05])
    #expect(NaturalTextEditing.bytes(for: keyEvent(left, left, [.option])) == [0x1B, 0x62])
    #expect(NaturalTextEditing.bytes(for: keyEvent("\u{7F}", "\u{7F}", [.command])) == [0x15])
    #expect(NaturalTextEditing.bytes(for: keyEvent("\u{7F}", "\u{7F}", [.option])) == [0x1B, 0x7F])
    // ⌘⌥← is pane navigation, and plain control keys go to the shell as-is.
    #expect(NaturalTextEditing.bytes(for: keyEvent(left, left, [.command, .option])) == nil)
    #expect(NaturalTextEditing.bytes(for: keyEvent("\u{01}", "a", [.control])) == nil)
}

@MainActor
@Test func controlKeysReachTheShell() {
    // ⌃A / ⌃E / ⌃L / ⌃R / ⌃U are handled by the shell's line editor; the
    // terminal just has to deliver the raw control byte.
    let view = MooTermTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    var sent: [UInt8] = []
    view.onInput = { sent += $0 }
    for (letter, byte) in [("a", 0x01), ("e", 0x05), ("l", 0x0C), ("r", 0x12), ("u", 0x15)] as [(String, UInt8)] {
        sent = []
        let ctrl = String(Character(UnicodeScalar(byte)))
        view.keyDown(with: keyEvent(ctrl, letter, [.control]))
        #expect(sent == [byte], "⌃\(letter.uppercased())")
    }
}

// MARK: - Scrollback and ⌘K

@MainActor
private func bufferText(_ host: TerminalHostView) -> String {
    String(decoding: host.view.getTerminal().getBufferAsData(), as: UTF8.self)
}

@MainActor
private func feedLines(_ host: TerminalHostView, _ count: Int) {
    host.view.feed(text: (1...count).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
}

@MainActor
@Test func clearBufferWipesScreenAndScrollback() {
    let host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    host.applyScrollback(lines: 1_000)
    feedLines(host, 300)
    #expect(bufferText(host).contains("line 1\n"), "early lines are in scrollback before ⌘K")
    #expect(bufferText(host).contains("line 300"))
    host.clearBuffer()
    #expect(!bufferText(host).contains("line"), "⌘K leaves neither screen nor history")
}

@MainActor
@Test func scrollbackLimitIsAppliedToTheTerminal() {
    let host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    host.applyScrollback(lines: 50)
    feedLines(host, 500)
    let text = bufferText(host)
    #expect(!text.contains("line 100\n"), "lines beyond the 50-line history are dropped")
    #expect(text.contains("line 500"))
    host.applyScrollback(lines: 1_000)
    feedLines(host, 900)
    #expect(bufferText(host).contains("line 10\n"), "raising the limit keeps more history")
}

@MainActor
@Test func terminalPreferencesClampAndPersistScrollback() {
    let defaults = UserDefaults(suiteName: "mooterm-prefs-test-\(UUID().uuidString)")!
    let prefs = TerminalPreferences(defaults: defaults)
    #expect(prefs.scrollbackLines == TerminalPreferences.defaultScrollback)
    prefs.scrollbackLines = 25_000
    #expect(TerminalPreferences(defaults: defaults).scrollbackLines == 25_000)
    prefs.scrollbackLines = -5
    #expect(prefs.scrollbackLines == 0)
    prefs.scrollbackLines = 9_999_999
    #expect(prefs.scrollbackLines == TerminalPreferences.scrollbackRange.upperBound)
    #expect(TerminalPreferences(defaults: defaults).scrollbackLines == TerminalPreferences.scrollbackRange.upperBound)
}

// MARK: - Claude command panel

@Test func riskAssessmentFlagsDestructiveCommands() {
    #expect(CommandRisk.assess("find . -type f | xargs du -h | sort -hr | head") == .safe)
    #expect(CommandRisk.assess("git log --since='1 week ago' --author=me --oneline") == .safe)
    #expect(CommandRisk.assess("ls 2>/dev/null | wc -l") == .safe, "stderr redirect isn't a file write")
    #expect(CommandRisk.assess("grep -c foo *.txt >> counts.log") == .safe || CommandRisk.assess("grep -c foo *.txt >> counts.log") == .caution)
    #expect(CommandRisk.assess("sed -i '' 's/a/b/' file.txt") == .caution)
    #expect(CommandRisk.assess("echo hi > out.txt") == .caution)
    #expect(CommandRisk.assess("git commit -am wip") == .caution)
    #expect(CommandRisk.assess("rm -rf build") == .danger)
    #expect(CommandRisk.assess("find . -name '*.o' -delete") == .danger)
    #expect(CommandRisk.assess("find . -name '*.o' | xargs rm") == .danger)
    #expect(CommandRisk.assess("sudo lsof -i :80") == .danger)
    #expect(CommandRisk.assess("git push --force origin main") == .danger)
    #expect(CommandRisk.assess("curl -fsSL https://x.sh | sh") == .danger)
}

@Test func assistantEntryTakesTheHigherRiskAndAllowsAnswersWithoutCommands() {
    let understated = CommandAssistant.entry(from: ["command": "rm -rf node_modules", "explanation": "cleans", "risk": "safe"])
    #expect(understated.risk == .danger, "local check overrides a model that understates risk")
    #expect(understated.status == .proposed)
    let answer = CommandAssistant.entry(from: ["command": NSNull(), "explanation": "The build failed because…", "risk": "safe"])
    #expect(answer.command == nil && answer.risk == nil && answer.status == nil)
    let blank = CommandAssistant.entry(from: ["command": "  ", "explanation": "x", "risk": "safe"])
    #expect(blank.command == nil)
}

@Test func promptCarriesTerminalContextHistoryAndRequest() {
    let context = TerminalContext(cwd: "/tmp/proj", shell: "zsh", foregroundProgram: nil,
                                  recentOutput: "error: no such file", broadcastPaneCount: 1)
    let history = CommandAssistant.historySection([
        AssistantEntry(role: .user, text: "largest files"),
        AssistantEntry(role: .assistant, text: "sizes", command: "du -sh * | sort -h", risk: .safe, status: .ran),
        AssistantEntry(role: .note, text: "Cancelled."),
    ])
    #expect(history.contains("user: largest files"))
    #expect(history.contains("`du -sh * | sort -h` [ran]"))
    #expect(!history.contains("Cancelled"))
    let prompt = CommandAssistant.prompt(request: "only .swift", context: context, history: history)
    #expect(prompt.contains("cwd: /tmp/proj"))
    #expect(prompt.contains("shell: zsh"))
    #expect(prompt.contains("error: no such file"))
    #expect(prompt.contains("<request>\nonly .swift\n</request>"))
}

private func cliOutput(_ stdout: Data, status: Int32 = 0) -> LoginShellProcess.Output {
    LoginShellProcess.Output(status: status, stdout: stdout, stderr: Data())
}

@Test func claudeCLIParsesStructuredOutputAndErrors() throws {
    let structured = try JSONSerialization.data(withJSONObject: [
        "is_error": false, "result": "", "structured_output": ["command": "ls", "explanation": "list", "risk": "safe"],
    ])
    // Interactive shells may print a banner before the CLI's JSON line.
    let withBanner = Data("Welcome to zsh\n".utf8) + structured
    #expect(try ClaudeCLI.parse(cliOutput(withBanner)).get().command == "ls")

    let legacy = try JSONSerialization.data(withJSONObject: [
        "is_error": false, "result": #"{"command":"pwd","explanation":"here","risk":"safe"}"#,
    ])
    #expect(try ClaudeCLI.parse(cliOutput(legacy)).get().command == "pwd")

    let notLoggedIn = try JSONSerialization.data(withJSONObject: ["is_error": true, "result": "Not logged in · Please run /login"])
    guard case .failure(let failure) = ClaudeCLI.parse(cliOutput(notLoggedIn, status: 1)) else {
        Issue.record("expected failure"); return
    }
    #expect(failure.message.contains("claude auth login"))
    guard case .failure(.notInstalled) = ClaudeCLI.parse(cliOutput(Data(), status: 127)) else {
        Issue.record("exit 127 means the tool wasn't found"); return
    }
}

@Test func commandInputClearsLineAndUsesBracketedPaste() {
    #expect(TerminalHostView.commandInput("ls | wc -l", execute: true, bracketedPaste: false) == "\u{15}ls | wc -l\r")
    #expect(TerminalHostView.commandInput("ls", execute: false, bracketedPaste: true) == "\u{15}\u{1b}[200~ls\u{1b}[201~")
}

/// Backend double: returns a canned reply and records the request.
private final class StubTranslator: CommandTranslator, @unchecked Sendable {
    let result: Result<CommandReply, AssistantFailure>
    var onRequest: ((TranslationRequest) -> Void)?
    init(_ result: Result<CommandReply, AssistantFailure>) { self.result = result }
    func translate(_ request: TranslationRequest) async -> Result<CommandReply, AssistantFailure> {
        onRequest?(request)
        return result
    }
    func cancel() {}
}

@MainActor
private func stubbedAssistant(_ reply: [String: Any], provider: AssistantProvider = .claude) -> CommandAssistant {
    let assistant = CommandAssistant(provider: provider,
                                     defaults: UserDefaults(suiteName: "mooterm-assistant-\(UUID().uuidString)")!)
    let parsed = CommandReply(json: reply) ?? CommandReply(command: nil, explanation: "", risk: "safe")
    assistant.makeTranslator = { StubTranslator(.success(parsed)) }
    return assistant
}

private let haiku = AssistantOptions(model: "haiku")

private let sampleContext = TerminalContext(cwd: NSTemporaryDirectory(), shell: "zsh", foregroundProgram: nil,
                                            recentOutput: "", broadcastPaneCount: 1)

@MainActor
@Test func assistantAutoRunsOnlySafeCommandsWhenEnabled() async {
    let safe = stubbedAssistant(["command": "ls -la", "explanation": "list", "risk": "safe"])
    #expect(await safe.submit("list files", context: sampleContext, options: haiku) == nil, "auto-run is off by default")
    #expect(safe.entries.map(\.role) == [.user, .assistant])

    safe.autoRunSafe = true
    let auto = await safe.submit("list again", context: sampleContext, options: haiku)
    #expect(auto?.command == "ls -la")

    let risky = stubbedAssistant(["command": "rm -rf tmp", "explanation": "delete", "risk": "danger"])
    risky.autoRunSafe = true
    #expect(await risky.submit("delete tmp", context: sampleContext, options: haiku) == nil, "never auto-run danger")
}

@MainActor
@Test func bangPrefixRunsCommandVerbatimWithoutClaude() async {
    let assistant = stubbedAssistant([:])
    assistant.makeTranslator = {
        Issue.record("the model must not be called for !commands")
        return StubTranslator(.failure(.cancelled))
    }
    let entry = await assistant.submit("!git status -sb", context: sampleContext, options: haiku)
    #expect(entry?.command == "git status -sb")
    #expect(await assistant.submit("!rm -rf /tmp/x", context: sampleContext, options: haiku) == nil,
            "dangerous literal commands still wait for confirmation")
    #expect(assistant.run(UUID(), command: "ls", in: nil) == .noPane)
}

@MainActor
@Test func recentOutputReturnsTrimmedTail() {
    let host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    host.view.feed(text: (1...30).map { "row \($0)   " }.joined(separator: "\r\n"))
    let tail = host.recentOutput(lines: 3)
    #expect(tail == "row 28\nrow 29\nrow 30")
}

@Test func cliToolsRunByNameSoShellAliasesApply() {
    // Regression: exec'ing the binary by path skipped `alias claude='https_proxy=… claude'`
    // and the API answered "403 Request not allowed".
    let launch = LoginShellProcess.launch(tool: "claude", arguments: ["--print"])
    #expect(launch.arguments.prefix(3) == ["-l", "-i", "-c"])
    #expect(launch.arguments[3].contains(#"then claude "$@""#))
    #expect(launch.arguments.suffix(2) == ["mooterm-claude", "--print"])
    #expect(LoginShellProcess.launch(tool: "codex", arguments: []).arguments[3].contains(#"then codex "$@""#))
    #expect(AssistantFailure.failed("Failed to authenticate. API Error: 403 Request not allowed").message.contains("proxy"))
}

private func liveRequest(model: String, apiKey: String? = nil, baseURL: String? = nil) -> TranslationRequest {
    let context = TerminalContext(cwd: NSTemporaryDirectory(), shell: "zsh", foregroundProgram: nil,
                                  recentOutput: "", broadcastPaneCount: 1)
    return TranslationRequest(
        prompt: CommandAssistant.prompt(request: "count files in this directory, including hidden ones",
                                        context: context, history: ""),
        systemPrompt: CommandAssistant.systemPrompt, schema: CommandAssistant.schema, model: model,
        workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        environment: ProxyConfiguration.automatic()?.environment ?? [:],
        apiProxy: .system, apiKey: apiKey, baseURL: baseURL)
}

private func expectLiveReply(_ name: String, _ result: Result<CommandReply, AssistantFailure>) {
    guard case .success(let reply) = result else {
        Issue.record("\(name) failed: \(result)"); return
    }
    let entry = CommandAssistant.entry(from: reply)
    print("live \(name) →", entry.command ?? "nil", "|", entry.risk.map(\.rawValue) ?? "-", "|", entry.text)
    #expect(entry.command?.isEmpty == false)
}

/// Opt-in end-to-end checks against the real services. Strip proxy
/// variables to mimic a Dock-launched app, e.g.
/// `env -u http_proxy -u https_proxy MOOTERM_LIVE=claude,deepseek swift test --filter live`
private func liveEnabled(_ name: String) -> Bool {
    (ProcessInfo.processInfo.environment["MOOTERM_LIVE"] ?? "").split(separator: ",").contains { $0 == name }
}

@Test(.enabled(if: liveEnabled("claude")))
func liveClaudeTranslatesARequest() async {
    expectLiveReply("claude", await ClaudeCLI().translate(liveRequest(model: "haiku")))
}

@Test(.enabled(if: liveEnabled("codex")))
func liveCodexTranslatesARequest() async {
    expectLiveReply("codex", await CodexCLI().translate(liveRequest(model: "")))
}

@Test(.enabled(if: liveEnabled("deepseek")))
func liveDeepSeekTranslatesARequest() async {
    let client = AssistantProvider.deepseek.makeTranslator()
    let key = APIKeyStore.resolve(for: .deepseek)
    expectLiveReply("deepseek", await client.translate(liveRequest(
        model: AssistantProvider.deepseek.defaultModel, apiKey: key,
        baseURL: AssistantProvider.deepseek.baseURLChoices.first?.url)))
}

// MARK: - Proxy inheritance

@Test func systemProxySettingsBecomeProxyVariables() {
    // Shape of CFNetworkCopySystemProxySettings() with Clash-style settings.
    let settings: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7890,
        "ExceptionsList": ["*.local", "192.168.0.0/16"],
    ]
    let config = ProxyConfiguration.fromSystemSettings(settings)
    #expect(config?.https == "http://127.0.0.1:7890")
    #expect(config?.http == "http://127.0.0.1:7890")
    let env = config?.environment ?? [:]
    #expect(env["https_proxy"] == "http://127.0.0.1:7890")
    #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:7890")
    #expect(env["no_proxy"]?.contains(".local") == true)
    #expect(env["no_proxy"]?.contains("localhost") == true)

    let socksOnly: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": "10.0.0.2", "SOCKSPort": 1080]
    #expect(ProxyConfiguration.fromSystemSettings(socksOnly)?.all == "socks5://10.0.0.2:1080")
    #expect(ProxyConfiguration.fromSystemSettings(["HTTPEnable": 0, "HTTPProxy": "x"]) == nil)
}

@Test func explicitProxyVariablesWinOverSystemProxy() {
    let env = ["HTTPS_PROXY": "http://corp:3128", "PATH": "/bin"]
    #expect(ProxyConfiguration.automatic(environment: env)?.https == "http://corp:3128")
    #expect(ProxyConfiguration.fromEnvironment(["PATH": "/bin"]) == nil)
    #expect(ProxyConfiguration.custom("127.0.0.1:7890")?.https == "http://127.0.0.1:7890")
    #expect(ProxyConfiguration.custom("socks5://h:1")?.all == "socks5://h:1")
    #expect(ProxyConfiguration.custom("  ") == nil)
}

@MainActor
@Test func proxyPreferencesDriveClaudeAndPaneEnvironments() {
    let defaults = UserDefaults(suiteName: "mooterm-proxy-\(UUID().uuidString)")!
    let prefs = TerminalPreferences(defaults: defaults)
    #expect(prefs.proxyMode == .automatic)
    #expect(!prefs.proxyInPanes, "panes keep their own proxy setup by default")
    #expect(prefs.paneEnvironment.isEmpty)

    prefs.proxyMode = .custom
    prefs.customProxy = "http://127.0.0.1:7890"
    #expect(prefs.cliEnvironment["https_proxy"] == "http://127.0.0.1:7890")
    prefs.proxyInPanes = true
    #expect(prefs.paneEnvironment["http_proxy"] == "http://127.0.0.1:7890")

    prefs.proxyMode = .off
    #expect(prefs.cliEnvironment["https_proxy"] == "", "None clears inherited proxy variables")
    #expect(prefs.paneEnvironment.isEmpty)
    #expect(TerminalPreferences(defaults: defaults).proxyMode == .off)
}

@MainActor
@Test func assistantPassesOptionsToTheBackend() async {
    let assistant = CommandAssistant(provider: .deepseek,
                                     defaults: UserDefaults(suiteName: "mooterm-assistant-\(UUID().uuidString)")!)
    nonisolated(unsafe) var seen: TranslationRequest?
    assistant.makeTranslator = {
        let stub = StubTranslator(.success(CommandReply(command: "ls", explanation: "", risk: "safe")))
        stub.onRequest = { seen = $0 }
        return stub
    }
    var options = AssistantOptions(model: "deepseek-chat")
    options.environment = ["https_proxy": "http://127.0.0.1:7890"]
    options.baseURL = "https://api.deepseek.com"
    options.apiKey = { "sk-test" }
    _ = await assistant.submit("list", context: sampleContext, options: options)
    #expect(seen?.environment["https_proxy"] == "http://127.0.0.1:7890")
    #expect(seen?.model == "deepseek-chat")
    #expect(seen?.apiKey == "sk-test")
    #expect(seen?.baseURL == "https://api.deepseek.com")
}

// MARK: - Activity bar

@Test func activityBarStartsWithClaude() {
    #expect(SidebarItem.builtIns.first == .claude)
    let ids = SidebarItem.builtIns.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(SidebarItem(rawValue: "") == nil, "empty selection means the sidebar is closed")
}

// MARK: - Codex, DeepSeek, MiniMax

@Test func commandReplyParsesFencedOrReasoningWrappedJSON() {
    let fenced = CommandReply(text: "```json\n{\"command\":\"ls\",\"explanation\":\"x\",\"risk\":\"safe\"}\n```")
    #expect(fenced?.command == "ls")
    let thinking = CommandReply(text: "<think>maybe {not json}</think>\n{\"command\":null,\"explanation\":\"answer\",\"risk\":\"safe\"}")
    #expect(thinking?.command == nil && thinking?.explanation == "answer")
    #expect(CommandReply(text: "no json here") == nil)
}

@Test func chatCompletionsParsesRepliesAndErrors() throws {
    let ok = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": #"{"command":"pwd","explanation":"","risk":"safe"}"#]]]])
    let okResponse = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    #expect(try ChatCompletionsClient.parse(data: ok, response: okResponse, error: nil, provider: "DeepSeek").get().command == "pwd")

    let unauthorized = try JSONSerialization.data(withJSONObject: ["error": ["message": "Authentication Fails"]])
    let r401 = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)
    guard case .failure(let failure) = ChatCompletionsClient.parse(data: unauthorized, response: r401, error: nil, provider: "DeepSeek") else {
        Issue.record("expected 401 failure"); return
    }
    #expect(failure.message.contains("401") && failure.message.contains("Authentication Fails"))

    // MiniMax reports some errors as HTTP 200 with base_resp.
    let minimax = try JSONSerialization.data(withJSONObject: ["base_resp": ["status_code": 1004, "status_msg": "login fail"]])
    guard case .failure(let mm) = ChatCompletionsClient.parse(data: minimax, response: okResponse, error: nil, provider: "MiniMax") else {
        Issue.record("expected MiniMax failure"); return
    }
    #expect(mm.message.contains("1004"))
}

@Test func chatCompletionsRequestBodyAsksForJSON() {
    let request = TranslationRequest(prompt: "p", systemPrompt: "s", schema: "{}", model: "deepseek-chat",
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:],
                                     apiProxy: .system, apiKey: "k", baseURL: nil)
    let body = ChatCompletionsClient.body(for: request, jsonMode: true)
    #expect(body["model"] as? String == "deepseek-chat")
    #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
    #expect(ChatCompletionsClient.body(for: request, jsonMode: false)["response_format"] == nil)
}

@MainActor
@Test func apiProvidersWithoutAKeyExplainWhereToPutIt() async {
    let result = await ChatCompletionsClient(providerName: "MiniMax", keyVariable: "MINIMAX_API_KEY")
        .translate(TranslationRequest(prompt: "", systemPrompt: "", schema: "", model: "m",
                                      workingDirectory: URL(fileURLWithPath: "/"), environment: [:],
                                      apiProxy: .system, apiKey: nil, baseURL: "https://api.minimaxi.com/v1"))
    guard case .failure(let failure) = result else { Issue.record("expected missing key"); return }
    #expect(failure == .missingAPIKey(provider: "MiniMax", variable: "MINIMAX_API_KEY"))
    #expect(failure.message.contains("MINIMAX_API_KEY"))
}

@Test func codexRunsReadOnlyEphemeralWithSchema() {
    let request = TranslationRequest(prompt: "", systemPrompt: "", schema: "{}", model: "",
                                     workingDirectory: URL(fileURLWithPath: "/tmp/proj"), environment: [:],
                                     apiProxy: .system, apiKey: nil, baseURL: nil)
    let args = CodexCLI.arguments(for: request, schemaFile: URL(fileURLWithPath: "/s.json"),
                                  outputFile: URL(fileURLWithPath: "/o.txt"))
    #expect(args.first == "exec")
    #expect(args.contains("--ephemeral"))
    #expect(args.firstIndex(of: "--sandbox").map { args[$0 + 1] } == "read-only")
    #expect(args.firstIndex(of: "--output-schema").map { args[$0 + 1] } == "/s.json")
    #expect(args.firstIndex(of: "--cd").map { args[$0 + 1] } == "/tmp/proj")
    #expect(!args.contains("--model"), "empty model keeps Codex's configured default")
    #expect(args.last == "-")
}

@Test func apiKeysAreStoredPrivately() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mooterm-keys-\(UUID().uuidString)/credentials.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    APIKeyStore.save("  sk-abc  ", for: .deepseek, file: file)
    #expect(APIKeyStore.savedKey(for: .deepseek, file: file) == "sk-abc")
    #expect(APIKeyStore.savedKey(for: .minimax, file: file) == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    APIKeyStore.save("", for: .deepseek, file: file)
    #expect(APIKeyStore.savedKey(for: .deepseek, file: file) == nil)
}

@Test func loginShellVariableIgnoresBanners() {
    #expect(APIKeyStore.parseMarkedValue("HTTP proxy set\n\nMOOTERM_ENV_VALUE=sk-123\n") == "sk-123")
    #expect(APIKeyStore.parseMarkedValue("Welcome!\n\nMOOTERM_ENV_VALUE=\n") == nil, "unset variable, not the banner")
}

@MainActor
@Test func providerPreferencesHaveDefaultsAndMigrateClaudeModel() {
    let defaults = UserDefaults(suiteName: "mooterm-provider-\(UUID().uuidString)")!
    defaults.set("sonnet", forKey: TerminalPreferences.claudeModelKey)
    let prefs = TerminalPreferences(defaults: defaults)
    #expect(prefs.model(for: .claude) == "sonnet", "old single Claude model setting carries over")
    #expect(prefs.model(for: .deepseek) == "deepseek-chat")
    #expect(prefs.model(for: .codex) == "")
    #expect(prefs.baseURL(for: .minimax) == "https://api.minimaxi.com/v1")
    prefs.setModel("MiniMax-M3", for: .minimax)
    prefs.setBaseURL("https://api.minimax.io/v1", for: .minimax)
    let reloaded = TerminalPreferences(defaults: defaults)
    #expect(reloaded.model(for: .minimax) == "MiniMax-M3")
    #expect(reloaded.baseURL(for: .minimax) == "https://api.minimax.io/v1")
}

@MainActor
@Test func eachProviderKeepsItsOwnConversation() async {
    let defaults = UserDefaults(suiteName: "mooterm-hub-\(UUID().uuidString)")!
    let hub = AssistantHub(defaults: defaults)
    #expect(Set(hub.assistants.keys) == Set(SidebarItem.builtIns))
    _ = await hub[.codex].submit("!ls", context: sampleContext, options: haiku)
    #expect(hub[.codex].entries.count == 2)
    #expect(hub[.claude].entries.isEmpty)
    #expect(AssistantHub(defaults: defaults)[.codex].entries.count == 2, "persisted per provider")
}

@Test func activityBarHasAllAssistants() {
    #expect(SidebarItem.builtIns.map(\.rawValue) == ["claude", "codex", "deepseek", "minimax"])
    #expect(SidebarItem.builtIns.allSatisfy { $0.provider != nil })
}

// MARK: - Double-click

@Test func windowDoubleClickFollowsSystemSetting() {
    #expect(WindowDoubleClick.action(for: nil) == .zoom)
    #expect(WindowDoubleClick.action(for: "Maximize") == .zoom)
    #expect(WindowDoubleClick.action(for: "Minimize") == .minimize)
    #expect(WindowDoubleClick.action(for: "None") == .none)
}

@MainActor
@Test func doubleClickingAPaneHeaderTogglesMaximise() {
    let tab = TabSession()
    let a = tab.panes[0]
    tab.split(.vertical)
    tab.toggleMaximise(paneID: a.id)
    #expect(tab.zoomedPaneID == a.id && tab.activePaneID == a.id)
    #expect(!tab.zoomBumpsFont, "maximise keeps the font size")
    tab.toggleMaximise(paneID: a.id)
    #expect(tab.zoomedPaneID == nil)
}

@MainActor
@Test func zoomChangesAWindowBuiltLikeMooTerms() throws {
    try #require(NSScreen.main != nil, "needs a display")
    let content = Color.clear.frame(minWidth: 720, idealWidth: 900, maxWidth: .infinity,
                                    minHeight: 480, idealHeight: 600, maxHeight: .infinity)
    let hosting = NSHostingController(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.contentViewController = hosting
    window.setContentSize(NSSize(width: 900, height: 600))
    window.orderFront(nil)
    window.isReleasedWhenClosed = false  // ARC owns it; close() must not free it too
    defer { window.close() }
    let before = window.frame
    WindowDoubleClick.perform(on: window)
    print("zoom:", before, "→", window.frame, "zoomed:", window.isZoomed)
    #expect(window.frame != before)
}

@MainActor
private func sendDoubleClick(to window: NSWindow, at point: NSPoint) {
    for count in 1...2 {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: count, pressure: 1)!
            window.sendEvent(event)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
}

@MainActor
@Test func titleBarAreaDoubleClickReachesAppKit() throws {
    try #require(NSScreen.main != nil)
    nonisolated(unsafe) var fired = 0
    let view = HStack {
        Text("tab")
        TitleBarArea(onDoubleClick: { fired += 1 })
            .frame(minWidth: 4, maxWidth: .infinity, minHeight: 22, maxHeight: 22)
    }.frame(width: 400, height: 40)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 40),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: view)
    window.makeKeyAndOrderFront(nil)
    window.isReleasedWhenClosed = false  // ARC owns it; close() must not free it too
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    sendDoubleClick(to: window, at: NSPoint(x: 300, y: 20))
    #expect(fired == 1, "double-click on empty tab-bar space reaches the handler")
}

@MainActor
@Test func paneHeaderDoubleClickWorksOverItsLabels() throws {
    try #require(NSScreen.main != nil)
    nonisolated(unsafe) var doubles = 0
    nonisolated(unsafe) var singles = 0
    // Same shape as PaneView's header: labels and a button over the area.
    let view = HStack {
        Group {
            Image(systemName: "terminal")
            Text("chengmb@host")
        }
        .allowsHitTesting(false)  // as in PaneView: clicks fall through to the area
        Spacer()
        Button("x") {}
    }
    .frame(width: 400, height: 30)
    .background(TitleBarArea(onDoubleClick: { doubles += 1 }, onClick: { singles += 1 })
        .background(Color.gray.opacity(0.15)))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 30),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: view)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    sendDoubleClick(to: window, at: NSPoint(x: 200, y: 15))   // empty middle
    #expect(doubles == 1 && singles == 1)
    sendDoubleClick(to: window, at: NSPoint(x: 60, y: 15))    // over the title text
    #expect(doubles == 2, "labels don't swallow the double-click")
}

// MARK: - Rename (mTerm → mooTerm)

@Test func renameMigrationCarriesOldSettingsOver() {
    let migrated = RenameMigration.migratedKeys([
        "mTerm.fontSize": 18.0,
        "mTerm.colorScheme": "solarized-dark",
        "NSWindow Frame main": "ignored",
    ])
    #expect(migrated["mooTerm.fontSize"] as? Double == 18.0)
    #expect(migrated["mooTerm.colorScheme"] as? String == "solarized-dark")
    #expect(migrated.count == 2, "only the app's own keys move")
}

@Test func renameMigrationCopiesIntoAFreshStoreOnce() {
    // Throwaway domains only — never the real local.mterm.app settings.
    let oldDomain = "mooterm-test-old-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "mooterm-test-new-\(UUID().uuidString)")!
    defaults.setPersistentDomain(["mTerm.fontSize": 20.0], forName: oldDomain)
    defer { defaults.removePersistentDomain(forName: oldDomain) }
    RenameMigration.run(defaults: defaults, fromDomains: [oldDomain], moveFiles: false)
    #expect(defaults.double(forKey: "mooTerm.fontSize") == 20.0)
    #expect(defaults.bool(forKey: RenameMigration.doneKey))
    defaults.setPersistentDomain(["mTerm.fontSize": 9.0], forName: oldDomain)
    RenameMigration.run(defaults: defaults, fromDomains: [oldDomain], moveFiles: false)
    #expect(defaults.double(forKey: "mooTerm.fontSize") == 20.0, "runs once")
}

// MARK: - Custom assistants

@Test func sidebarItemsRoundTripForCustomAssistants() {
    let id = UUID()
    let item = SidebarItem(custom: id)
    #expect(item.customID == id && item.provider == nil)
    #expect(SidebarItem(rawValue: item.rawValue) == item)
    #expect(SidebarItem(rawValue: "custom:not-a-uuid") == nil)
    #expect(SidebarItem(rawValue: "kimi") == nil)
}

@Test func replyExtractionHandlesRealCLIOutput() {
    // opencode: JSON, then colour codes and a status line with no braces.
    let opencode = "{\"command\": \"ls -S | head -5\", \"explanation\": \"x\", \"risk\": \"safe\"}\n\u{1B}[0m\n> build · deepseek-v4-flash\n\u{1B}[0m"
    #expect(CommandReply.extract(from: opencode)?.command == "ls -S | head -5")
    // gemini/qwen -o json: an envelope whose "response" holds the answer.
    let envelope = #"{"response": "```json\n{\"command\": \"pwd\", \"explanation\": \"here\", \"risk\": \"safe\"}\n```", "stats": {"tokens": 12}}"#
    #expect(CommandReply.extract(from: envelope)?.command == "pwd")
    // Braces inside strings and a later unrelated object.
    let tricky = #"note {not json} then {"command": "awk '{print $1}' f", "explanation": "a } b", "risk": "safe"} and {"x": 1}"#
    #expect(CommandReply.extract(from: tricky)?.command == "awk '{print $1}' f")
    // No JSON: a fenced block becomes the command, rated for review.
    let fenced = "Try this:\n```sh\ndu -sh * | sort -h\n```"
    let reply = CommandReply.extract(from: fenced)
    #expect(reply?.command == "du -sh * | sort -h" && reply?.risk == "caution")
    #expect(CommandReply.extract(from: "LLM not set") == nil)
}

@MainActor
@Test func customAssistantsPersistAndKeepTheirKeysSeparate() {
    let defaults = UserDefaults(suiteName: "mooterm-custom-\(UUID().uuidString)")!
    let store = CustomAssistantStore(defaults: defaults)
    let kimi = store.add(CustomAssistant.presets[0].make())
    #expect(kimi.name == "Kimi" && kimi.kind == .openAICompatible)
    var edited = kimi
    edited.model = "kimi-k2-0905-preview"
    store.update(edited)
    let reloaded = CustomAssistantStore(defaults: defaults)
    #expect(reloaded.assistants.map(\.model) == ["kimi-k2-0905-preview"])
    #expect(kimi.keyAccount == "custom.\(kimi.id.uuidString)")
    reloaded.remove(id: kimi.id)
    #expect(CustomAssistantStore(defaults: defaults).assistants.isEmpty)
}

@MainActor
@Test func customAssistantsAppearAfterBuiltInsWithTheirOptions() {
    let defaults = UserDefaults(suiteName: "mooterm-custom-\(UUID().uuidString)")!
    let store = CustomAssistantStore(defaults: defaults)
    let prefs = TerminalPreferences(defaults: defaults)
    let qwen = store.add(CustomAssistant.presets[1].make())
    let cli = store.add(CustomAssistant(name: "my tool", kind: .command, command: "mytool --json"))
    let descriptors = AssistantDescriptor.all(store: store, preferences: prefs)
    #expect(descriptors.map(\.title) == ["Claude", "Codex", "DeepSeek", "MiniMax", "Qwen", "my tool"])
    #expect(descriptors.last?.letter == "M" && descriptors.last?.modelLabel == "mytool")

    let options = assistantOptions(for: SidebarItem(custom: qwen.id), preferences: prefs, store: store)
    #expect(options.baseURL == "https://dashscope.aliyuncs.com/compatible-mode/v1")
    #expect(options.model == "qwen-plus")
    #expect(options.apiKey != nil)
    #expect(assistantOptions(for: SidebarItem(custom: cli.id), preferences: prefs, store: store).apiKey == nil)

    let hub = AssistantHub(defaults: defaults)
    let a = hub.assistant(for: SidebarItem(custom: qwen.id), store: store)
    #expect(a === hub.assistant(for: SidebarItem(custom: qwen.id), store: store))
    #expect(a.storageID == "custom.\(qwen.id.uuidString)")
}

private func sampleRequest() -> TranslationRequest {
    TranslationRequest(prompt: "<request>list files</request>", systemPrompt: "SYSTEM", schema: "{}", model: "m1",
                       workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:],
                       apiProxy: .system, apiKey: nil, baseURL: nil)
}

@Test func customCommandGetsThePromptAndItsAnswerIsParsed() async throws {
    // A stand-in "CLI": checks stdin and $MOOTERM_PROMPT carry the prompt,
    // then answers with JSON after some noise.
    let script = #"input=$(cat); case "$input$MOOTERM_PROMPT" in *SYSTEM*list*SYSTEM*list*) ok=yes;; *) ok=no;; esac; echo "banner {"; printf '{"command":"ls -la","explanation":"%s %s","risk":"safe"}\n' "$ok" "$MOOTERM_MODEL""#
    let reply = try await CustomCommandTranslator(command: script).translate(sampleRequest()).get()
    #expect(reply.command == "ls -la")
    #expect(reply.explanation == "yes m1", "prompt on stdin and in $MOOTERM_PROMPT; model in $MOOTERM_MODEL")
}

@Test func customCommandFailuresAreReadable() async {
    let missing = await CustomCommandTranslator(command: "definitely-not-a-real-tool-xyz -p hi").translate(sampleRequest())
    guard case .failure(let failure) = missing else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("definitely-not-a-real-tool-xyz"))
    let silent = await CustomCommandTranslator(command: "echo 'LLM not set' >&2; exit 1").translate(sampleRequest())
    guard case .failure(let other) = silent else { Issue.record("expected failure"); return }
    #expect(other.message.contains("LLM not set"))
    let empty = await CustomCommandTranslator(command: "  ").translate(sampleRequest())
    guard case .failure(let none) = empty else { Issue.record("expected failure"); return }
    #expect(none.message.contains("no command"))
}

@Test func localServersNeedNoKey() {
    let ollama = CustomAssistant.presets.first { $0.label.hasPrefix("Ollama") }!.make()
    #expect(ollama.apiKeyVariable.isEmpty)
    let client = ollama.makeTranslator() as? ChatCompletionsClient
    #expect(client?.requiresKey == false)
    let kimi = CustomAssistant.presets[0].make().makeTranslator() as? ChatCompletionsClient
    #expect(kimi?.requiresKey == true)
}

@Test(.enabled(if: liveEnabled("opencode")))
func liveOpencodePresetTranslatesARequest() async {
    let preset = CustomAssistant.presets.first { $0.label == "opencode" }!.make()
    expectLiveReply("opencode", await preset.makeTranslator().translate(liveRequest(model: "")))
}

// MARK: - Closing a split keeps the survivor's terminal on screen

@MainActor
private func renderTab(_ tab: TabSession, store: SessionStore) -> NSWindow {
    let defaults = UserDefaults(suiteName: "mooterm-render-\(UUID().uuidString)")!
    let view = TabContentView(tab: tab)
        .environmentObject(store)
        .environmentObject(ColorSchemeStore(defaults: defaults))
        .environmentObject(FontSizeStore(defaults: defaults))
        .environmentObject(TerminalPreferences(defaults: defaults))
        .frame(width: 800, height: 500)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: view)
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    return window
}

@MainActor
private func expectOnScreen(_ pane: Pane, in window: NSWindow, _ label: String) {
    let view = pane.host?.view
    #expect(view?.window === window, "\(label): terminal view is in the window")
    let size = view?.frame.size ?? .zero
    #expect(size.width > 100 && size.height > 100, "\(label): terminal has a real size, got \(size)")
}

@MainActor
@Test(arguments: [SplitDirection.vertical, .horizontal], [false, true])
func closingASplitKeepsTheOtherTerminalVisible(direction: SplitDirection, closeOriginal: Bool) {
    let store = SessionStore()
    let tab = store.activeTab!
    let window = renderTab(tab, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    let original = tab.panes[0]
    expectOnScreen(original, in: window, "before split")

    tab.split(direction)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let added = tab.activePane!
    expectOnScreen(original, in: window, "original after split")
    expectOnScreen(added, in: window, "new pane after split")

    let (closing, survivor) = closeOriginal ? (original, added) : (added, original)
    tab.closePane(closing.id)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    expectOnScreen(survivor, in: window, "survivor after close")
}

@MainActor
@Test func terminalsSurviveZoomAndNestedClose() {
    let store = SessionStore()
    let tab = store.activeTab!
    let window = renderTab(tab, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    // [a | (b over c)]
    let a = tab.panes[0]
    tab.split(.vertical); settle()
    let b = tab.activePane!
    tab.split(.horizontal); settle()
    let c = tab.activePane!
    let views = [a, b, c].map { $0.host?.view }

    tab.toggleMaximise(paneID: b.id); settle()
    expectOnScreen(b, in: window, "zoomed pane")
    tab.toggleMaximise(paneID: b.id); settle()
    for (pane, name) in [(a, "a"), (b, "b"), (c, "c")] { expectOnScreen(pane, in: window, "\(name) after unzoom") }

    tab.closePane(b.id); settle()
    expectOnScreen(a, in: window, "a after closing nested b")
    expectOnScreen(c, in: window, "c after closing nested b")
    #expect([a, c].map { $0.host?.view } == [views[0], views[2]], "same terminals (and shells), not new ones")
}

@MainActor
private func sharedStores(_ defaults: UserDefaults) -> SharedStores {
    SharedStores(schemeStore: ColorSchemeStore(defaults: defaults), fontSizeStore: FontSizeStore(defaults: defaults),
                 layoutStore: LayoutStore(), windowStore: WindowStore(defaults: defaults),
                 preferences: TerminalPreferences(defaults: defaults), assistantHub: AssistantHub(defaults: defaults),
                 customStore: CustomAssistantStore(defaults: defaults))
}

/// The app's real window, built by the same controller the app uses.
@MainActor
private func makeAppWindow(defaults: UserDefaults, store: SessionStore) -> NSWindow {
    let controller = MooTermWindowController(sessionStore: store, shared: sharedStores(defaults),
                                             windowState: WindowState(sidebarSelection: ""))
    liveControllers.append(controller)
    controller.show(cascadingFrom: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    return controller.window
}

/// Keeps test window controllers alive while their windows are open.
@MainActor private var liveControllers: [MooTermWindowController] = []

@MainActor
@Test func realAppWindowZoomsFromTheTabBar() throws {
    try #require(NSScreen.main != nil)
    let defaults = UserDefaults(suiteName: "mooterm-appwin-\(UUID().uuidString)")!
    let store = SessionStore()
    let window = makeAppWindow(defaults: defaults, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    print("appwin frame", window.frame, "contentMax", window.contentMaxSize, "max", window.maxSize,
          "zoomable", window.isZoomable, "screen", window.screen?.visibleFrame ?? .zero)

    // 1. Zoom itself (what the real title bar's double-click does).
    let before = window.frame
    window.zoom(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("appwin after zoom(nil)", window.frame)
    #expect(window.frame.width > before.width + 100 && window.frame.height > before.height + 100,
            "zoom grows the real window, not just moves it")
    window.zoom(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    // 2. Double-click on empty tab-bar space.
    let area = try #require(findView(TitleBarAreaView.self, in: window.contentView!), "tab-bar double-click area exists")
    let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
    let beforeClick = window.frame
    sendDoubleClick(to: window, at: point)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("appwin after double-click", window.frame)
    #expect(window.frame.width > beforeClick.width + 100, "double-clicking empty tab-bar space zooms the window")
}

@MainActor
private func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
    if let match = root as? T { return match }
    for sub in root.subviews { if let found = findView(type, in: sub) { return found } }
    return nil
}

// MARK: - Per-pane font size

@MainActor
@Test func paneFontSizeIsRelativeAndClamped() {
    let pane = Pane(cwd: NSTemporaryDirectory())
    pane.adjustFontSize(by: 1, globalSize: 13)
    pane.adjustFontSize(by: 1, globalSize: 13)
    #expect(pane.fontSizeOffset == 2)
    let fonts = FontSizeStore(defaults: UserDefaults(suiteName: "mooterm-pfs-\(UUID().uuidString)")!)
    #expect(fonts.size(forOffset: pane.fontSizeOffset) == 15)
    fonts.increase()   // ⌥⌘=: the default moves, the pane keeps its +2
    #expect(fonts.size(forOffset: pane.fontSizeOffset) == 16)
    for _ in 0..<100 { pane.adjustFontSize(by: 1, globalSize: fonts.size) }
    #expect(fonts.size(forOffset: pane.fontSizeOffset) == FontSizeStore.maxSize, "clamped at the maximum")
    for _ in 0..<100 { pane.adjustFontSize(by: -1, globalSize: fonts.size) }
    #expect(fonts.size(forOffset: pane.fontSizeOffset) == FontSizeStore.minSize, "clamped at the minimum")
}

@MainActor
@Test func onlyTheAdjustedPaneChangesSize() {
    let store = SessionStore()
    let tab = store.activeTab!
    let window = renderTab(tab, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
    let left = tab.panes[0]
    tab.split(.vertical); settle()
    let right = tab.activePane!
    let before = left.host!.view.font.pointSize
    #expect(right.host!.view.font.pointSize == before)

    right.adjustFontSize(by: 3, globalSize: FontSizeStore.default); settle()
    #expect(right.host!.view.font.pointSize == before + 3, "active pane grew")
    #expect(left.host!.view.font.pointSize == before, "other pane unchanged")

    right.fontSizeOffset = 0; settle()   // ⌘0
    #expect(right.host!.view.font.pointSize == before)
}

@MainActor
@Test func savedLayoutsKeepPaneFontSizes() {
    let session = SessionStore()
    let tab = session.activeTab!
    tab.split(.vertical)
    tab.activePane!.fontSizeOffset = 4
    let saved = LayoutStore.snapshot(of: session, name: "fonts")
    let fresh = SessionStore()
    LayoutStore().restore(saved, into: fresh)
    #expect(fresh.activeTab!.panes.map(\.fontSizeOffset).sorted() == [0, 4])
    fresh.tabs.forEach { $0.terminate() }
}

// MARK: - Multiple windows

@MainActor
private func openTestWindow(_ store: SessionStore, _ defaults: UserDefaults, sidebar: String = "") -> MooTermWindowController {
    let controller = MooTermWindowController(sessionStore: store, shared: sharedStores(defaults),
                                             windowState: WindowState(sidebarSelection: sidebar))
    liveControllers.append(controller)
    controller.show(cascadingFrom: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    return controller
}

@MainActor
@Test func windowsHaveSeparateTabsAndSidebars() throws {
    try #require(NSScreen.main != nil)
    let defaults = UserDefaults(suiteName: "mooterm-win-\(UUID().uuidString)")!
    let one = openTestWindow(SessionStore(cwd: "/tmp"), defaults, sidebar: "claude")
    let two = openTestWindow(SessionStore(cwd: "/usr"), defaults)
    defer { one.window.close(); two.window.close() }
    one.sessionStore.newTab()
    #expect(one.sessionStore.tabs.count == 2 && two.sessionStore.tabs.count == 1)
    #expect(two.sessionStore.activeTab?.activePane?.cwd == "/usr", "new window starts in the given directory")
    #expect(one.windowState.selectedItem == .claude && two.windowState.selectedItem == nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    #expect(two.window.title == "usr — mooTerm", "title follows the active tab")
}

@MainActor
@Test func closingTheLastTabClosesTheWindowAndEndsShells() throws {
    try #require(NSScreen.main != nil)
    let defaults = UserDefaults(suiteName: "mooterm-win-\(UUID().uuidString)")!
    let controller = openTestWindow(SessionStore(), defaults)
    nonisolated(unsafe) var closed = false
    controller.onClose = { _ in closed = true }
    let pane = controller.sessionStore.activeTab!.panes[0]
    #expect(pane.host != nil, "window shows a live terminal")
    controller.sessionStore.closeActiveTab()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    #expect(closed, "window closed with its last tab")
    #expect(!controller.window.isVisible)
    #expect(pane.host == nil, "shell ended")
}

@MainActor
@Test func movingATabToANewWindowKeepsItsShells() throws {
    try #require(NSScreen.main != nil)
    let defaults = UserDefaults(suiteName: "mooterm-win-\(UUID().uuidString)")!
    let source = openTestWindow(SessionStore(), defaults)
    source.sessionStore.newTab()
    let moving = source.sessionStore.activeTab!
    moving.split(.vertical)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let terminals = moving.panes.map { $0.host?.view }
    #expect(terminals.allSatisfy { $0 != nil })

    let tab = try #require(source.sessionStore.detachTab(moving.id))
    let target = openTestWindow(SessionStore(adopting: tab), defaults)
    defer { source.window.close(); target.window.close() }
    #expect(source.sessionStore.tabs.count == 1)
    #expect(target.sessionStore.activeTab === moving)
    #expect(moving.panes.map { $0.host?.view } == terminals, "same terminals, shells still running")
    for pane in moving.panes {
        #expect(pane.host?.view.window === target.window, "terminal now shows in the new window")
    }
    #expect(source.sessionStore.detachTab(source.sessionStore.activeTabID) == nil, "a window's only tab can't be moved out")
}

// MARK: - Copy on select

@MainActor
@Test func selectingTextCopiesIt() throws {
    try #require(NSScreen.main != nil)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mooterm-test-\(UUID().uuidString)"))
    MooTermTerminalView.selectionPasteboard = pasteboard
    defer { MooTermTerminalView.selectionPasteboard = .general; pasteboard.releaseGlobally() }

    let view = MooTermTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    view.feed(text: "hello copy on select\r\n")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    func send(_ type: NSEvent.EventType, x: CGFloat, clicks: Int) {
        let point = view.convert(NSPoint(x: x, y: view.frame.height - 8), to: nil)  // first row
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        window.sendEvent(event)
    }

    // Double-click a word: SwiftTerm selects it, releasing copies it.
    send(.leftMouseDown, x: 60, clicks: 2)
    send(.leftMouseUp, x: 60, clicks: 2)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    #expect(pasteboard.string(forType: .string) == "copy", "double-clicked word copied")

    // Any finished selection is copied when the mouse is released.
    view.selectAll()
    send(.leftMouseUp, x: 200, clicks: 1)
    #expect(pasteboard.string(forType: .string) == "hello copy on select")

    // Turned off: nothing is copied.
    pasteboard.clearContents()
    #expect(!view.copySelectionIfEnabled(pasteboard: pasteboard, enabled: false))
    #expect(pasteboard.string(forType: .string) == nil)
}

@MainActor
@Test func copyingShowsAToastThatFades() async throws {
    try #require(NSScreen.main != nil)
    #expect(Pane.CopyToast(characters: 1).message == "Copied 1 character")
    let many = Pane.CopyToast(characters: 1234).message
    #expect(many.hasPrefix("Copied 1") && many.hasSuffix("234 characters"), "grouped number, plural: \(many)")

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mooterm-toast-\(UUID().uuidString)"))
    MooTermTerminalView.selectionPasteboard = pasteboard
    defer { MooTermTerminalView.selectionPasteboard = .general; pasteboard.releaseGlobally() }

    let store = SessionStore()
    let tab = store.activeTab!
    let window = renderTab(tab, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    let pane = tab.panes[0]
    let view = try #require(pane.host?.view)
    view.feed(text: "\u{1b}[2J\u{1b}[Hcopy me please")
    view.selectAll()
    #expect(view.copySelectionIfEnabled(pasteboard: pasteboard, enabled: true))
    let copied = pasteboard.string(forType: .string) ?? ""
    #expect(pane.copyToast?.characters == copied.count, "toast counts what was copied (\(copied.count))")
    // Other tests can hold the main actor for seconds when run in parallel.
    // Count retries rather than watching the clock: each sleep re-queues
    // this check behind the toast's own (already due) fade-out job.
    for _ in 0..<60 where pane.copyToast != nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(pane.copyToast == nil, "toast fades away")
}

// MARK: - Scrollbar

@MainActor
private func scrollbarWindow(_ mode: MooTermTerminalView.ScrollbarMode) -> (MooTermTerminalView, NSWindow) {
    let view = MooTermTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFront(nil)
    view.setScrollbarMode(mode)
    view.getTerminal().changeScrollback(1000)
    view.feed(text: (1...300).map { "line \($0)" }.joined(separator: "\r\n"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    return (view, window)
}

@MainActor
@Test func scrollbarIsVisibleByDefault() throws {
    try #require(NSScreen.main != nil)
    #expect(TerminalPreferences(defaults: UserDefaults(suiteName: "mooterm-sb-\(UUID().uuidString)")!).scrollbarMode == .always)
    let (view, window) = scrollbarWindow(.always)
    defer { window.close() }
    let scroller = try #require(view.scrollerView)
    #expect(scroller.scrollerStyle == .legacy, "classic scroller: overlay never drew its knob")
    #expect(!scroller.isHidden && scroller.alphaValue == 1)
    #expect(scroller.isEnabled, "there is history to scroll")
    view.scrollUp(lines: 50)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    if let dir = ProcessInfo.processInfo.environment["MOOTERM_PROBE_DIR"],
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("scrollbar-always.png"))
    }
}

@MainActor
@Test func neverModeGivesTheWidthBackToText() throws {
    try #require(NSScreen.main != nil)
    let (shown, w1) = scrollbarWindow(.always)
    let (hidden, w2) = scrollbarWindow(.never)
    defer { w1.close(); w2.close() }
    #expect(hidden.scrollerView?.isHidden == true)
    #expect(hidden.getTerminal().cols > shown.getTerminal().cols, "\(hidden.getTerminal().cols) vs \(shown.getTerminal().cols) columns")
}

@MainActor
@Test func whileScrollingShowsThenFades() async throws {
    try #require(NSScreen.main != nil)
    let (view, window) = scrollbarWindow(.whileScrolling)
    defer { window.close() }
    let scroller = try #require(view.scrollerView)
    #expect(scroller.alphaValue == 0, "hidden until you scroll")
    view.feed(text: "\r\nmore output\r\n")   // following output isn't user scrolling
    #expect(scroller.alphaValue == 0)
    view.scrollUp(lines: 20)
    #expect(scroller.alphaValue == 1, "appears when scrolled into history")
    for _ in 0..<60 where scroller.alphaValue > 0.01 {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(scroller.alphaValue < 0.01, "fades out after scrolling stops")
}

@MainActor
@Test func scrollbarMatchesTheThemeBrightness() {
    let host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    host.view.setScrollbarMode(.always)
    host.applyScheme(.solarizedLight)
    #expect(host.view.scrollerView?.appearance?.name == .aqua)
    host.applyScheme(.tomorrowNight)
    #expect(host.view.scrollerView?.appearance?.name == .darkAqua)
}

// MARK: - Text margins

@MainActor
@Test func terminalTextHasMarginsInsideThePane() throws {
    try #require(NSScreen.main != nil)
    let store = SessionStore()
    let tab = store.activeTab!
    let window = renderTab(tab, store: store)
    defer { window.close(); store.tabs.forEach { $0.terminate() } }
    let view = try #require(tab.panes[0].host?.view)
    let container = try #require(view.superview as? TerminalContainerView)
    let m = TerminalPreferences.defaultTextMargin
    #expect(view.frame.minX == m, "left margin")
    #expect(view.frame.minY == m / 2 && container.bounds.maxY - view.frame.maxY == m / 2, "top and bottom margins")
    #expect(container.bounds.maxX - view.frame.maxX == 0, "scrollbar stays at the pane's right edge")

    // Resizing keeps the margins.
    container.setFrameSize(NSSize(width: container.frame.width - 100, height: container.frame.height - 50))
    #expect(view.frame.minX == m && container.bounds.maxX - view.frame.maxX == 0)
    #expect(container.bounds.maxY - view.frame.maxY == m / 2)
}

@Test func marginsFollowTheScrollbarSetting() {
    let shown = TerminalContainerView.Margins.forText(margin: 8, scrollbar: .always)
    #expect(shown == .init(left: 8, right: 0, top: 4, bottom: 4))
    let none = TerminalContainerView.Margins.forText(margin: 8, scrollbar: .never)
    #expect(none.right == 8, "no scrollbar: text gets a right margin too")
    #expect(TerminalContainerView.Margins.forText(margin: 0, scrollbar: .always) == .init())
}
