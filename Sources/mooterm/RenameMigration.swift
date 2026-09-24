import Foundation

/// One-time carry-over from the app's old name (mTerm, bundle id
/// `local.mterm.app`) to mooTerm: settings live under a new bundle id and
/// key prefix, and saved layouts/API keys under a new Application Support
/// folder. Old data is copied, not deleted.
enum RenameMigration {
    static let doneKey = "mooTerm.migratedFromMTerm"
    /// The .app's old bundle id, and the executable name `swift run` used.
    static let oldDomains = ["local.mterm.app", "mterm"]
    static let oldPrefix = "mTerm."
    static let newPrefix = "mooTerm."

    static func run(defaults: UserDefaults = .standard,
                    fromDomains domains: [String] = oldDomains,
                    moveFiles: Bool = true) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in domains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in migratedKeys(old) where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        if moveFiles { moveApplicationSupport(fileManager: .default) }
        defaults.set(true, forKey: doneKey)
    }

    /// Old `mTerm.*` settings under their `mooTerm.*` names.
    static func migratedKeys(_ old: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in old where key.hasPrefix(oldPrefix) {
            result[newPrefix + key.dropFirst(oldPrefix.count)] = value
        }
        return result
    }

    static func moveApplicationSupport(fileManager: FileManager) {
        guard let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: false) else { return }
        let old = base.appendingPathComponent("mTerm", isDirectory: true)
        let new = base.appendingPathComponent("mooTerm", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.copyItem(at: old, to: new)
    }
}
