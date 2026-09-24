import Testing
import AppKit
import SwiftUI
@testable import mterm

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
    let defaults = UserDefaults(suiteName: "mterm-test-\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "mterm-font-test-\(UUID().uuidString)")!
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
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mTermLayoutTest-\(UUID().uuidString)")
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
    #expect(first === second)
    pane.terminate()
    #expect(pane.host == nil)
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
    let view = MTermTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
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
    let defaults = UserDefaults(suiteName: "mterm-prefs-test-\(UUID().uuidString)")!
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
                                     defaults: UserDefaults(suiteName: "mterm-assistant-\(UUID().uuidString)")!)
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
    #expect(launch.arguments.suffix(2) == ["mterm-claude", "--print"])
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
/// `env -u http_proxy -u https_proxy MTERM_LIVE=claude,deepseek swift test --filter live`
private func liveEnabled(_ name: String) -> Bool {
    (ProcessInfo.processInfo.environment["MTERM_LIVE"] ?? "").split(separator: ",").contains { $0 == name }
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
    let defaults = UserDefaults(suiteName: "mterm-proxy-\(UUID().uuidString)")!
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
                                     defaults: UserDefaults(suiteName: "mterm-assistant-\(UUID().uuidString)")!)
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
    #expect(SidebarItem.allCases.first == .claude)
    let ids = SidebarItem.allCases.map(\.id)
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
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mterm-keys-\(UUID().uuidString)/credentials.json")
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
    #expect(APIKeyStore.parseMarkedValue("HTTP proxy set\n\nMTERM_ENV_VALUE=sk-123\n") == "sk-123")
    #expect(APIKeyStore.parseMarkedValue("Welcome!\n\nMTERM_ENV_VALUE=\n") == nil, "unset variable, not the banner")
}

@MainActor
@Test func providerPreferencesHaveDefaultsAndMigrateClaudeModel() {
    let defaults = UserDefaults(suiteName: "mterm-provider-\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "mterm-hub-\(UUID().uuidString)")!
    let hub = AssistantHub(defaults: defaults)
    #expect(Set(hub.assistants.keys) == Set(AssistantProvider.allCases))
    _ = await hub[.codex].submit("!ls", context: sampleContext, options: haiku)
    #expect(hub[.codex].entries.count == 2)
    #expect(hub[.claude].entries.isEmpty)
    #expect(AssistantHub(defaults: defaults)[.codex].entries.count == 2, "persisted per provider")
}

@Test func activityBarHasAllAssistants() {
    #expect(SidebarItem.allCases.map(\.rawValue) == ["claude", "codex", "deepseek", "minimax"])
    #expect(SidebarItem.allCases.allSatisfy { $0.provider != nil })
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
@Test func zoomChangesAWindowBuiltLikeMTerms() throws {
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
