import AppKit
import SwiftUI

extension UserDefaults {
    static let assistantWidthKey = "mooTerm.assistant.width"
}

/// Narrow left-hand assistant panel (Claude, Codex, DeepSeek, MiniMax):
/// describe what you want in plain language, get a shell command (usually a
/// pipeline), review it, and run it in the active pane. Modelled on
/// NemoMac's Claude sidebar, but the model only *proposes* commands — mooTerm
/// types them into your shell when you accept.
struct AssistantPanelView: View {
    let descriptor: AssistantDescriptor
    @ObservedObject var assistant: CommandAssistant
    @EnvironmentObject var customStore: CustomAssistantStore
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var preferences: TerminalPreferences
    @AppStorage(UserDefaults.sidebarSelectionKey) private var sidebarSelection = ""
    @State private var input = ""
    @State private var focusComposer = 0

    private var targetTab: TabSession? { store.activeTab }
    private var targetPane: Pane? { targetTab?.activePane }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let tab = targetTab {
                TargetBar(tab: tab)
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { focusComposer += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .mootermFocusAssistant)) { _ in
            focusComposer += 1
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let symbol = descriptor.systemImage, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol).foregroundStyle(descriptor.tint)
            } else {
                Text(descriptor.letter).font(.headline.weight(.bold)).foregroundStyle(descriptor.tint)
            }
            Text(descriptor.title).font(.headline).lineLimit(1)
            let model = descriptor.modelLabel
            if !model.isEmpty {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Model — change in Settings (⌘,)")
            }
            Spacer(minLength: 4)
            Toggle(isOn: $assistant.autoRunSafe) {
                Image(systemName: "bolt.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(assistant.autoRunSafe
                  ? "Auto-run is on: read-only (safe) commands run immediately"
                  : "Auto-run is off: review every command before it runs")
            Button(action: assistant.clear) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(assistant.isThinking || assistant.entries.isEmpty)
                .help("Clear conversation")
            Button { sidebarSelection = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close panel")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if assistant.entries.isEmpty && !assistant.isThinking {
                        EmptyStateView(providerName: descriptor.title) { example in
                            input = example
                            send()
                        }
                    }
                    ForEach(assistant.entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    if assistant.isThinking {
                        ThinkingRow(providerName: descriptor.title, since: assistant.thinkingSince, onCancel: assistant.cancel)
                            .id("thinking")
                    }
                }
                .padding(10)
            }
            .onChange(of: assistant.entries.count) { _ in
                if let last = assistant.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: assistant.isThinking) { thinking in
                if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: AssistantEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .assistant:
            if entry.command != nil {
                CommandCard(entry: entry,
                            isLatest: entry.id == assistant.entries.last(where: { $0.command != nil })?.id,
                            onRun: { run(entry, $0) },
                            onInsert: { insert(entry, $0) })
            } else {
                Text(.init(entry.text))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case .note:
            Label(entry.text, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ComposerTextView(text: $input, focusToken: focusComposer, onSend: send, onEscape: returnToTerminal)
                .frame(minHeight: 44, maxHeight: 100)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Describe a command…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                        .allowsHitTesting(false)
                }
            Text("↩ ask · ⇧↩ new line · !cmd runs as typed · esc back to terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(9)
    }

    // MARK: Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isThinking else { return }
        input = ""
        let context = TerminalContext.of(targetPane, broadcastPaneCount: broadcastCount)
        let options = assistantOptions(for: descriptor.item, preferences: preferences, store: customStore)
        Task {
            if let autoRun = await assistant.submit(text, context: context, options: options),
               let command = autoRun.command {
                run(autoRun, command)
            }
        }
    }

    private var broadcastCount: Int {
        guard let tab = targetTab, let pane = targetPane, tab.broadcast else { return 1 }
        return tab.broadcastTargets(for: pane).count
    }

    private func run(_ entry: AssistantEntry, _ command: String) {
        let risk = max(entry.risk ?? .safe, CommandRisk.assess(command))
        if risk == .danger && !confirmDangerous(command) { return }
        if let error = assistant.run(entry.id, command: command, in: targetPane) {
            assistant.note(error.message)
        } else {
            returnToTerminal()
        }
    }

    private func insert(_ entry: AssistantEntry, _ command: String) {
        if let error = assistant.insert(entry.id, command: command, in: targetPane) {
            assistant.note(error.message)
        } else {
            returnToTerminal()
        }
    }

    private func confirmDangerous(_ command: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run a potentially destructive command?"
        let where_ = broadcastCount > 1 ? " in \(broadcastCount) panes (broadcast is on)" : ""
        alert.informativeText = "\(command)\n\nThis may delete data or be hard to undo. It will run\(where_) in \(targetPane?.currentDirectory ?? "the active pane")."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func returnToTerminal() {
        guard let view = targetPane?.host?.view else { return }
        view.window?.makeFirstResponder(view)
    }
}

extension Notification.Name {
    /// Ask the panel to focus its composer (menu shortcut while visible).
    static let mootermFocusAssistant = Notification.Name("mooTerm.focusAssistant")
}

// MARK: - Pieces

/// Shows where commands will run: the active pane's directory, and a
/// warning when broadcast will fan the command out.
private struct TargetBar: View {
    @ObservedObject var tab: TabSession

    var body: some View {
        let pane = tab.activePane
        let dir = (pane?.cwd).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right.circle")
                Text(dir)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Commands run in the active pane: \(dir)")
            }
            if tab.broadcast, let pane {
                let count = tab.broadcastTargets(for: pane).count
                if count > 1 {
                    Label("Broadcast on — runs in \(count) panes", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandCard: View {
    let entry: AssistantEntry
    let isLatest: Bool
    let onRun: (String) -> Void
    let onInsert: (String) -> Void
    @State private var command: String = ""

    private var risk: CommandRisk { max(entry.risk ?? .safe, CommandRisk.assess(command)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RiskBadge(risk: risk)
                Spacer()
                if let status = entry.status, status != .proposed {
                    Label(status == .ran ? "Ran" : "Inserted",
                          systemImage: status == .ran ? "checkmark.circle.fill" : "text.cursor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("command", text: $command, axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help("Edit before running if you like")
            if !entry.text.isEmpty {
                Text(.init(entry.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                let runButton = Button { onRun(command) } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(risk == .danger ? .red : .accentColor)
                .controlSize(.small)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(isLatest ? "Run in the active pane (⌘↩)" : "Run in the active pane")
                if isLatest {
                    runButton.keyboardShortcut(.return, modifiers: [.command])
                } else {
                    runButton
                }
                Button { onInsert(command) } label: { Text("Insert") }
                    .controlSize(.small)
                    .help("Type it at the prompt without running, to edit first")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy")
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(risk == .danger ? Color.red.opacity(0.5) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { command = entry.command ?? "" }
    }
}

private struct RiskBadge: View {
    let risk: CommandRisk
    var body: some View {
        let (label, color, icon): (String, Color, String) = {
            switch risk {
            case .safe: return ("Read-only", .green, "checkmark.shield")
            case .caution: return ("Modifies", .orange, "exclamationmark.triangle")
            case .danger: return ("Destructive", .red, "exclamationmark.octagon")
            }
        }()
        Label(label, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct ThinkingRow: View {
    let providerName: String
    let since: Date?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = since.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                Text("\(providerName) is thinking… \(seconds)s").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .font(.caption)
        .padding(8)
    }
}

private struct EmptyStateView: View {
    let providerName: String
    let onPick: (String) -> Void
    private let examples = [
        "10 largest files under here",
        "which process is listening on port 3000",
        "count lines of Swift code, by file, biggest first",
        "my git commits this week, one line each",
        "why did the last command fail?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask in plain language — \(providerName) writes the command, you review it, mooTerm runs it in the active pane.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(examples, id: \.self) { example in
                Button { onPick(example) } label: {
                    Text(example)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}

/// Multi-line composer: Return sends, Shift-Return inserts a newline,
/// Escape hands focus back to the terminal.
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSend: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape() }
        if textView.string != text { textView.string = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusToken = -1
        init(parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if isReturn && mods.isEmpty && !hasMarkedText() {
            onSend?()
            return
        }
        if event.keyCode == 53 && !hasMarkedText() {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
