import Foundation
import Combine

/// One node in a saved layout's split tree. Mirrors the runtime `SplitNode`
/// but is a value type so we can serialise it without holding class references.
indirect enum LayoutNode: Codable, Equatable {
    case pane(LayoutPane)
    case split(direction: String, ratio: Double, first: LayoutNode, second: LayoutNode)

    private enum CodingKeys: String, CodingKey {
        case kind, pane, direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "pane":
            self = .pane(try c.decode(LayoutPane.self, forKey: .pane))
        case "split":
            let dir = try c.decode(String.self, forKey: .direction)
            let ratio = try c.decode(Double.self, forKey: .ratio)
            let first = try c.decode(LayoutNode.self, forKey: .first)
            let second = try c.decode(LayoutNode.self, forKey: .second)
            self = .split(direction: dir, ratio: ratio, first: first, second: second)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown node kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(p):
            try c.encode("pane", forKey: .kind)
            try c.encode(p, forKey: .pane)
        case let .split(dir, ratio, first, second):
            try c.encode("split", forKey: .kind)
            try c.encode(dir, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

/// Per-pane fields worth persisting. shellID is the broadcast-group marker;
/// customCommand is the launch command for the shell (when non-nil).
struct LayoutPane: Codable, Equatable {
    let title: String?
    let customTitle: String?
    let cwd: String?
    let shellID: String?
    let customCommand: String?
    let accent: String?
}

/// One tab in a saved layout.
struct LayoutTab: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String?
    let customTitle: String?
    let accent: String?
    let broadcast: Bool
    let activePaneID: UUID?
    let root: LayoutNode

    enum CodingKeys: String, CodingKey {
        case id, title, customTitle, accent, broadcast, activePaneID, root
    }

    init(id: UUID = UUID(),
         title: String? = nil,
         customTitle: String? = nil,
         accent: String? = nil,
         broadcast: Bool = false,
         activePaneID: UUID? = nil,
         root: LayoutNode)
    {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.accent = accent
        self.broadcast = broadcast
        self.activePaneID = activePaneID
        self.root = root
    }
}

/// A complete saved layout: a list of tabs plus the active tab id.
struct SavedLayout: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var tabs: [LayoutTab]
    var activeTabID: UUID?

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         tabs: [LayoutTab],
         activeTabID: UUID?)
    {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

/// Persisted store of layouts. One JSON file under
/// `~/Library/Application Support/mTerm/layouts.json`.
@MainActor
final class LayoutStore: ObservableObject {
    static let storageFileName = "layouts.json"
    static let defaultLayoutName = "default"

    @Published private(set) var layouts: [SavedLayout] = []

    private let storageURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base: URL
        if let appSupport = try? fileManager.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true) {
            base = appSupport.appendingPathComponent("mTerm", isDirectory: true)
        } else {
            base = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/mTerm", isDirectory: true)
        }
        self.storageURL = base.appendingPathComponent(Self.storageFileName)
        load()
    }

    // MARK: - Snapshot / Restore

    /// Capture the current `SessionStore` state into a `SavedLayout` value
    /// that can be persisted or restored later.
    static func snapshot(of store: SessionStore, name: String) -> SavedLayout {
        let tabs: [LayoutTab] = store.tabs.map { tab in
            let node = nodeFrom(tab.root)
            let activeID = tab.activePaneID ?? tab.collectPanes(tab.root).first?.id
            return LayoutTab(
                id: tab.id,
                title: tab.title,
                customTitle: tab.customTitle,
                accent: tab.accent.rawValue,
                broadcast: tab.broadcast,
                activePaneID: activeID,
                root: node
            )
        }
        return SavedLayout(
            name: name,
            tabs: tabs,
            activeTabID: store.activeTabID
        )
    }

    /// Apply a saved layout to the given store, replacing all current tabs.
    /// Restores the split tree, per-pane cwd/title, broadcast, and the
    /// active tab/pane. Anything in progress (live shells) is terminated.
    func restore(_ layout: SavedLayout, into store: SessionStore) {
        store.tabs.forEach { $0.terminate() }
        let rebuiltTabs: [TabSession] = layout.tabs.map { tab in
            let t = TabSession(id: tab.id)
            t.customTitle = tab.customTitle
            t.accent = AccentColor(rawValue: tab.accent ?? "") ?? .none
            t.broadcast = tab.broadcast
            t.root = splitNode(from: tab.root)
            t.activePaneID = tab.activePaneID
            return t
        }
        store.tabs = rebuiltTabs.isEmpty ? [TabSession()] : rebuiltTabs
        if let active = layout.activeTabID, rebuiltTabs.contains(where: { $0.id == active }) {
            store.activeTabID = active
        } else {
            store.activeTabID = store.tabs.first?.id ?? UUID()
        }
    }

    // MARK: - CRUD

    func save(_ layout: SavedLayout) {
        if let idx = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[idx] = layout
        } else {
            layouts.append(layout)
        }
        persist()
    }

    func delete(id: UUID) {
        layouts.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[idx].name = newName
        persist()
    }

    /// Find a layout by name (case-insensitive). Useful for `mterm --layout foo`.
    func layout(named name: String) -> SavedLayout? {
        layouts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.layouts = try decoder.decode([SavedLayout].self, from: data)
        } catch {
            AppDelegate.log("[mTerm] LayoutStore.load failed: \(error)")
        }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(layouts)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            AppDelegate.log("[mTerm] LayoutStore.persist failed: \(error)")
        }
    }

    // MARK: - Split tree conversion

    private static func nodeFrom(_ node: SplitNode) -> LayoutNode {
        if let pane = node.pane {
            return .pane(LayoutPane(
                title: pane.title,
                customTitle: pane.title,
                cwd: pane.cwd,
                shellID: pane.shellID,
                customCommand: pane.customCommand,
                accent: nil
            ))
        }
        let dirString: String
        switch node.direction {
        case .horizontal: dirString = "h"
        case .vertical: dirString = "v"
        }
        let first = node.first.map(nodeFrom) ?? .pane(LayoutPane(title: nil, customTitle: nil, cwd: nil, shellID: nil, customCommand: nil, accent: nil))
        let second = node.second.map(nodeFrom) ?? first
        return .split(direction: dirString, ratio: Double(node.ratio), first: first, second: second)
    }

    private func splitNode(from layout: LayoutNode) -> SplitNode {
        switch layout {
        case let .pane(paneData):
            let pane = Pane()
            pane.title = paneData.title ?? paneData.customTitle ?? "shell"
            pane.cwd = paneData.cwd
            pane.shellID = paneData.shellID
            pane.customCommand = paneData.customCommand
            return SplitNode(pane: pane)
        case let .split(dir, ratio, first, second):
            let direction: SplitDirection = (dir == "h") ? .horizontal : .vertical
            return SplitNode(direction: direction,
                             first: splitNode(from: first),
                             second: splitNode(from: second),
                             ratio: CGFloat(ratio))
        }
    }
}