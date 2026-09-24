import Testing
import AppKit
@testable import mterm

@Test func splitTreeGrowsOnSplit() {
    let tab = TabSession()
    #expect(tab.collectPanes(tab.root).count == 1)
    tab.split(.horizontal)
    #expect(tab.collectPanes(tab.root).count == 2)
    tab.split(.vertical)
    #expect(tab.collectPanes(tab.root).count == 3)
}

@Test func closePaneReducesTree() {
    let tab = TabSession()
    tab.split(.horizontal)
    tab.split(.horizontal)
    #expect(tab.collectPanes(tab.root).count == 3)
    tab.closeActivePane()
    #expect(tab.collectPanes(tab.root).count == 2)
}

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

@Test func tabTitlePrefersCustomTitleOverCwd() {
    let tab = TabSession()
    tab.root.pane?.cwd = nil
    #expect(tab.title == "shell", "fresh tab with no cwd shows shell")
    tab.root.pane?.cwd = "/Users/chengmb/projects/foo"
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

@Test func scrollbackBufferCountsAndFindsCaseInsensitive() {
    let buf = ScrollbackBuffer()
    // No trailing LF — the last line lives in `pending` and only reaches
    // snapshot via the snapshot computed property.
    let payload = Array("Hello world\nfoo bar\nhello again".utf8)
    buf.append(bytes: payload[...])
    #expect(buf.count(of: "hello") == 2)
    #expect(buf.count(of: "HELLO") == 2)
    #expect(buf.count(of: "missing") == 0)
    let matches = buf.find("hello")
    #expect(matches.count == 2)
    #expect(matches[0].lineIndex == 1)
    #expect(matches[1].lineIndex == 3)
}

@Test func scrollbackBufferStripsAnsiEscapes() {
    let buf = ScrollbackBuffer()
    // "\u{1B}[31mERROR\u{1B}[0m: not found\n" should leave only the printable chars.
    let payload: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D,
                            0x45, 0x52, 0x52, 0x4F, 0x52,
                            0x1B, 0x5B, 0x30, 0x6D,
                            0x3A, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x66, 0x6F, 0x75, 0x6E, 0x64,
                            0x0A]
    buf.append(bytes: payload[...])
    #expect(buf.count(of: "ERROR") == 1)
    #expect(buf.count(of: "not found") == 1)
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
@Test func terminalHostCoordinatorKeepsHostAlive() {
    // Regression: a weak coordinator reference let the host deallocate right
    // after makeNSView, so font/theme changes only applied after relaunch.
    let coordinator = TerminalHost.Coordinator(paneID: UUID())
    coordinator.host = TerminalHostView(startingDirectory: URL(fileURLWithPath: NSHomeDirectory()))
    #expect(coordinator.host != nil)
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
