import SwiftUI

/// Settings window (⌘,). Every control writes straight to its store, so
/// open panes update as you change things — no Apply button.
struct SettingsView: View {
    @EnvironmentObject var preferences: TerminalPreferences
    @EnvironmentObject var fontSizeStore: FontSizeStore
    @EnvironmentObject var schemeStore: ColorSchemeStore
    @AppStorage(UserDefaults.dimInactivePanesKey) private var dimInactivePanes = true

    private var proxyDescription: String {
        let using = preferences.effectiveProxy()?.summary
        switch preferences.proxyMode {
        case .automatic:
            return "Uses the macOS system proxy (System Settings → Network → Proxies, e.g. from Clash), or proxy variables mTerm was launched with. Currently: \(using ?? "no proxy found")."
        case .custom:
            return "Sets http_proxy, https_proxy, and all_proxy to this URL. Currently: \(using ?? "not set")."
        case .off:
            return "No proxy variables are passed on; inherited ones are removed for the Claude panel."
        }
    }

    var body: some View {
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

            AssistantSettingsSection()

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
        .frame(width: 500, height: 680)
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
                    .help("Without a saved key, mTerm uses $\(variable) from your shell profile.")
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
