import Testing
import AppKit
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

@Test func claudeCLIParsesStructuredOutputAndErrors() throws {
    let structured = try JSONSerialization.data(withJSONObject: [
        "is_error": false, "result": "", "structured_output": ["command": "ls", "explanation": "list", "risk": "safe"],
    ])
    // Interactive shells may print a banner before the CLI's JSON line.
    let withBanner = Data("Welcome to zsh\n".utf8) + structured
    guard case .success(let object) = ClaudeCLI.parse(output: withBanner, errorOutput: Data(), status: 0) else {
        Issue.record("expected success"); return
    }
    #expect(object["command"] as? String == "ls")

    let legacy = try JSONSerialization.data(withJSONObject: [
        "is_error": false, "result": #"{"command":"pwd","explanation":"here","risk":"safe"}"#,
    ])
    guard case .success(let legacyObject) = ClaudeCLI.parse(output: legacy, errorOutput: Data(), status: 0) else {
        Issue.record("expected success from result text"); return
    }
    #expect(legacyObject["command"] as? String == "pwd")

    let notLoggedIn = try JSONSerialization.data(withJSONObject: ["is_error": true, "result": "Not logged in · Please run /login"])
    guard case .failure(let failure) = ClaudeCLI.parse(output: notLoggedIn, errorOutput: Data(), status: 1) else {
        Issue.record("expected failure"); return
    }
    #expect(failure.message.contains("claude auth login"))
}

@Test func commandInputClearsLineAndUsesBracketedPaste() {
    #expect(TerminalHostView.commandInput("ls | wc -l", execute: true, bracketedPaste: false) == "\u{15}ls | wc -l\r")
    #expect(TerminalHostView.commandInput("ls", execute: false, bracketedPaste: true) == "\u{15}\u{1b}[200~ls\u{1b}[201~")
}

@MainActor
private func stubbedAssistant(_ reply: [String: Any]) -> CommandAssistant {
    let assistant = CommandAssistant(defaults: UserDefaults(suiteName: "mterm-assistant-\(UUID().uuidString)")!)
    nonisolated(unsafe) let reply = reply
    assistant.translate = { _, _, _, _ in .success(reply) }
    return assistant
}

private let sampleContext = TerminalContext(cwd: NSTemporaryDirectory(), shell: "zsh", foregroundProgram: nil,
                                            recentOutput: "", broadcastPaneCount: 1)

@MainActor
@Test func assistantAutoRunsOnlySafeCommandsWhenEnabled() async {
    let safe = stubbedAssistant(["command": "ls -la", "explanation": "list", "risk": "safe"])
    #expect(await safe.submit("list files", context: sampleContext, model: "haiku") == nil, "auto-run is off by default")
    #expect(safe.entries.map(\.role) == [.user, .assistant])

    safe.autoRunSafe = true
    let auto = await safe.submit("list again", context: sampleContext, model: "haiku")
    #expect(auto?.command == "ls -la")

    let risky = stubbedAssistant(["command": "rm -rf tmp", "explanation": "delete", "risk": "danger"])
    risky.autoRunSafe = true
    #expect(await risky.submit("delete tmp", context: sampleContext, model: "haiku") == nil, "never auto-run danger")
}

@MainActor
@Test func bangPrefixRunsCommandVerbatimWithoutClaude() async {
    let assistant = stubbedAssistant([:])
    assistant.translate = { _, _, _, _ in
        Issue.record("Claude must not be called for !commands")
        return .failure(.cancelled)
    }
    let entry = await assistant.submit("!git status -sb", context: sampleContext, model: "")
    #expect(entry?.command == "git status -sb")
    #expect(await assistant.submit("!rm -rf /tmp/x", context: sampleContext, model: "") == nil,
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

@Test func claudeRunsByNameSoShellAliasesApply() {
    // Regression: exec'ing the binary by path skipped `alias claude='https_proxy=… claude'`
    // and the API answered "403 Request not allowed".
    let launch = ClaudeCLI.loginShellLaunch(arguments: ["--print"])
    #expect(launch.arguments.prefix(3) == ["-l", "-i", "-c"])
    #expect(launch.arguments[3].contains(#"then claude "$@""#))
    #expect(launch.arguments.suffix(2) == ["mterm-claude", "--print"])
    #expect(ClaudeCLI.Failure.failed("Failed to authenticate. API Error: 403 Request not allowed").message.contains("proxy"))
}

/// Opt-in end-to-end check against the installed Claude Code CLI. Strip the
/// proxy variables to mimic a Dock-launched app:
/// `env -u http_proxy -u https_proxy MTERM_LIVE_CLAUDE=1 swift test --filter liveClaude`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MTERM_LIVE_CLAUDE"] == "1"))
func liveClaudeTranslatesARequest() throws {
    let context = TerminalContext(cwd: NSTemporaryDirectory(), shell: "zsh", foregroundProgram: nil,
                                  recentOutput: "", broadcastPaneCount: 1)
    let prompt = CommandAssistant.prompt(request: "count files in this directory, including hidden ones",
                                         context: context, history: "")
    let result = ClaudeCLI().run(prompt: prompt, systemPrompt: CommandAssistant.systemPrompt,
                                 schema: CommandAssistant.schema, model: "haiku",
                                 workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    guard case .success(let object) = result else {
        Issue.record("CLI failed: \(result)"); return
    }
    let entry = CommandAssistant.entry(from: object)
    print("live claude →", entry.command ?? "nil", "|", entry.risk.map(\.rawValue) ?? "-", "|", entry.text)
    #expect(entry.command?.isEmpty == false)
    #expect(entry.risk == .safe)
}
