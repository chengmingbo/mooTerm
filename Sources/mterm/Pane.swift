import AppKit
import Foundation
import SwiftUI

/// A single terminal pane. The pane — not the SwiftUI view tree — owns its
/// `TerminalHostView`, so the shell survives splits, zoom, and tab switches
/// (all of which make SwiftUI tear down and rebuild the pane's view).
@MainActor
final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "shell"
    @Published var cwd: String?
    /// Output arrived since the user last looked at this pane's tab.
    @Published var hasUnseenOutput = false
    /// The shell rang the bell since the user last looked at this pane's tab.
    @Published var bellRang = false
    /// Members of the same broadcast group share a shellID. nil = no group.
    var shellID: String? = nil
    /// Optional command to launch instead of the user's default shell when
    /// the pane's terminal starts. Used by saved layouts to restore a
    /// per-pane command (e.g. `tail -F /var/log/syslog`).
    var customCommand: String? = nil
    /// Called when the shell exits so the owning tab can remove the pane.
    var onExit: (() -> Void)?
    /// Called when the terminal view becomes first responder (e.g. clicked).
    var onFocus: (() -> Void)?
    /// Called with every chunk of user input, so the tab can broadcast it.
    var onInput: ((ArraySlice<UInt8>) -> Void)?

    private(set) var host: TerminalHostView?

    init(cwd: String? = nil) {
        // Start at $HOME. Use NSHomeDirectory() (which falls back to
        // getpwuid) rather than ProcessInfo.processInfo.environment["HOME"]
        // because `.app` bundles launched via Finder or `open` sometimes
        // run without HOME set in the inherited environment, and we never
        // want to land the user in `/` by default.
        let home = NSHomeDirectory()
        self.cwd = cwd ?? (home.isEmpty ? "/" : home)
    }

    /// The pane's terminal, created and started on first use.
    func ensureHost(fontSize: CGFloat, scheme: ColorScheme, scrollback: Int,
                    environment: [String: String] = [:]) -> TerminalHostView {
        if let host { return host }
        let dir = URL(fileURLWithPath: cwd ?? NSHomeDirectory())
        let host = TerminalHostView(startingDirectory: dir)
        host.configureAppearance(fontSize: fontSize)
        host.applyScheme(scheme)
        host.applyScrollback(lines: scrollback)
        host.currentDirectoryDidChange = { [weak self] url in self?.cwd = url.path }
        host.titleChanged = { [weak self] title in
            self?.title = title.isEmpty ? "shell" : title
        }
        host.exitedChanged = { [weak self] _ in self?.onExit?() }
        host.view.onOutput = { [weak self] in
            guard let self, !self.hasUnseenOutput else { return }
            self.hasUnseenOutput = true
        }
        host.view.onBell = { [weak self] in
            self?.bellRang = true
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        host.view.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }
        host.view.onInput = { [weak self] data in self?.onInput?(data) }
        host.startShell(in: dir, command: customCommand, environment: environment)
        self.host = host
        return host
    }

    /// Best-known working directory: the live shell's cwd when available,
    /// otherwise the last OSC 7 report / starting directory.
    var currentDirectory: String? { host?.liveWorkingDirectory ?? cwd }

    /// Name of a program running in the foreground (e.g. `vim`), or nil
    /// when the shell is idle at its prompt or has exited.
    var runningProcessName: String? { host?.foregroundProcessName }

    func clearIndicators() {
        if hasUnseenOutput { hasUnseenOutput = false }
        if bellRang { bellRang = false }
    }

    func terminate() {
        onExit = nil
        host?.terminate()
        host = nil
    }
}
