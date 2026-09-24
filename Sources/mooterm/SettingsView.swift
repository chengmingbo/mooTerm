import SwiftUI

/// Settings window (⌘,). Every control writes straight to its store, so
/// open panes update as you change things — no Apply button.
struct SettingsView: View {
    enum Tab: String { case general, assistants, custom }
    /// Set before opening the window to land on a tab (then cleared).
    static let focusSectionKey = "mooTerm.settings.focusTab"

    @State private var tab: Tab = .general
    @EnvironmentObject var preferences: TerminalPreferences
    @EnvironmentObject var fontSizeStore: FontSizeStore
    @EnvironmentObject var schemeStore: ColorSchemeStore
    @AppStorage(UserDefaults.dimInactivePanesKey) private var dimInactivePanes = false

    private var proxyDescription: String {
        let using = preferences.effectiveProxy()?.summary
        switch preferences.proxyMode {
        case .automatic:
            return "Uses the macOS system proxy (System Settings → Network → Proxies, e.g. from Clash), or proxy variables mooTerm was launched with. Currently: \(using ?? "no proxy found")."
        case .custom:
            return "Sets http_proxy, https_proxy, and all_proxy to this URL. Currently: \(using ?? "not set")."
        case .off:
            return "No proxy variables are passed on; inherited ones are removed for the Claude panel."
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            Form { AssistantSettingsSection() }
                .formStyle(.grouped)
                .tabItem { Label("Assistants", systemImage: "sparkles") }
                .tag(Tab.assistants)
            CustomAssistantsSettings()
                .tabItem { Label("Custom", systemImage: "plus.square.on.square") }
                .tag(Tab.custom)
        }
        .frame(width: 560, height: 640)
        .onAppear(perform: applyFocusRequest)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            applyFocusRequest()
        }
    }

    private func applyFocusRequest() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.focusSectionKey), let requested = Tab(rawValue: raw) {
            tab = requested
            defaults.removeObject(forKey: Self.focusSectionKey)
        }
    }

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Scrollback", value: $preferences.scrollbackLines, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                    Text("lines")
                    Menu("Presets") {
                        ForEach(TerminalPreferences.scrollbackPresets, id: \.self) { lines in
                            Button(lines.formatted()) { preferences.scrollbackLines = lines }
                        }
                        Divider()
                        Button("Off") { preferences.scrollbackLines = 0 }
                    }
                    .fixedSize()
                }
                Text("History kept above the screen in each pane (0 turns it off, maximum 1,000,000). Lowering it drops the oldest lines from open panes. ⌘K clears the screen and scrollback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Scrollback")
            }

            Section {
                Picker("Proxy", selection: $preferences.proxyMode) {
                    Text("Automatic").tag(TerminalPreferences.ProxyMode.automatic)
                    Text("Custom").tag(TerminalPreferences.ProxyMode.custom)
                    Text("None").tag(TerminalPreferences.ProxyMode.off)
                }
                if preferences.proxyMode == .custom {
                    TextField("Proxy URL", text: $preferences.customProxy, prompt: Text("http://127.0.0.1:7890"))
                }
                Toggle("Also set in new terminal panes", isOn: $preferences.proxyInPanes)
                    .disabled(preferences.proxyMode == .off)
                Text(proxyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Network")
            }

            Section {
                Stepper {
                    Text("Font size: \(Int(fontSizeStore.size)) pt")
                } onIncrement: {
                    fontSizeStore.increase()
                } onDecrement: {
                    fontSizeStore.decrease()
                }
                Picker("Theme", selection: Binding(
                    get: { schemeStore.current.id },
                    set: { id in
                        if let scheme = ColorScheme.all.first(where: { $0.id == id }) {
                            schemeStore.select(scheme)
                        }
                    })) {
                    ForEach(ColorScheme.all, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Toggle("Dim inactive panes", isOn: $dimInactivePanes)
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
    }
}


/// Model, endpoint, and API key for each assistant panel.
private struct AssistantSettingsSection: View {
    @EnvironmentObject var preferences: TerminalPreferences
    @State private var provider: AssistantProvider = UserDefaults.selectedSidebarItem?.provider ?? .claude
    @State private var keyDraft = ""
    @State private var keyStatus = ""

    var body: some View {
        Section {
            Picker("Assistant", selection: $provider) {
                ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(provider.backendDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: Binding(
                        get: { preferences.model(for: provider) },
                        set: { preferences.setModel($0, for: provider) }),
                        prompt: Text(provider == .codex ? "Codex default (config.toml)" : "Tool default"))
                        .labelsHidden()
                    if !provider.modelSuggestions.isEmpty {
                        Menu("") {
                            ForEach(provider.modelSuggestions, id: \.self) { model in
                                Button(model) { preferences.setModel(model, for: provider) }
                            }
                        }
                        .menuIndicator(.visible)
                        .fixedSize()
                    }
                }
            }

            if provider.baseURLChoices.count > 1 {
                Picker("Endpoint", selection: Binding(
                    get: { preferences.baseURL(for: provider) ?? "" },
                    set: { preferences.setBaseURL($0, for: provider) })) {
                    ForEach(provider.baseURLChoices, id: \.url) { Text($0.label).tag($0.url) }
                }
            }

            if let variable = provider.apiKeyVariable {
                LabeledContent("API key") {
                    HStack(spacing: 6) {
                        SecureField("API key", text: $keyDraft, prompt: Text("Paste to save"))
                            .labelsHidden()
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if APIKeyStore.savedKey(for: provider) != nil {
                            Button("Remove") {
                                APIKeyStore.save(nil, for: provider)
                                refreshKeyStatus()
                            }
                        }
                    }
                }
                Text(keyStatus.isEmpty ? "Checking for a key…" : keyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Without a saved key, mooTerm uses $\(variable) from your shell profile.")
            }
        } header: {
            Text("Assistants")
        }
        .onAppear(perform: refreshKeyStatus)
        .onChange(of: provider) { _ in
            keyDraft = ""
            refreshKeyStatus()
        }
    }

    private func saveKey() {
        APIKeyStore.save(keyDraft, for: provider)
        keyDraft = ""
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        guard let variable = provider.apiKeyVariable else { keyStatus = ""; return }
        let current = provider
        if let source = APIKeyStore.source(for: current) {
            keyStatus = "Using the key \(source)."
            return
        }
        keyStatus = ""
        Task {
            let found = await Task.detached { APIKeyStore.resolve(for: current) != nil }.value
            guard current == provider else { return }
            keyStatus = found
                ? "Using $\(variable) from your shell profile."
                : "No key yet. Paste one above, or export \(variable) in ~/.zshrc."
        }
    }
}

/// Settings → Custom: add assistants for any OpenAI-compatible API (Kimi,
/// Qwen, OpenRouter, Ollama…) or any CLI (qwen, kimi, gemini, opencode…).
private struct CustomAssistantsSettings: View {
    @EnvironmentObject var store: CustomAssistantStore
    @EnvironmentObject var preferences: TerminalPreferences
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.assistants) { assistant in
                        HStack(spacing: 8) {
                            CustomAssistantIcon(assistant: assistant)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(assistant.name).lineLimit(1)
                                Text(assistant.kind == .command ? "Command" : "API")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(assistant.id)
                    }
                }
                .overlay {
                    if store.assistants.isEmpty {
                        Text("No custom assistants yet.\nAdd one with +.")
                            .multilineTextAlignment(.center)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(CustomAssistant.presets, id: \.label) { preset in
                            Button(preset.label) { selection = store.add(preset.make()).id }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add from a preset")
                    Button {
                        if let id = selection {
                            store.remove(id: id)
                            selection = store.assistants.first?.id
                        }
                    } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        .help("Remove")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 170)
            Divider()
            if let id = selection, store.assistant(id: id) != nil {
                CustomAssistantEditor(id: id)
                    .id(id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "plus.square.on.square").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Add an assistant for any tool").font(.headline)
                    Text("Use + to start from Kimi, Qwen, OpenRouter, Ollama, or a command-line tool like qwen, kimi, gemini, or opencode. Each one gets its own button on the left bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.assistants.first?.id } }
    }
}

struct CustomAssistantIcon: View {
    let assistant: CustomAssistant
    var body: some View {
        let tint = assistant.color.nsColor.map { Color(nsColor: $0) } ?? .gray
        Group {
            if !assistant.symbol.isEmpty, NSImage(systemSymbolName: assistant.symbol, accessibilityDescription: nil) != nil {
                Image(systemName: assistant.symbol)
            } else {
                Text(assistant.letter).font(.system(size: 12, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 18)
    }
}

private struct CustomAssistantEditor: View {
    let id: UUID
    @EnvironmentObject var store: CustomAssistantStore
    @EnvironmentObject var preferences: TerminalPreferences
    @State private var keyDraft = ""
    @State private var keyStatus = ""
    @State private var testResult: String?
    @State private var testing = false

    private var assistant: Binding<CustomAssistant> {
        Binding(get: { store.assistant(id: id) ?? CustomAssistant(name: "", kind: .command) },
                set: { store.update($0) })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: assistant.name)
                Picker("Type", selection: assistant.kind) {
                    Text("OpenAI-compatible API").tag(CustomAssistant.Kind.openAICompatible)
                    Text("Command-line tool").tag(CustomAssistant.Kind.command)
                }
                HStack {
                    TextField("Icon", text: assistant.symbol, prompt: Text("SF Symbol, e.g. moon.stars"))
                    CustomAssistantIcon(assistant: assistant.wrappedValue)
                }
                Picker("Color", selection: assistant.color) {
                    ForEach(AccentColor.allCases.filter { $0 != .none }, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            if assistant.wrappedValue.kind == .openAICompatible {
                Section {
                    TextField("Base URL", text: assistant.baseURL, prompt: Text("https://api.example.com/v1"))
                    TextField("Model", text: assistant.model)
                    HStack(spacing: 6) {
                        SecureField("API key", text: $keyDraft, prompt: Text("Paste to save"))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if APIKeyStore.savedKey(account: assistant.wrappedValue.keyAccount) != nil {
                            Button("Remove") {
                                APIKeyStore.save(nil, account: assistant.wrappedValue.keyAccount)
                                refreshKeyStatus()
                            }
                        }
                    }
                    TextField("Key variable", text: assistant.apiKeyVariable, prompt: Text("e.g. MOONSHOT_API_KEY"))
                    Text(keyStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("API")
                } footer: {
                    Text("Any service with a /chat/completions endpoint: Kimi (api.moonshot.cn/v1), Qwen (dashscope…/compatible-mode/v1), OpenRouter, DeepSeek, Ollama (localhost:11434/v1, no key)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Command", text: assistant.command, prompt: Text(#"e.g. qwen -p "Follow the instructions above.""#),
                              axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...5)
                    TextField("Model", text: assistant.model, prompt: Text("optional, available as $MOOTERM_MODEL"))
                } header: {
                    Text("Command")
                } footer: {
                    Text("Runs in your login shell (your PATH, aliases, and the tool's own login apply). The full prompt — instructions, terminal context, and request — arrives on stdin and in $MOOTERM_PROMPT. mooTerm reads the JSON answer from what the command prints; a fenced code block also works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing)
                    Text("Asks: “show the current directory”")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let testResult {
                    Text(testResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshKeyStatus)
    }

    private func saveKey() {
        APIKeyStore.save(keyDraft, account: assistant.wrappedValue.keyAccount)
        keyDraft = ""
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        let custom = assistant.wrappedValue
        if APIKeyStore.savedKey(account: custom.keyAccount) != nil {
            keyStatus = "Using the key saved in mooTerm."
            return
        }
        let variable = custom.apiKeyVariable
        guard !variable.isEmpty else {
            keyStatus = "No key: requests are sent without authentication (fine for local servers like Ollama)."
            return
        }
        keyStatus = "Looking for $\(variable)…"
        Task {
            let found = await Task.detached { APIKeyStore.resolve(account: custom.keyAccount, variable: variable) != nil }.value
            keyStatus = found ? "Using $\(variable) from your shell profile."
                              : "No key yet. Paste one above, or export \(variable) in ~/.zshrc."
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let custom = assistant.wrappedValue
        let item = SidebarItem(custom: custom.id)
        let options = assistantOptions(for: item, preferences: preferences, store: store)
        let home = NSHomeDirectory()
        Task {
            let started = Date()
            let key: String? = if let resolve = options.apiKey { await Task.detached { resolve() }.value } else { nil }
            let context = TerminalContext(cwd: home, shell: "zsh", foregroundProgram: nil, recentOutput: "", broadcastPaneCount: 1)
            let request = TranslationRequest(
                prompt: CommandAssistant.prompt(request: "show the current directory", context: context, history: ""),
                systemPrompt: CommandAssistant.systemPrompt, schema: CommandAssistant.schema,
                model: options.model, workingDirectory: URL(fileURLWithPath: home),
                environment: options.environment, apiProxy: options.apiProxy,
                apiKey: key, baseURL: options.baseURL)
            let result = await custom.makeTranslator().translate(request)
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
            switch result {
            case .success(let reply):
                testResult = "✓ \(seconds)  \(reply.command ?? "(no command)")\n\(reply.explanation)"
            case .failure(let failure):
                testResult = "✗ \(seconds)  \(failure.message)"
            }
            testing = false
        }
    }
}
