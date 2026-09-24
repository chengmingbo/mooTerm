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
    /// Extra variables for the shell, used only when it first starts.
    let environment: [String: String]

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.pane = pane
        pane.containers.register(container)
        attachTerminal(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        // SwiftUI may briefly keep several containers for one pane (e.g.
        // while zooming or closing a split) and update ones it is about to
        // remove; only the newest live one may hold the terminal.
        guard pane.containers.newest === container else { return }
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

    /// The pane keeps the terminal alive. If this container held it, hand
    /// it to the newest container still on screen (SwiftUI doesn't always
    /// remove the older ones first).
    static func dismantleNSView(_ container: TerminalContainerView, coordinator: Coordinator) {
        guard let pane = container.pane else { return }
        pane.containers.unregister(container)
        guard let view = pane.host?.view, view.superview === container else { return }
        view.removeFromSuperview()
        if let next = pane.containers.newest { next.adopt(view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @discardableResult
    private func attachTerminal(to container: TerminalContainerView) -> TerminalHostView {
        let host = pane.ensureHost(fontSize: fontSize, scheme: scheme, scrollback: scrollback,
                                   environment: environment)
        container.adopt(host.view)
        return host
    }

    @MainActor
    final class Coordinator {
        var wasFocused = false
    }
}

/// Holds a pane's terminal view while SwiftUI shows that pane.
final class TerminalContainerView: NSView {
    weak var pane: Pane?

    func adopt(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}

/// The containers SwiftUI currently has for one pane, oldest first.
@MainActor
struct TerminalContainerList {
    private var items: [WeakContainer] = []

    var newest: TerminalContainerView? {
        items.last(where: { $0.value != nil })?.value
    }

    mutating func register(_ container: TerminalContainerView) {
        items.removeAll { $0.value == nil }
        items.append(WeakContainer(value: container))
    }

    mutating func unregister(_ container: TerminalContainerView) {
        items.removeAll { $0.value == nil || $0.value === container }
    }

    private struct WeakContainer { weak var value: TerminalContainerView? }
}
