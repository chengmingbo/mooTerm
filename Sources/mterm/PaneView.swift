import SwiftUI
import AppKit

/// Focus state — which pane currently owns keyboard input. Lives on the
/// store so cross-pane navigation works.
final class FocusStore: ObservableObject {
    @Published var focusedPaneID: UUID?
}

/// Embeds an NSTextField that owns keyboard focus. The field is the actual
/// receiver of mouse clicks + keystrokes; everything else is a styled display.
struct TerminalInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (String) -> Void
    var onAnyKey: (String) -> Void
    var focusRequest: Int       // bump to force-focus
    var broadcasts: [Pane]      // when broadcast is on, echo keystrokes here too

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.textColor = .green
        tf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.commit(_:))
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        context.coordinator.parent = self
        if let win = tf.window, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { win.makeFirstResponder(tf) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalInput
        var lastFocusRequest: Int = 0
        init(_ parent: TerminalInput) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
            parent.onAnyKey(tf.stringValue)
        }

        @objc func commit(_ sender: NSTextField) {
            parent.onSubmit(sender.stringValue)
            sender.stringValue = ""
            parent.text = ""
        }
    }
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var tab: TabSession
    @EnvironmentObject var focus: FocusStore
    @State private var input: String = ""
    @State private var focusRequest: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                Text(pane.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .background(Color.black)
            inputRow
        }
        .background(Color.black)
        .overlay(
            Rectangle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: tab.activePaneID == pane.id ? 2 : 0)
        )
        .onTapGesture {
            tab.setActive(paneID: pane.id)
            focus.focusedPaneID = pane.id
            focusRequest &+= 1
        }
        .onChange(of: focus.focusedPaneID) { newValue in
            if newValue == pane.id { focusRequest &+= 1 }
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
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.gray.opacity(0.15))
    }

    private var inputRow: some View {
        let broadcasts: [Pane] = tab.broadcast
            ? tab.broadcastTargets(for: pane).filter { $0.id != pane.id }
            : []
        return HStack(spacing: 4) {
            Text("$")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)
            TerminalInput(
                text: $input,
                placeholder: "type a command and press Return…",
                onSubmit: { cmd in runCommand(cmd) },
                onAnyKey: { _ in fanOutKey(broadcasts: broadcasts) },
                focusRequest: focusRequest,
                broadcasts: broadcasts
            )
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    private func runCommand(_ cmd: String) {
        let line = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        pane.content.append("$ \(line)\n")
        executeOnPane(pane, line: line)
        // Broadcast: same command on every group member except self.
        if tab.broadcast {
            for other in tab.broadcastTargets(for: pane) where other.id != pane.id {
                other.content.append("$ \(line)\n")
                executeOnPane(other, line: line)
            }
        }
    }

    private func executeOnPane(_ pane: Pane, line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "echo":
            pane.content.append((parts.count > 1 ? parts[1] : "") + "\n")
        case "clear":
            pane.content = "$ "
        case "cwd":
            pane.content.append((pane.cwd ?? "?") + "\n")
        case "ls":
            let path = parts.count > 1 ? parts[1] : (pane.cwd ?? "/")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                pane.content.append(names.joined(separator: "  ") + "\n")
            } else {
                pane.content.append("ls: \(path): No such file or directory\n")
            }
        default:
            pane.content.append("mterm MVP — unknown command '\(parts[0])'. try: echo, clear, cwd, ls\n")
        }
    }

    /// When the user types into this pane while broadcast is on, mirror the
    /// same string into every other pane in the group so they all run the
    /// command simultaneously. MVP fan-out: at Submit time we run the command
    /// in each pane.
    private func fanOutKey(broadcasts: [Pane]) {
        // per-keystroke echo is left as a TODO; submit-time fan-out is below.
        _ = broadcasts
    }
}