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

            Section {
                Picker("Model", selection: $preferences.claudeModel) {
                    ForEach(TerminalPreferences.claudeModelChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                Text("Used by the Claude panel (⇧⌘A) through your installed Claude Code CLI. Claude only proposes commands; nothing runs until you press Run, unless you turn on auto-run for read-only commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Claude Panel")
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
        .frame(width: 460)
        .fixedSize()
    }
}
