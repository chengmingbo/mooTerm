import AppKit

/// iTerm2's "Natural Text Editing" key preset: macOS text-field shortcuts
/// translated into the readline/zle control sequences shells understand.
/// Plain control keys (⌃A, ⌃E, ⌃L, ⌃R, …) need no mapping — SwiftTerm
/// already sends them to the shell verbatim.
@MainActor
enum NaturalTextEditing {
    /// Bytes to send for `event`, or nil to let it through unchanged.
    static func bytes(for event: NSEvent) -> [UInt8]? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return nil }
        let esc: UInt8 = 0x1B
        switch (mods, Int(key)) {
        case ([.command], NSLeftArrowFunctionKey): return [0x01]          // ⌘← start of line (⌃A)
        case ([.command], NSRightArrowFunctionKey): return [0x05]         // ⌘→ end of line (⌃E)
        case ([.option], NSLeftArrowFunctionKey): return [esc, 0x62]      // ⌥← back one word (Esc b)
        case ([.option], NSRightArrowFunctionKey): return [esc, 0x66]     // ⌥→ forward one word (Esc f)
        case ([.command], 0x7F): return [0x15]                            // ⌘⌫ delete to start of line (⌃U)
        case ([.option], 0x7F): return [esc, 0x7F]                        // ⌥⌫ delete previous word
        case ([.option], NSDeleteFunctionKey): return [esc, 0x64]         // ⌥⌦ delete next word (Esc d)
        default: return nil
        }
    }

    /// Handle `event` if it targets a terminal and matches the preset.
    static func handle(_ event: NSEvent) -> Bool {
        guard let terminal = event.window?.firstResponder as? MooTermTerminalView,
              let bytes = bytes(for: event) else { return false }
        terminal.send(bytes)
        return true
    }
}
