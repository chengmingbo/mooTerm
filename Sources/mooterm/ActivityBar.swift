import SwiftUI

/// A button on the activity bar: a built-in assistant (`claude`) or a
/// custom one (`custom:<uuid>`). The raw value is what's persisted.
struct SidebarItem: Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init?(rawValue: String) {
        guard AssistantProvider(rawValue: rawValue) != nil || Self.customID(in: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(provider: AssistantProvider) { rawValue = provider.rawValue }
    init(custom id: UUID) { rawValue = "custom:\(id.uuidString)" }

    static let claude = SidebarItem(provider: .claude)
    static var builtIns: [SidebarItem] { AssistantProvider.allCases.map(SidebarItem.init(provider:)) }

    var provider: AssistantProvider? { AssistantProvider(rawValue: rawValue) }
    var customID: UUID? { Self.customID(in: rawValue) }

    private static func customID(in raw: String) -> UUID? {
        raw.hasPrefix("custom:") ? UUID(uuidString: String(raw.dropFirst("custom:".count))) : nil
    }
}

extension AssistantProvider {
    var tint: Color {
        switch self {
        case .claude: return .purple
        case .codex: return .teal
        case .deepseek: return .blue
        case .minimax: return .pink
        }
    }
}

extension UserDefaults {
    /// Raw value of the open `SidebarItem`, or "" when the sidebar is closed.
    static let sidebarSelectionKey = "mooTerm.sidebar.selection"

    static var selectedSidebarItem: SidebarItem? {
        get { standard.string(forKey: sidebarSelectionKey).flatMap(SidebarItem.init(rawValue:)) }
        set { standard.set(newValue?.rawValue ?? "", forKey: sidebarSelectionKey) }
    }
}

/// VS Code–style activity bar: a thin column of tool buttons on the far
/// left. Clicking a button opens its panel; clicking it again closes it.
struct ActivityBar: View {
    @AppStorage(UserDefaults.sidebarSelectionKey) private var selection = ""
    @EnvironmentObject var customStore: CustomAssistantStore
    @EnvironmentObject var preferences: TerminalPreferences

    static let width: CGFloat = 36

    var body: some View {
        VStack(spacing: 6) {
            let items = AssistantDescriptor.all(store: customStore, preferences: preferences)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, descriptor in
                ActivityBarButton(descriptor: descriptor, index: index,
                                  isSelected: selection == descriptor.item.rawValue) {
                    selection = selection == descriptor.item.rawValue ? "" : descriptor.item.rawValue
                }
            }
            Button {
                NSApp.sendAction(#selector(AppDelegate.showCustomAssistantsAction), to: nil, from: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a custom assistant (Kimi, Qwen, Ollama, any CLI…)")
            Spacer()
            Button {
                NSApp.sendAction(#selector(AppDelegate.showSettingsAction), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct ActivityBarButton: View {
    let descriptor: AssistantDescriptor
    let index: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(isSelected ? descriptor.tint : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? descriptor.tint.opacity(0.18)
                              : hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // Selection marker hugging the window edge.
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(descriptor.tint)
                    .frame(width: 2, height: 18)
                    .offset(x: -4)
            }
        }
        .onHover { hovering = $0 }
        .help(index < 9 ? "\(descriptor.title) (⌃⌘\(index + 1)\(descriptor.item == .claude ? " or ⇧⌘A" : ""))" : descriptor.title)
        .accessibilityLabel(descriptor.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// SF Symbol when there is one; otherwise the name's first letter.
    @ViewBuilder
    private var icon: some View {
        if let symbol = descriptor.systemImage, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
        } else {
            Text(descriptor.letter).font(.system(size: 14, weight: .bold, design: .rounded))
        }
    }
}

/// The panel for the selected sidebar item.
struct SidebarPanel: View {
    let item: SidebarItem
    @EnvironmentObject var hub: AssistantHub
    @EnvironmentObject var customStore: CustomAssistantStore
    @EnvironmentObject var preferences: TerminalPreferences

    var body: some View {
        if let descriptor = AssistantDescriptor.all(store: customStore, preferences: preferences)
            .first(where: { $0.item == item }) {
            AssistantPanelView(descriptor: descriptor, assistant: hub.assistant(for: item, store: customStore))
                .id(item)
        }
    }
}
