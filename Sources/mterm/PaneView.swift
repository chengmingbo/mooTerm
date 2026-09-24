import SwiftUI
import AppKit

/// Notifications for menu items that originate inside SwiftUI views and need
/// to mutate global state owned by AppDelegate (tabs, session).
extension Notification.Name {
    static let mtermNewTab = Notification.Name("mTerm.newTab")
    static let mtermCloseTab = Notification.Name("mTerm.closeTab")
    /// Posted by the menu / the find bar itself when the user wants to
    /// open the find bar in the focused pane. UserInfo: ["paneID": UUID,
    /// "term": String].
    static let mtermFindInPane = Notification.Name("mTerm.findInPane")
}

/// Focus state — which pane currently owns keyboard input. Lives on the
/// store so cross-pane navigation works.
final class FocusStore: ObservableObject {
    @Published var focusedPaneID: UUID?
    /// When non-nil, the focused pane should show its find bar pre-filled
    /// with this string.
    @Published var findRequest: FindRequest?
}

struct FindRequest: Equatable {
    let paneID: UUID
    let term: String
}

/// PaneView: renders a single terminal pane — header on top, terminal
/// surface filling the rest, with split/close context menu. The terminal
/// itself is a real SwiftTerm-backed shell via `TerminalHost`; everything
/// visible inside the pane comes from the shell's PTY.
struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var tab: TabSession
    @EnvironmentObject var focus: FocusStore
    @EnvironmentObject var schemeStore: ColorSchemeStore
    @EnvironmentObject var fontSizeStore: FontSizeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            terminal
            if findBarVisible {
                FindBar(paneID: pane.id, isVisible: $findBarVisible)
            }
        }
        .background(Color(nsColor: schemeStore.current.nsBackground()))
        .overlay(borderOverlay)
        .contextMenu { paneContextMenu }
        .onTapGesture {
            tab.setActive(paneID: pane.id)
            focus.focusedPaneID = pane.id
        }
        .onChange(of: focus.focusedPaneID) { newValue in
            if newValue == pane.id { /* focus is handled by TerminalHost */ }
        }
        .onChange(of: focus.findRequest) { request in
            if let request, request.paneID == pane.id {
                findBarVisible = true
            }
        }
    }

    @State private var findBarVisible: Bool = false

    private var terminal: some View {
        let startDir: URL
        if let cwd = pane.cwd {
            startDir = URL(fileURLWithPath: cwd)
        } else if let home = ProcessInfo.processInfo.environment["HOME"] {
            startDir = URL(fileURLWithPath: home)
        } else {
            startDir = URL(fileURLWithPath: "/")
        }
        // Zoom (⌘⇧Z) bumps the font size by 2pt; maximise (⌘⇧X) keeps it.
        let effectiveSize = tab.zoomBumpsFont ? fontSizeStore.size + 2 : fontSizeStore.size
        return TerminalHost(
            paneID: pane.id,
            startingDirectory: startDir,
            isFocused: focus.focusedPaneID == pane.id,
            scheme: schemeStore.current,
            fontSize: effectiveSize,
            onCwdChange: { url in pane.cwd = url.path }
        )
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if tab.activePaneID == pane.id {
            Rectangle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
            Text(pane.title).font(.system(size: 11, weight: .medium))
            Spacer()
            if let dir = pane.cwd {
                Text(dir).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if tab.broadcast && pane.shellID != nil {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.cyan).font(.system(size: 10))
            }
            Button { tab.split(.horizontal) } label: {
                Image(systemName: "rectangle.split.1x2").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split horizontally (divider runs horizontally)")
            Button { tab.split(.vertical) } label: {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split vertically (divider runs vertically)")
            Button { tab.closeActivePane() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Close pane")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.gray.opacity(0.15))
    }

    @ViewBuilder
    private var paneContextMenu: some View {
        Button("Copy") { sendSelectionAction(#selector(NSText.copy(_:))) }
        Button("Paste") { sendSelectionAction(#selector(NSText.paste(_:))) }
        Button("Select All") { sendSelectionAction(#selector(NSText.selectAll(_:))) }
        Divider()
        Button("Split Horizontally") { tab.split(.horizontal) }
        Button("Split Vertically") { tab.split(.vertical) }
        Divider()
        Button("Close Pane") { tab.closeActivePane() }
        Divider()
        Button(tab.broadcast ? "Disable Broadcast Group" : "Enable Broadcast Group") {
            tab.toggleBroadcast()
        }
        Button("New Tab") {
            NotificationCenter.default.post(name: .mtermNewTab, object: nil)
        }
        Button("Close Tab") {
            NotificationCenter.default.post(name: .mtermCloseTab, object: nil)
        }
    }

/// Forward a standard Cocoa text selector (Copy / Paste / Select All) to
    /// the responder chain so it reaches the currently-focused SwiftTerm
    /// view, which implements NSTextInputClient. `NSApp.sendAction` walks
    /// the responder chain automatically until something handles it.
    private func sendSelectionAction(_ action: Selector) {
        let target: NSResponder? = NSApp.keyWindow ?? NSApp.mainWindow
        NSApp.sendAction(action, to: nil, from: target)
}
}

/// ⌘F find bar attached to the bottom of a pane. For MVP the search is
/// plain-text only: counts matches and surfaces the **active line** (the line
/// containing the currently-selected match). Scroll-to-match will come in a
/// later iteration.
struct FindBar: View {
    let paneID: UUID
    @Binding var isVisible: Bool
    @State private var term: String = ""
    @State private var matchIndex: Int = 0
    @State private var matchCount: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
            TextField("Find", text: $term)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { advance(by: 1) }
                .onChange(of: term) { _ in recount() }
            Text(matchCount > 0
                 ? "\(matchIndex + 1) of \(matchCount)"
                 : (term.isEmpty ? "" : "0 matches"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Button { advance(by: -1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            Button { advance(by: 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            Button {
                isVisible = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.15))
        .onAppear { fieldFocused = true }
        .onExitCommand { isVisible = false }
    }

    private func recount() {
        let buffer = ScrollbackRegistry.shared.buffer(for: paneID)
        matchCount = buffer?.count(of: term) ?? 0
        matchIndex = matchCount > 0 ? 0 : 0
    }

    private func advance(by delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
        // Scroll-to-match would go here. For MVP we just update the
        // counter; the user scrolls manually.
    }
}

/// Lightweight registry of scrollback buffers, keyed by pane UUID. The pane
/// view registers when the SwiftTerm host spins up and unregisters when it
/// tears down. Global so ⌘F (handled by AppDelegate) can find the right pane.
@MainActor
final class ScrollbackRegistry {
    static let shared = ScrollbackRegistry()
    private var buffers: [UUID: ScrollbackBuffer] = [:]

    func register(paneID: UUID, buffer: ScrollbackBuffer) {
        buffers[paneID] = buffer
    }

    func unregister(paneID: UUID) {
        buffers.removeValue(forKey: paneID)
    }

    func buffer(for paneID: UUID) -> ScrollbackBuffer? {
        buffers[paneID]
    }
}