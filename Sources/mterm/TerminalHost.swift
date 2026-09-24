import AppKit
import SwiftUI
import Combine

/// SwiftUI wrapper around DropTerm's `TerminalHostView`. One shell per pane,
/// started the moment the SwiftUI view is mounted. The host auto-respawns the
/// shell if the user types `exit`.
///
/// This is the only file that bridges SwiftUI and SwiftTerm. `PaneView`
/// instantiates one `TerminalHost` per pane and forgets about it.
struct TerminalHost: NSViewRepresentable {
    let paneID: UUID
    let startingDirectory: URL
    let isFocused: Bool
    let scheme: ColorScheme
    let fontSize: CGFloat
    let onCwdChange: (URL) -> Void

    func makeNSView(context: Context) -> NSView {
        let host = TerminalHostView(startingDirectory: startingDirectory)
        host.configureAppearance(fontSize: fontSize)
        host.applyScheme(scheme)
        host.currentDirectoryDidChange = { [weak coordinator = context.coordinator] url in
            coordinator?.handleCwdChange(url)
        }
        context.coordinator.host = host
        context.coordinator.onCwdChange = onCwdChange
        ScrollbackRegistry.shared.register(paneID: paneID, buffer: host.scrollback)
        host.startShell(in: startingDirectory)
        return host.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCwdChange = onCwdChange
        if isFocused && !coordinator.wasFocused {
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
        coordinator.wasFocused = isFocused
        // Re-apply scheme + font size so menu-driven changes recolour and
        // resize every open pane immediately. Both setters no-op when the
        // value is unchanged, so ordinary SwiftUI updates stay cheap.
        coordinator.host?.applyScheme(scheme)
        coordinator.host?.configureAppearance(fontSize: fontSize)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.host?.view.removeFromSuperview()
        coordinator.host = nil
        ScrollbackRegistry.shared.unregister(paneID: coordinator.paneID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(paneID: paneID)
    }

    @MainActor
    final class Coordinator {
        let paneID: UUID
        /// Strong: nothing else retains the host (the NSView only references
        /// it through a weak delegate back-pointer). A weak reference here
        /// let it deallocate right after `makeNSView`, silently dropping
        /// every later font, scheme, and cwd update.
        var host: TerminalHostView?
        var wasFocused = false
        var onCwdChange: ((URL) -> Void)?

        init(paneID: UUID) {
            self.paneID = paneID
        }

        func handleCwdChange(_ url: URL) {
            onCwdChange?(url)
        }
    }
}