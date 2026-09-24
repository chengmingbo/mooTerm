import AppKit
import Combine
import Foundation

/// What double-clicking a title-bar-like area does, per System Settings →
/// Desktop & Dock → "Double-click a window's title bar to".
enum WindowDoubleClick {
    enum Action: Equatable { case zoom, minimize, none }

    static func action(for setting: String?) -> Action {
        switch setting {
        case "Minimize": return .minimize
        case "None": return .none
        default: return .zoom  // "Maximize", "Fill", or unset
        }
    }

    /// Borderless windows (Show Window Borders off) ignore `zoom`, so
    /// toggle between the screen's visible frame and the previous frame.
    @MainActor
    private static func toggleFill(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        if let previous = preFillFrames[window.windowNumber], window.frame == screen.visibleFrame {
            window.setFrame(previous, display: true, animate: true)
            preFillFrames[window.windowNumber] = nil
        } else {
            preFillFrames[window.windowNumber] = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }

    @MainActor private static var preFillFrames: [Int: NSRect] = [:]

    @MainActor
    static func perform(on window: NSWindow?) {
        guard let window else { return }
        let setting = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action(for: setting) {
        case .zoom:
            if window.styleMask.contains(.titled) {
                window.zoom(nil)
            } else {
                toggleFill(window)
            }
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
}

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