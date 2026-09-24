import SwiftUI
import AppKit

extension UserDefaults {
    static let dimInactivePanesKey = "mTerm.dimInactivePanes"
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
    @AppStorage(UserDefaults.dimInactivePanesKey) private var dimInactivePanes = true

    private var isActive: Bool { tab.activePaneID == pane.id }
    private var isOnlyVisiblePane: Bool { tab.zoomedPaneID != nil || tab.root.pane != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            terminal
                .overlay(dimOverlay)
        }
        .background(Color(nsColor: schemeStore.current.nsBackground()))
        .overlay(borderOverlay)
        .contextMenu { paneContextMenu }
    }

    private var terminal: some View {
        // Zoom (⌘⇧Z) bumps the font size by 2pt; maximise (⌘⇧X) keeps it.
        let effectiveSize = tab.zoomBumpsFont ? fontSizeStore.size + 2 : fontSizeStore.size
        return TerminalHost(
            pane: pane,
            isFocused: isActive,
            scheme: schemeStore.current,
            fontSize: effectiveSize
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
        .background(Color.gray.opacity(0.15))
        .contentShape(Rectangle())
        .onTapGesture { tab.setActive(paneID: pane.id) }
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
