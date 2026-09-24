import AppKit
import Darwin
import SwiftTerm
import Foundation

/// `LocalProcessTerminalView` with the hooks mTerm needs: output activity
/// and bell notifications for tab indicators.
@MainActor
final class MTermTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onBell: (() -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    /// Bytes the user typed/pasted into this terminal (for broadcast).
    var onInput: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onInput?(data)
    }

    /// Write straight to the PTY without re-broadcasting.
    func sendToProcess(_ data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }
}

/// The single layer that knows about SwiftTerm.
///
/// Following the same separation as NemoMac's `TerminalHostView`, this class
/// hides the terminal emulator from the rest of the app so the implementation
/// can be swapped (for example, for libghostty) without changing the panel,
/// settings, or session bookkeeping.
@MainActor
final class TerminalHostView: NSObject {
    let view: MTermTerminalView
    private(set) var currentDirectory: URL
    private var processDelegate: ProcessDelegate

    var title: String = "" {
        didSet { titleChanged?(title) }
    }
    var exited: Bool = false {
        didSet { if exited { exitedChanged?(processDelegate.lastExitCode) } }
    }
    var currentDirectoryDidChange: ((URL) -> Void)?
    var titleChanged: ((String) -> Void)?
    var exitedChanged: ((Int32?) -> Void)?

    init(startingDirectory: URL) {
        self.currentDirectory = startingDirectory.standardizedFileURL
        self.view = MTermTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        self.processDelegate = ProcessDelegate()
        super.init()
        self.processDelegate.owner = self
        self.view.processDelegate = processDelegate
    }

    private var appliedFontSize: CGFloat?
    private var appliedSchemeID: String?
    private var appliedScrollback: Int?

    /// Resize the history buffer. Shrinking drops the oldest lines;
    /// 0 turns scrollback off.
    func applyScrollback(lines: Int) {
        guard lines != appliedScrollback else { return }
        appliedScrollback = lines
        view.getTerminal().changeScrollback(lines)
    }

    /// Set the terminal font size. SwiftTerm's `font` setter recomputes the
    /// cell size, resizes the grid (sending SIGWINCH to the shell), and
    /// schedules a redraw, so one assignment is all that's needed.
    func configureAppearance(fontSize: CGFloat) {
        guard fontSize != appliedFontSize else { return }
        appliedFontSize = fontSize
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Re-paint the terminal using the supplied scheme. Safe to call at any
    /// time; SwiftTerm re-renders the next frame after the colours change.
    func applyScheme(_ scheme: ColorScheme) {
        guard scheme.id != appliedSchemeID else { return }
        appliedSchemeID = scheme.id
        view.nativeBackgroundColor = scheme.nsBackground()
        view.nativeForegroundColor = scheme.nsForeground()
        view.caretColor = scheme.nsCaret()
        view.needsDisplay = true
    }

    /// Start the login shell in the given directory — or, when `command` is
    /// set, run it through the shell. Passing the directory explicitly
    /// matters: `.app` bundles launched via `open` have `/` as their cwd.
    func startShell(in directory: URL, command: String? = nil) {
        let resolvedShell = Self.resolveLoginShell()
        var args = ["-l"]
        if let command, !command.isEmpty { args += ["-c", command] }
        view.startProcess(
            executable: resolvedShell,
            args: args,
            environment: Self.shellEnvironment(shellPath: resolvedShell),
            execName: "-" + URL(fileURLWithPath: resolvedShell).lastPathComponent,
            currentDirectory: directory.path
        )
    }

    /// Hang up the shell (SIGHUP to its process group, like closing a
    /// terminal window) so child jobs exit too.
    func terminate() {
        processDelegate.owner = nil
        guard view.process.running else { return }
        let pid = view.process.shellPid
        if pid > 0 { kill(-pid, SIGHUP) }
        view.terminate()
    }

    /// Clear the screen and scrollback (iTerm2's ⌘K), then ask an idle shell
    /// to redraw its prompt.
    func clearBuffer() {
        view.feed(text: "\u{1b}[H\u{1b}[2J")
        view.clearScrollback()
        if shellIsIdle { view.send([0x0C]) }
    }

    /// Name of the foreground job when it is not the shell itself.
    var foregroundProcessName: String? {
        guard view.process.running else { return nil }
        let pgrp = tcgetpgrp(view.process.childfd)
        guard pgrp > 0, pgrp != view.process.shellPid else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pgrp, &buffer, UInt32(buffer.count)) > 0 else { return "a process" }
        return String(cString: buffer)
    }

    /// The shell's actual cwd, read from the kernel. Works even when the
    /// shell doesn't emit OSC 7 (bash, fish, custom prompts).
    var liveWorkingDirectory: String? {
        guard view.process.running else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(view.process.shellPid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// True when the shell owns the PTY foreground process group and is safe to
    /// receive injected text. Mirrors NemoMac's idle-detection so any caller that
    /// later wants to send commands can guard against interrupting a child
    /// program (editor, REPL, `top`, etc.).
    var shellIsIdle: Bool {
        guard view.process.running else { return false }
        return tcgetpgrp(view.process.childfd) == view.process.shellPid
    }

    // MARK: - Shell environment

    nonisolated static func resolveLoginShell() -> String {
        let accountShell = getpwuid(getuid()).flatMap { entry -> String? in
            guard let ptr = entry.pointee.pw_shell else { return nil }
            return String(cString: ptr)
        }
        let candidate = accountShell ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
    }

    nonisolated static func shellEnvironment(shellPath: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // macOS's /etc/zshrc uses TERM_PROGRAM to decide whether to install its
        // OSC 7 working-directory hook. Setting it to "Apple_Terminal" matches
        // NemoMac and lets us observe the shell's CWD via SwiftTerm.
        env["TERM_PROGRAM"] = "Apple_Terminal"
        env["TERM_PROGRAM_VERSION"] = "0.2.0"
        env["SHELL"] = shellPath
        env["HOME"] = NSHomeDirectory()
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Shell quoting (matches NemoMac)

    /// POSIX-shell single-quote a value so it can safely appear inside a
    /// double-quoted command body. Empty input returns the empty-quotes form
    /// rather than the unquoted empty string.
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a `cd` command for the shell, prefixed with Ctrl-U to clear any
    /// half-typed command before the directory change arrives.
    nonisolated static func directoryChangeCommand(for url: URL) -> String {
        "\u{15}cd -- \(shellQuote(url.standardizedFileURL.path))\n"
    }

    /// Parse the OSC 7 working-directory report that a well-configured shell
    /// emits after every prompt. Returns `nil` for non-`file://` URLs so a
    /// hostile prompt cannot redirect the terminal somewhere unexpected.
    nonisolated static func reportedDirectory(from value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        return URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
    }

    // MARK: - Private delegate

    @MainActor
private final class ProcessDelegate: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        weak var owner: TerminalHostView?
        var lastExitCode: Int32?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            owner?.title = String(title.prefix(80))
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let owner,
                  let reported = TerminalHostView.reportedDirectory(from: directory),
                  reported != owner.currentDirectory else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: reported.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            owner.currentDirectory = reported
            owner.currentDirectoryDidChange?(reported)
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            lastExitCode = exitCode
            owner?.exited = true
        }
    }
}