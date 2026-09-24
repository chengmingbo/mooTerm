import SwiftUI

/// Settings window (⌘,). Every control writes straight to its store, so
/// open panes update as you change things — no Apply button.
struct SettingsView: View {
    @EnvironmentObject var preferences: TerminalPreferences
    @EnvironmentObject var fontSizeStore: FontSizeStore
    @EnvironmentObject var schemeStore: ColorSchemeStore
    @AppStorage(UserDefaults.dimInactivePanesKey) private var dimInactivePanes = true

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
