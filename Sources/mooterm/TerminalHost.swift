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
    var scrollbarMode: MooTermTerminalView.ScrollbarMode = .always
    var textMargin: CGFloat = TerminalPreferences.defaultTextMargin
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
        guard pane.containers.newest === container,
              let host = attachTerminal(to: container) else { return }
        // These setters no-op when the value is unchanged, so ordinary
        // SwiftUI updates stay cheap.
        host.applyScheme(scheme)
        host.configureAppearance(fontSize: fontSize)
        host.applyScrollback(lines: scrollback)
        host.view.setScrollbarMode(scrollbarMode)
        container.margins = .forText(margin: textMargin, scrollbar: scrollbarMode)
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
    private func attachTerminal(to container: TerminalContainerView) -> TerminalHostView? {
        guard let host = pane.ensureHost(fontSize: fontSize, scheme: scheme, scrollback: scrollback,
                                         environment: environment) else { return nil }
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

    /// Space between the pane's edges and the terminal (points). The
    /// pane's background shows through, so it reads as terminal padding.
    struct Margins: Equatable {
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0

        /// `margin` at the left, half of it above and below; the right
        /// side only when there's no scrollbar there (it sits at the edge).
        static func forText(margin: CGFloat, scrollbar: MooTermTerminalView.ScrollbarMode) -> Margins {
            Margins(left: margin, right: scrollbar == .never ? margin : 0,
                    top: (margin / 2).rounded(), bottom: (margin / 2).rounded())
        }
    }

    var margins = Margins() {
        didSet { if margins != oldValue { layoutTerminal() } }
    }

    func adopt(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        addSubview(view)
        layoutTerminal()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutTerminal()
    }

    private func layoutTerminal() {
        guard let terminal = subviews.first else { return }
        let frame = NSRect(x: margins.left, y: margins.bottom,
                           width: max(0, bounds.width - margins.left - margins.right),
                           height: max(0, bounds.height - margins.top - margins.bottom))
        if terminal.frame != frame { terminal.frame = frame }
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
