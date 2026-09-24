import AppKit
import Combine
import Foundation

/// Window-level preferences: borderless mode + always-on-top. Both persist
/// to UserDefaults. The window is mutated by the AppDelegate whenever these
/// flip so the menu checkmarks stay in sync.
@MainActor
final class WindowStore: ObservableObject {
    static let bordersKey = "mTerm.window.borders"
    static let alwaysOnTopKey = "mTerm.window.alwaysOnTop"

    @Published var borders: Bool {
        didSet { UserDefaults.standard.set(borders, forKey: Self.bordersKey) }
    }
    @Published var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey) }
    }

    init(defaults: UserDefaults = .standard) {
        // Default: borders on (window chrome visible) and not always on top.
        self.borders = defaults.object(forKey: Self.bordersKey) as? Bool ?? true
        self.alwaysOnTop = defaults.bool(forKey: Self.alwaysOnTopKey)
    }

    /// Apply both settings to the given window. Call once at launch and
    /// every time a setting flips.
    func apply(to window: NSWindow) {
        if borders {
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        } else {
            // .fullSizeContentView + no title keeps the mask non-titled so
            // the title bar disappears but traffic-light controls can stay
            // for window movement on macOS Big Sur+.
            window.styleMask.remove([.titled])
            window.styleMask.insert([.resizable, .miniaturizable, .closable])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.level = alwaysOnTop ? .floating : .normal
    }
}