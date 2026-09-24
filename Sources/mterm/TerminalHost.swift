import AppKit
import SwiftUI

/// SwiftUI wrapper that shows a pane's terminal.
///
/// The terminal itself belongs to the `Pane`, not to this view. SwiftUI
/// rebuilds pane views whenever the split tree changes shape, a pane is
/// zoomed, or the user switches tabs; each rebuild only re-parents the
/// existing terminal view into a fresh container, so the shell and its
/// scrollback are untouched.
struct TerminalHost: NSViewRepresentable {
    let pane: Pane
    let isFocused: Bool
    let scheme: ColorScheme
    let fontSize: CGFloat
    let scrollback: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attachTerminal(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let host = attachTerminal(to: container)
        // These setters no-op when the value is unchanged, so ordinary
        // SwiftUI updates stay cheap.
        host.applyScheme(scheme)
        host.configureAppearance(fontSize: fontSize)
        host.applyScrollback(lines: scrollback)
        let coordinator = context.coordinator
        if isFocused && !coordinator.wasFocused {
            DispatchQueue.main.async { [weak view = host.view] in
                guard let view, let window = view.window,
                      window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
        coordinator.wasFocused = isFocused
    }

    /// Only detach: the pane keeps the terminal alive for the next mount.
    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @discardableResult
    private func attachTerminal(to container: NSView) -> TerminalHostView {
        let host = pane.ensureHost(fontSize: fontSize, scheme: scheme, scrollback: scrollback)
        if host.view.superview !== container {
            host.view.removeFromSuperview()
            host.view.frame = container.bounds
            host.view.autoresizingMask = [.width, .height]
            container.addSubview(host.view)
        }
        return host
    }

    @MainActor
    final class Coordinator {
        var wasFocused = false
    }
}
