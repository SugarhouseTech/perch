import Foundation

/// Carries settings over from the app's earlier identity, WindowPin
/// (`tech.sugarhouse.WindowPin`), the first time Perch runs, so a rename asks
/// for the permissions again but not for every setting as well.
///
/// Runs once: a flag records that it ran, whether or not there was anything to
/// copy, and a setting Perch already has is never overwritten.
nonisolated enum SettingsMigration {
    static let oldDomain = "tech.sugarhouse.WindowPin"
    static let doneKey = "migratedFromWindowPin"

    /// - Returns: the keys copied.
    @discardableResult
    static func run(old: [String: Any]?, into defaults: UserDefaults) -> [String] {
        guard !defaults.bool(forKey: doneKey) else { return [] }
        defaults.set(true, forKey: doneKey)
        guard let old else { return [] }
        var copied: [String] = []
        for (key, value) in old.sorted(by: { $0.key < $1.key }) where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }
}
