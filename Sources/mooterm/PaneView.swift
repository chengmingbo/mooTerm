import SwiftUI
import AppKit

extension UserDefaults {
    static let dimInactivePanesKey = "mooTerm.dimInactivePanes"
}

/// PaneView: renders a single terminal pane — header on top, terminal
/// surface filling the rest, with split/close context menu. The terminal
/// itself is a real SwiftTerm-backed shell owned by the `Pane`; everything
/// visible inside the pane comes from the shell's PTY.
///
/// Header buttons and the context menu act on *this* pane, not whichever
/// pane happens to be active.
struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var tab: TabSession
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var schemeStore: ColorSchemeStore
    @EnvironmentObject var fontSizeStore: FontSizeStore
    @EnvironmentObject var preferences: TerminalPreferences
    @AppStorage(UserDefaults.dimInactivePanesKey) private var dimInactivePanes = false

    private var isActive: Bool { tab.activePaneID == pane.id }
    private var isOnlyVisiblePane: Bool { tab.zoomedPaneID != nil || tab.root.pane != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            terminal
                .overlay(dimOverlay)
                .overlay(alignment: .bottomTrailing) { copyToast }
        }
        .background(Color(nsColor: schemeStore.current.nsBackground()))
        .animation(.easeOut(duration: 0.2), value: pane.copyToast)
        .overlay(borderOverlay)
        .contextMenu { paneContextMenu }
    }

    private var terminal: some View {
        // Zoom (⌘⇧Z) bumps the font size by 2pt; maximise (⌘⇧X) keeps it.
        let paneSize = fontSizeStore.size(forOffset: pane.fontSizeOffset)
        let effectiveSize = tab.zoomBumpsFont ? paneSize + 2 : paneSize
        return TerminalHost(
            pane: pane,
            isFocused: isActive,
            scheme: schemeStore.current,
            fontSize: effectiveSize,
            scrollback: preferences.scrollbackLines,
            scrollbarMode: preferences.scrollbarMode,
            textMargin: preferences.textMargin,
            environment: pane.host == nil ? preferences.paneEnvironment : [:]
        )
    }

    /// iTerm2's "dim inactive split panes": makes the focused pane obvious
    /// without a heavy border.
    @ViewBuilder
    private var dimOverlay: some View {
        if dimInactivePanes && !isActive && !isOnlyVisiblePane {
            Color.black.opacity(0.28).allowsHitTesting(false)
        }
    }

    /// iTerm2-style confirmation in the pane's bottom-right corner.
    @ViewBuilder
    private var copyToast: some View {
        if let toast = pane.copyToast {
            Label(toast.message, systemImage: "doc.on.clipboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                .padding(10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(toast.id)
                .allowsHitTesting(false)
                .accessibilityLabel(toast.message)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isActive && !isOnlyVisiblePane {
            Rectangle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            // Labels let clicks through to the header's click area below,
            // so double-clicking the title works too.
            Group {
                Image(systemName: "terminal")
                Text(pane.title).font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let dir = pane.cwd {
                    Text(dir).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if tab.broadcast && pane.shellID != nil {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.cyan).font(.system(size: 10))
                }
            }
            .allowsHitTesting(false)
            if pane.fontSizeOffset != 0 {
                // This pane has its own size (⌘= / ⌘-); click to reset.
                Button {
                    pane.fontSizeOffset = 0
                } label: {
                    Text("\(Int(fontSizeStore.size(forOffset: pane.fontSizeOffset))) pt")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("This pane's font size (others use \(Int(fontSizeStore.size)) pt). Click or press ⌘0 to reset.")
            }
            Button { tab.split(.horizontal, pane: pane.id) } label: {
                Image(systemName: "rectangle.split.1x2").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split horizontally (divider runs horizontally)")
            Button { tab.split(.vertical, pane: pane.id) } label: {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split vertically (divider runs vertically)")
            Button { store.requestClosePane(pane.id) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Close pane")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // AppKit click handling (SwiftUI's double-tap didn't fire). With
        // several panes, double-click fills the tab with this one; with a
        // single pane there's nothing to maximise, so zoom the window.
        .background(TitleBarArea(
            onDoubleClick: tab.panes.count > 1 ? { tab.toggleMaximise(paneID: pane.id) } : nil,
            onClick: { tab.setActive(paneID: pane.id) })
            .background(Color.gray.opacity(0.15)))  // colour behind the click area
        .help(tab.panes.count <= 1 ? "Double-click to zoom the window"
              : tab.zoomedPaneID == pane.id ? "Double-click to restore all panes"
              : "Double-click to fill the tab with this pane")
    }

    @ViewBuilder
    private var paneContextMenu: some View {
        Button("Copy") { sendSelectionAction(#selector(NSText.copy(_:))) }
        Button("Paste") { sendSelectionAction(#selector(NSText.paste(_:))) }
        Button("Select All") { sendSelectionAction(#selector(NSText.selectAll(_:))) }
        Button("Clear Buffer") { pane.host?.clearBuffer() }
        Divider()
        Button("Split Horizontally") { tab.split(.horizontal, pane: pane.id) }
        Button("Split Vertically") { tab.split(.vertical, pane: pane.id) }
        Divider()
        Button("Close Pane") { store.requestClosePane(pane.id) }
        Divider()
        Button(tab.broadcast ? "Disable Broadcast Group" : "Enable Broadcast Group") {
            tab.toggleBroadcast()
        }
        Button("New Tab") { store.newTab() }
        Button("Close Tab") { store.requestCloseTab(tab.id) }
    }

    /// Forward a standard Cocoa text selector (Copy / Paste / Select All) to
    /// this pane's terminal view.
    private func sendSelectionAction(_ action: Selector) {
        tab.setActive(paneID: pane.id)
        NSApp.sendAction(action, to: pane.host?.view, from: nil)
    }
}
