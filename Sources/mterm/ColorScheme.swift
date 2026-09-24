import AppKit
import Foundation

/// Named terminal color scheme. Mirrors the 16-color xterm palette used by
/// gnome-terminator and most other terminal emulators, plus the visible
/// foreground, background, and caret colors.
///
/// SwiftTerm only exposes foreground/background/caret via the public API on
/// `AppleTerminalView`; the 16-color ANSI palette stays at SwiftTerm's
/// built-in defaults (which the host app is not expected to override for an
/// MVP). Future work could wire each index individually if needed.
struct ColorScheme: Equatable, Sendable, Codable {
    let id: String
    let displayName: String
    let background: String    // #RRGGBB
    let foreground: String
    let caret: String
    /// Optional 16-entry palette (`color0`..`color15`). Stored for
    /// forward-compatibility — currently informational only.
    let palette: [String]

    static let terminator = ColorScheme(
        id: "terminator",
        displayName: "Terminator",
        background: "#300a24",
        foreground: "#f6f6f6",
        caret: "#fce94f",
        palette: [
            "#2e3436", "#cc0000", "#4e9a06", "#c4a000",
            "#3465a4", "#75507b", "#06989a", "#d3d7cf",
            "#555753", "#ef2929", "#8ae234", "#fce94f",
            "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
        ]
    )

    static let solarizedDark = ColorScheme(
        id: "solarized-dark",
        displayName: "Solarized Dark",
        background: "#002b36",
        foreground: "#839496",
        caret: "#93a1a1",
        palette: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ]
    )

    static let solarizedLight = ColorScheme(
        id: "solarized-light",
        displayName: "Solarized Light",
        background: "#fdf6e3",
        foreground: "#657b83",
        caret: "#586e75",
        palette: [
            "#eee8d5", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#073642",
            "#fdf6e3", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#002b36",
        ]
    )

    static let monokai = ColorScheme(
        id: "monokai",
        displayName: "Monokai",
        background: "#272822",
        foreground: "#f8f8f2",
        caret: "#f8f8f0",
        palette: [
            "#272822", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
            "#75715e", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
        ]
    )

    static let tomorrowNight = ColorScheme(
        id: "tomorrow-night",
        displayName: "Tomorrow Night",
        background: "#1d1f21",
        foreground: "#c5c8c6",
        caret: "#aeafad",
        palette: [
            "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
            "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#969896", "#cc6666", "#b5bd68", "#f0c674",
            "#81a2be", "#b294bb", "#8abeb7", "#ffffff",
        ]
    )

    /// All built-in schemes in menu order. Extend this list to ship a new
    /// scheme.
    static let all: [ColorScheme] = [
        .terminator,
        .solarizedDark,
        .solarizedLight,
        .monokai,
        .tomorrowNight,
    ]

    func nsBackground() -> NSColor { NSColor(hex: background) ?? .black }
    func nsForeground() -> NSColor { NSColor(hex: foreground) ?? .white }
    func nsCaret() -> NSColor { NSColor(hex: caret) ?? nsForeground() }
}

extension NSColor {
    /// Parses `#RRGGBB`, `#RGB`, or `#RRGGBBAA`. Returns nil for anything
    /// else so callers fall back to a sensible default rather than crashing.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            let r = CGFloat((v >> 8) & 0xF) / 15
            let g = CGFloat((v >> 4) & 0xF) / 15
            let b = CGFloat(v & 0xF) / 15
            self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
        case 6:
            let r = CGFloat((v >> 16) & 0xFF) / 255
            let g = CGFloat((v >> 8) & 0xFF) / 255
            let b = CGFloat(v & 0xFF) / 255
            self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((v >> 24) & 0xFF) / 255
            let g = CGFloat((v >> 16) & 0xFF) / 255
            let b = CGFloat((v >> 8) & 0xFF) / 255
            let a = CGFloat(v & 0xFF) / 255
            self.init(calibratedRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}

/// Persisted active scheme. Stored as the scheme id so future additions to
/// `ColorScheme.all` don't lose their preference.
final class ColorSchemeStore: ObservableObject {
    static let storageKey = "mTerm.colorScheme"

    @Published private(set) var current: ColorScheme
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.storageKey)
        let resolved = ColorScheme.all.first { $0.id == id } ?? .terminator
        self.current = resolved
    }

    func select(_ scheme: ColorScheme) {
        current = scheme
        defaults.set(scheme.id, forKey: Self.storageKey)
    }
}