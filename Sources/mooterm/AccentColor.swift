import AppKit
import SwiftUI

/// Per-pane / per-tab accent colour. The `.none` case falls back to the
/// default gray dot, preserving the existing appearance for tabs that have
/// not opted into colouring.
enum AccentColor: String, CaseIterable, Codable, Sendable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    /// Stable string for menu items / persistence.
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .red: return NSColor(calibratedRed: 0.93, green: 0.32, blue: 0.32, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.20, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.93, green: 0.85, blue: 0.30, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.45, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.32, green: 0.62, blue: 0.95, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.65, green: 0.45, blue: 0.85, alpha: 1)
        }
    }

    var swiftUIColor: Color {
        if let c = nsColor { return Color(nsColor: c) }
        return Color.gray.opacity(0.4)
    }
}