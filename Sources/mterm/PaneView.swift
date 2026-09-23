import SwiftUI
import AppKit

/// Notifications for menu items that originate inside SwiftUI views and need
/// to mutate global state owned by AppDelegate (tabs, session).
extension Notification.Name {
    static let mtermNewTab = Notification.Name("mterm.newTab")
    static let mtermCloseTab = Notification.Name("mterm.closeTab")
}

/// Focus state — which pane currently owns keyboard input. Lives on the
/// store so cross-pane navigation works.
final class FocusStore: ObservableObject {
    @Published var focusedPaneID: UUID?
}

/// The scrollback + cursor + input line, all in one piece. Renders scrollback
/// as plain green text, then the current prompt + cursor + active input as a
/// single NSTextField pinned to the bottom of the area. macOS Terminal and
/// iTerm2 use this layout.
struct TerminalSurface: NSViewRepresentable {
    @Binding var scrollback: String       // pane.content (read-only text)
    @Binding var input: String            // current line being typed
    var isFocused: Bool                   // this pane owns keyboard
    var onSubmit: (String) -> Void
    var onFocusRequest: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .black

        // Scrollback text view — non-editable, just shows history.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.75, alpha: 1)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        context.coordinator.scrollbackView = textView

        // Input row — pinned to the bottom of the scrollable area as a custom
        // subview so it stays in view while scrollback scrolls.
        let input = CursorInputField()
        input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        input.textColor = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.75, alpha: 1)
        input.backgroundColor = .clear
        input.drawsBackground = false
        input.isBezeled = false
        input.isBordered = false
        input.placeholderString = ""
        input.target = context.coordinator
        input.action = #selector(Coordinator.commit(_:))
        input.delegate = context.coordinator
        input.cell?.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.inputField = input

        scroll.addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -12),
            input.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -6),
            input.heightAnchor.constraint(equalToConstant: 22),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        // Update scrollback text.
        if let tv = coord.scrollbackView, tv.string != scrollback {
            tv.string = scrollback
            // Auto-scroll to bottom.
            if let docView = scroll.documentView {
                let bottom = NSPoint(x: 0, y: max(0, docView.frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: bottom)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        // Update input field.
        if let f = coord.inputField, f.stringValue != input {
            f.stringValue = input
        }
        // Focus management: focus the input field when this pane becomes active.
        if isFocused, let win = scroll.window {
            if coord.lastFocused != scroll.window?.windowNumber {
                coord.lastFocused = win.windowNumber
                DispatchQueue.main.async { [weak scroll] in
                    guard let scroll = scroll,
                          let field = coord.inputField,
                          let editor = field.currentEditor() ?? field.window?.fieldEditor(true, for: field)
                    else { return }
                    _ = editor
                    scroll.window?.makeFirstResponder(field)
                }
            }
        } else {
            coord.lastFocused = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalSurface
        weak var scrollbackView: NSTextView?
        weak var inputField: CursorInputField?
        var lastFocused: Int?

        init(_ parent: TerminalSurface) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.input = tf.stringValue
        }

        @objc func commit(_ sender: NSTextField) {
            parent.onSubmit(sender.stringValue)
            sender.stringValue = ""
            parent.input = ""
        }
    }
}

/// NSTextField with a block cursor (▌) appended to the visible text — mimics
/// macOS Terminal's caret when the field is empty or the user is typing.
final class CursorInputField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let editor = self.currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
    }
}

/// PaneView: renders a single terminal pane — header on top, terminal
/// surface filling the rest, with split/close context menu.
struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var tab: TabSession
    @EnvironmentObject var focus: FocusStore
    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TerminalSurface(
                scrollback: Binding(
                    get: { pane.content },
                    set: { pane.content = $0 }),
                input: $input,
                isFocused: focus.focusedPaneID == pane.id,
                onSubmit: { cmd in runCommand(cmd) },
                onFocusRequest: { focus.focusedPaneID = pane.id }
            )
            .background(Color.black)
        }
        .background(Color.black)
        .overlay(
            Rectangle()
                .stroke(Color.accentColor.opacity(0.7),
                    lineWidth: tab.activePaneID == pane.id ? 2 : 0)
        )
        .contextMenu { paneContextMenu }
        .onTapGesture {
            tab.setActive(paneID: pane.id)
            focus.focusedPaneID = pane.id
        }
        .onChange(of: focus.focusedPaneID) { newValue in
            if newValue == pane.id { /* focus handled in updateNSView */ }
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
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split horizontally")
            Button { tab.split(.vertical) } label: {
                Image(systemName: "rectangle.split.1x2").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Split vertically")
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

    private func runCommand(_ cmd: String) {
        let line = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        pane.content.append("\(pane.prompt) \(line)\n")
        executeOnPane(pane, line: line)
        if tab.broadcast {
            for other in tab.broadcastTargets(for: pane) where other.id != pane.id {
                other.content.append("\(other.prompt) \(line)\n")
                executeOnPane(other, line: line)
            }
        }
    }

    private func executeOnPane(_ pane: Pane, line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "clear":
            pane.content = ""
            return
        case "pwd":
            pane.content.append((pane.cwd ?? NSHomeDirectory()) + "\n")
            return
        case "exit":
            pane.content.append("(mterm MVP: shells persist; ignore exit)\n")
            return
        default:
            runShell(line, pane: pane)
        }
    }

    private func runShell(_ line: String, pane: Pane) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", line]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() }
            catch {
                DispatchQueue.main.async {
                    pane.content.append("mterm: failed to run: \(error.localizedDescription)\n")
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if !out.isEmpty {
                    pane.content.append(out.hasSuffix("\n") ? out : out + "\n")
                }
            }
        }
    }
}

extension Pane {
    /// Lightweight prompt — when real SwiftTerm arrives, replace with the
    /// OSC 7-derived cwd + a machine user@host.
    var prompt: String {
        let dir = cwd ?? NSHomeDirectory()
        let short = (dir as NSString).lastPathComponent
        return "\(NSUserName())@mterm:\(short)$"
    }
}