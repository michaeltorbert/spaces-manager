import Foundation

// MARK: - Name store

final class NameStore {
    private let defaults = UserDefaults.standard
    private let key = "spaceNames"

    init() {
        // One-shot migration from prior bundle id `local.spaceshud`.
        if defaults.dictionary(forKey: key) == nil,
           let legacy = UserDefaults(suiteName: "local.spaceshud")?
                            .dictionary(forKey: key) {
            defaults.set(legacy, forKey: key)
        }
    }

    func name(for spaceKey: String) -> String? {
        let dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return dict[spaceKey]
    }

    func setName(_ name: String?, for spaceKey: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let name, !name.isEmpty {
            dict[spaceKey] = name
        } else {
            dict.removeValue(forKey: spaceKey)
        }
        defaults.set(dict, forKey: key)
    }

    func displayName(for space: Space) -> String {
        if let n = name(for: space.key), !n.isEmpty { return n }
        return space.defaultName
    }
}
