import SwiftUI

/// A tool that lives in the left sidebar. Add a case (plus its panel in
/// `SidebarPanel`) to put another button on the activity bar.
enum SidebarItem: String, CaseIterable, Identifiable {
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return .purple
        }
    }

    var shortcutHint: String {
        switch self {
        case .claude: return "⇧⌘A"
        }
    }
}

extension UserDefaults {
    /// Raw value of the open `SidebarItem`, or "" when the sidebar is closed.
    static let sidebarSelectionKey = "mTerm.sidebar.selection"

    static var selectedSidebarItem: SidebarItem? {
        get { standard.string(forKey: sidebarSelectionKey).flatMap(SidebarItem.init(rawValue:)) }
        set { standard.set(newValue?.rawValue ?? "", forKey: sidebarSelectionKey) }
    }
}

/// VS Code–style activity bar: a thin column of tool buttons on the far
/// left. Clicking a button opens its panel; clicking it again closes it.
struct ActivityBar: View {
    @AppStorage(UserDefaults.sidebarSelectionKey) private var selection = ""

    static let width: CGFloat = 36

    var body: some View {
        VStack(spacing: 6) {
            ForEach(SidebarItem.allCases) { item in
                ActivityBarButton(item: item, isSelected: selection == item.rawValue) {
                    selection = selection == item.rawValue ? "" : item.rawValue
                }
            }
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
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? item.tint : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? item.tint.opacity(0.18)
                              : hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // Selection marker hugging the window edge.
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(item.tint)
                    .frame(width: 2, height: 18)
                    .offset(x: -4)
            }
        }
        .onHover { hovering = $0 }
        .help("\(item.title) (\(item.shortcutHint))")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The panel for the selected sidebar item.
struct SidebarPanel: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .claude: AssistantPanelView()
        }
    }
}
