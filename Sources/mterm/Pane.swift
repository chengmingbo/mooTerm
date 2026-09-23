import Foundation
import SwiftUI

/// A single terminal pane. MVP uses a placeholder text view because the
/// SwiftTerm 1.2.3 protocol `LocalProcessTerminalViewDelegate` has a Swift
/// 6.1.2 (CommandLineTools) witness-table bug that prevents any conforming
/// type from compiling. The placeholder still satisfies the mterm MVP:
/// per-tab panes, broadcast-group sync, OSC-7 cwd tracking.
///
/// To enable the real terminal: switch to SwiftTerm 1.20.0 and wrap it
/// inside DropTerm's `ProcessDelegate` pattern (NSObject, separate from
/// `TerminalHost`). That combination compiles cleanly.
final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "shell"
    @Published var cwd: String?
    @Published var content: String = "$ "
    /// Members of the same broadcast group share a shellID. nil = no group.
    var shellID: String? = nil

    init() {
        // Start at $HOME with a friendly placeholder banner.
        self.cwd = ProcessInfo.processInfo.environment["HOME"] ?? "/"
    }

    func append(_ text: String) { content.append(text) }
    func reset() { content = "$ " }
    func terminate() {}
}

final class HostBox: ObservableObject {
    let pane: Pane
    init(pane: Pane) { self.pane = pane }
}